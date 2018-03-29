{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Nix.Eval (NValue, NValueNF, NValueF(..), ValueSet, MonadNix(..),
                 evalExpr, tracingExprEval, checkExpr,
                 exprNormalForm, normalForm,
                 builtin, builtin2, atomText, valueText,
                 buildArgument) where

import           Control.Monad hiding (mapM, sequence)
import           Data.Align.Key
import           Data.Fix
import           Data.Functor.Identity
import           Data.List (intercalate)
import qualified Data.Map.Lazy as Map
import           Data.Maybe (fromMaybe)
import           Data.Monoid (appEndo, Endo)
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.These
import           Data.Typeable (Typeable)
import           GHC.Generics
import           Nix.Atoms
import           Nix.Expr
import           Nix.StringOperations (runAntiquoted)
import           Nix.Utils
import           Debug.Trace

type DList a = Endo [a]

-- | An 'NValue' is the most reduced form of an 'NExpr' after evaluation
-- is completed.
data NValueF m r
    = NVConstant NAtom
     -- | A string has a value and a context, which can be used to record what a
     -- string has been build from
    | NVStr Text (DList Text)
    | NVList [r]
    | NVSet (Map.Map Text r)
    | NVFunction (Params r) r
      -- ^ A function is a closed set of terms representing the "call
      --   signature", used at application time to check the type of arguments
      --   passed to the function. Since it supports default values which may
      --   depend on other values within the final argument set, this
      --   dependency is represented as a set of pending evaluations. The
      --   arguments are finally normalized into a set which is passed to the
      --   function.
    | NVLiteralPath FilePath
    | NVEnvPath FilePath
    | NVBuiltin String (NThunk m -> m (NThunk m))
      -- ^ A builtin function can never be normalized beyond this.
    deriving (Generic, Typeable, Functor)

type NValueNF m  = Fix (NValueF m)   -- normal form
type NValue m = NValueF m (NThunk m) -- head normal form

instance Show f => Show (NValueF m f) where
    showsPrec = flip go where
      go (NVConstant atom)    = showsCon1 "NVConstant" atom
      go (NVStr text context) = showsCon2 "NVStr"      text (appEndo context [])
      go (NVList     list)    = showsCon1 "NVList"     list
      go (NVSet     attrs)    = showsCon1 "NVSet"      attrs
      go (NVFunction r _)     = showsCon1 "NVFunction" (() <$ r)
      go (NVLiteralPath p)    = showsCon1 "NVLiteralPath" p
      go (NVEnvPath p)        = showsCon1 "NVEnvPath" p
      go (NVBuiltin name _)   = showsCon1 "NVBuiltin" name

      showsCon1 :: Show a => String -> a -> Int -> String -> String
      showsCon1 con a d =
          showParen (d > 10) $ showString (con ++ " ") . showsPrec 11 a

      showsCon2 :: (Show a, Show b)
                => String -> a -> b -> Int -> String -> String
      showsCon2 con a b d =
          showParen (d > 10)
              $ showString (con ++ " ")
              . showsPrec 11 a
              . showString " "
              . showsPrec 11 b

type ValueSet m = Map.Map Text (NThunk m)

builtin :: MonadNix m => String -> (NThunk m -> m (NThunk m)) -> m (NThunk m)
builtin name f = valueRef $ NVBuiltin name f

builtin2 :: MonadNix m
         => String -> (NThunk m -> NThunk m -> m (NThunk m)) -> m (NThunk m)
builtin2 name f = builtin name (builtin name . f)

valueText :: Functor m => NValueNF m -> (Text, DList Text)
valueText = cata phi where
    phi (NVConstant a)    = (atomText a, mempty)
    phi (NVStr t c)       = (t, c)
    phi (NVList _)        = error "Cannot coerce a list to a string"
    phi (NVSet set)
      | Just asString <- Map.lookup "__asString" set = asString
      | otherwise = error "Cannot coerce a set to a string"
    phi (NVFunction _ _)  = error "Cannot coerce a function to a string"
    phi (NVLiteralPath p) = (Text.pack p, mempty)
    phi (NVEnvPath p)     = (Text.pack p, mempty)
    phi (NVBuiltin _ _)    = error "Cannot coerce a function to a string"

valueTextNoContext :: Functor m => NValueNF m -> Text
valueTextNoContext = fst . valueText

-- | Translate an atom into its nix representation.
atomText :: NAtom -> Text
atomText (NInt i)   = Text.pack (show i)
atomText (NBool b)  = if b then "true" else "false"
atomText NNull      = "null"
atomText (NUri uri) = uri

class Monad m => MonadNix m where
    data NThunk m :: *
    pushScope  :: ValueSet m -> m r -> m r
    lookupVar  :: Text -> m (Maybe (NThunk m))
    importFile :: NThunk m -> m (NThunk m)

    buildThunk :: m (NValue m) -> m (NThunk m)
    forceThunk :: NThunk m -> m (NValue m)

    valueRef :: NValue m -> m (NThunk m)
    valueRef = buildThunk . return

wrap :: MonadNix m => NValueNF m -> m (NValue m)
wrap = cata phi
  where
    phi :: NValueF m (m (NValue m)) -> m (NValue m)
    phi = undefined

buildArgument :: forall m. MonadNix m
              => Params (m (NThunk m)) -> NThunk m -> m (ValueSet m)
buildArgument params arg = case params of
    Param name -> return $ Map.singleton name arg
    ParamSet (FixedParamSet s) m -> go s m
    ParamSet (VariadicParamSet s) m -> go s m
  where
    go s m = forceThunk arg >>= \case
        NVSet args -> do
            let res = loeb (alignWithKey assemble args s)
            maybe (pure res) (selfInject res) m
        x -> error $ "Expected set in function call, received: "
                ++ show (() <$ x)

    selfInject :: ValueSet m -> Text -> m (ValueSet m)
    selfInject res n = do
        ref <- valueRef (NVSet res)
        return $ Map.insert n ref res

    assemble :: Text
             -> These (NThunk m) (Maybe (NThunk m))
             -> Map.Map Text (m (NThunk m))
             -> m (NThunk m)
    assemble k = \case
        That Nothing  -> error $ "Missing value for parameter: " ++ show k
        That (Just f) -> \env -> buildThunk $ pushScope env f
        This x        -> const (pure x)
        These x _     -> const (pure x)

-- | Evaluate an nix expression, with a given ValueSet as environment
evalExpr :: MonadNix m => NExpr -> m (NThunk m)
evalExpr = cata eval

eval :: MonadNix m => NExprF (m (NThunk m)) -> m (NThunk m)

eval (NSym var) =
    fromMaybe (error $ "Undefined variable: " ++ show var) <$> lookupVar var

eval (NConstant x)    = valueRef $ NVConstant x
eval (NStr str)       = evalString str
eval (NLiteralPath p) = valueRef $ NVLiteralPath p
eval (NEnvPath p)     = valueRef $ NVEnvPath p

eval (NUnary op arg) = arg >>= forceThunk >>= \case
    NVConstant c -> valueRef $ NVConstant $ case (op, c) of
        (NNeg, NInt  i) -> NInt  (-i)
        (NNot, NBool b) -> NBool (not b)
        _ -> error $ "unsupported argument type for unary operator "
                 ++ show op
    _ -> error "argument to unary operator must evaluate to an atomic type"

eval (NBinary op larg rarg) = do
  lval <- forceThunk =<< larg
  rval <- forceThunk =<< rarg
  let unsupportedTypes =
          "unsupported argument types for binary operator "
              ++ show (() <$ lval, op, () <$ rval)
  case (lval, rval) of
   (NVConstant lc, NVConstant rc) ->
       valueRef $ NVConstant $ case (op, lc, rc) of
     (NEq,  l, r) -> NBool $ l == r
     (NNEq, l, r) -> NBool $ l /= r
     (NLt,  l, r) -> NBool $ l <  r
     (NLte, l, r) -> NBool $ l <= r
     (NGt,  l, r) -> NBool $ l >  r
     (NGte, l, r) -> NBool $ l >= r
     (NAnd,  NBool l, NBool r) -> NBool $ l && r
     (NOr,   NBool l, NBool r) -> NBool $ l || r
     (NImpl, NBool l, NBool r) -> NBool $ not l || r
     (NPlus,  NInt l, NInt r) -> NInt $ l + r
     (NMinus, NInt l, NInt r) -> NInt $ l - r
     (NMult,  NInt l, NInt r) -> NInt $ l * r
     (NDiv,   NInt l, NInt r) -> NInt $ l `div` r
     _ -> error unsupportedTypes
   (NVStr ls lc, NVStr rs rc) -> case op of
     NPlus -> valueRef $ NVStr (ls `mappend` rs) (lc `mappend` rc)
     _ -> error unsupportedTypes
   (NVSet ls, NVSet rs) -> case op of
     NUpdate -> valueRef $ NVSet $ rs `Map.union` ls
     _ -> error unsupportedTypes
   (NVList ls, NVList rs) -> case op of
     NConcat -> valueRef $ NVList $ ls ++ rs
     _ -> error unsupportedTypes
   (NVLiteralPath ls, NVLiteralPath rs) -> case op of
     NPlus -> valueRef $ NVLiteralPath $ ls ++ rs -- TODO: Canonicalise path
     _ -> error unsupportedTypes
   (NVLiteralPath ls, NVStr rs rc) -> case op of
     -- TODO: Canonicalise path
     NPlus -> valueRef $ NVStr (Text.pack ls `mappend` rs) rc
     _ -> error unsupportedTypes
   _ -> error unsupportedTypes

eval (NSelect aset attr alternative) = do
    aset' <- normalForm =<< aset
    ks <- evalSelector True attr
    case extract aset' ks of
        Just v  -> valueRef =<< wrap v
        Nothing -> case alternative of
            Just v  -> v
            Nothing -> error $ "could not look up attribute "
                ++ intercalate "." (map Text.unpack ks)
                ++ " in " ++ show aset'
  where
    extract (Fix (NVSet s)) (k:ks) = case Map.lookup k s of
        Just v  -> extract v ks
        Nothing -> Nothing
    extract _  (_:_) = Nothing
    extract v     [] = Just v

eval (NHasAttr aset attr) = aset >>= forceThunk >>= \case
    NVSet s -> evalSelector True attr >>= \case
        [keyName] -> valueRef $ NVConstant $ NBool $ keyName `Map.member` s
        _ -> error "attr name argument to hasAttr is not a single-part name"
    _ -> error "argument to hasAttr has wrong type"

eval (NList l) = valueRef $ NVList l

eval (NSet binds) =
    valueRef . NVSet =<< evalBinds True False binds

eval (NRecSet binds) =
    valueRef . NVSet =<< evalBinds True True binds

eval (NLet binds e) = do
    s <- evalBinds True True binds
    pushScope s e

eval (NIf cond t f) = cond >>= forceThunk >>= \case
    NVConstant (NBool True) -> t
    NVConstant (NBool False) -> f
    _ -> error "condition must be a boolean"

eval (NWith scope e) = scope >>= forceThunk >>= \case
    NVSet scope' -> pushScope scope' e
    _ -> error "scope must be a set in with statement"

eval (NAssert cond e) = cond >>= forceThunk >>= \case
    NVConstant (NBool True) -> e
    NVConstant (NBool False) -> error "assertion failed"
    _ -> error "assertion condition must be boolean"

eval (NApp fun arg) = fun >>= forceThunk >>= \case
    NVFunction params f -> do
        args <- buildArgument params =<< arg
        traceM $ "args = " ++ show (() <$ args)
        pushScope args f
    NVBuiltin _ f -> f =<< arg
    _ -> error "Attempt to call non-function"

eval (NAbs a b) =
    -- It is the environment at the definition site, not the call site, that
    -- needs to be used when evaluation the body and the default arguments
    valueRef $ NVFunction a b

tracingExprEval :: MonadNix m => NExpr -> IO (m (NThunk m))
tracingExprEval =
    fmap (runIdentity . snd) . adiM @() (pure <$> eval) psi
  where
    psi k v@(Fix x) = do
        putStrLn $ "Evaluating: " ++ show x
        k v

exprNormalForm :: MonadNix m => NExpr -> m (NValueNF m)
exprNormalForm = normalForm <=< evalExpr

normalForm :: MonadNix m => NThunk m -> m (NValueNF m)
normalForm x = forceThunk x >>= \case
    NVConstant a     -> return $ Fix $ NVConstant a
    NVStr t s        -> return $ Fix $ NVStr t s
    NVList l         -> Fix . NVList <$> (traverse normalForm =<< sequence l)
    NVSet s          -> Fix . NVSet <$> (traverse normalForm =<< sequence s)
    NVFunction p f   -> do
        p' <- traverse normalForm =<< sequence p
        f' <- normalForm =<< f
        return $ Fix $ NVFunction p' f'
    NVLiteralPath fp -> return $ Fix $ NVLiteralPath fp
    NVEnvPath p      -> return $ Fix $ NVEnvPath p
    NVBuiltin name f -> return $ Fix $ NVBuiltin name f

attrSetAlter :: MonadNix m
             => [Text]
             -> ValueSet m
             -> (Maybe (NThunk m) -> m (Maybe (NThunk m)))
             -> m (ValueSet m, Maybe (NThunk m))
attrSetAlter [] _ _ = error "invalid selector with no components"
attrSetAlter (p:ps) m f = case Map.lookup p m of
    Nothing | null ps -> go Nothing
            | otherwise -> recurse Map.empty
    Just v  | null ps -> go . Just =<< v
            | otherwise -> v >>= forceThunk >>= \case
                  NVSet s -> recurse s
                  _ -> error $ "attribute " ++ attr ++ " is not a set"
  where
    attr = show (Text.intercalate "." (p:ps))

    go mx = f mx >>= \case
        Nothing -> return (m, Nothing)
        Just v' -> return (Map.insert p (pure v') m, Just v')

    recurse s = attrSetAlter ps s f >>= \case
        (m', mres)
            | Map.null m' -> return (m, mres)
            | otherwise ->
                  return (Map.insert p (valueRef (NVSet m')) m, mres)

evalBinds :: forall m. MonadNix m
          => Bool
          -> Bool
          -> [Binding (m (NThunk m))]
          -> m (ValueSet m)
evalBinds allowDynamic recursive = buildResult . concat <=< mapM go
  where
    -- TODO: Inherit
    go :: Binding (m (NThunk m)) -> m [([Text], m (NThunk m))]
    go (NamedVar x y) =
        sequence [liftM2 (,) (evalSelector allowDynamic x) (pure y)]
    go _ = pure [] -- HACK! But who cares right now

    buildResult :: [([Text], m (NThunk m))] -> m (ValueSet m)
    buildResult bindings = do
        s <- foldM insert Map.empty bindings
        return $ if recursive
                 then loeb (flip pushScope <$> s)
                 else s

    insert m (path, value) =
        fst <$> attrSetAlter path m (const (Just <$> value))

evalString :: MonadNix m => NString (m (NThunk m)) -> m (NThunk m)
evalString nstr = do
    let fromParts parts = do
          (t, c) <- mconcat <$> mapM go parts
          valueRef $ NVStr t c
    case nstr of
      Indented     parts -> fromParts parts
      DoubleQuoted parts -> fromParts parts
  where
    go = runAntiquoted (return . (, mempty)) (fmap valueText . (normalForm =<<))

evalSelector :: MonadNix m => Bool -> NAttrPath (m (NThunk m)) -> m [Text]
evalSelector dyn = mapM evalKeyName where
  evalKeyName (StaticKey k) = return k
  evalKeyName (DynamicKey k)
    | dyn       = do
          v  <- runAntiquoted evalString id k
          valueTextNoContext <$> normalForm v
    | otherwise = error "dynamic attribute not allowed in this context"

nullVal :: MonadNix m => m (NThunk m)
nullVal = valueRef (NVConstant NNull)

-- | Evaluate an nix expression, with a given ValueSet as environment
checkExpr :: MonadNix m => NExpr -> m ()
checkExpr = cata check

check :: MonadNix m => NExprF (m ()) -> m ()

check (NSym var) = lookupVar var >>= \case
    Nothing -> error $ "Undefined variable: " ++ show var
    Just _ -> return ()

check (NSet binds) =
    void $ evalBinds True False (fmap (fmap (const nullVal)) binds)

check (NRecSet binds) =
    void $ evalBinds True True (fmap (fmap (const nullVal)) binds)

check (NLet binds e) =
    (`pushScope` e) =<< evalBinds True True (fmap (fmap (const nullVal)) binds)

check (NAbs a b) = case a of
    Param name ->
        pushScope (Map.singleton name nullVal) b
    ParamSet (FixedParamSet s) Nothing ->
        pushScope (nullVal <$ s) b
    ParamSet (FixedParamSet s) (Just m) ->
        pushScope (Map.insert m nullVal (nullVal <$ s)) b
    ParamSet (VariadicParamSet s) Nothing ->
        pushScope (nullVal <$ s) b
    ParamSet (VariadicParamSet s) (Just m) ->
        pushScope (Map.insert m nullVal (nullVal <$ s)) b

-- In order to check some of the other operations properly, we'd need static
-- typing
check _ = return ()
