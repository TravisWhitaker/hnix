{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Nix.Utils (module Nix.Utils, module X) where

import           Control.Arrow ((&&&))
import           Control.Monad
import           Control.Monad.Fix
import qualified Data.Aeson as A
import qualified Data.Aeson.Encoding as A
import           Data.Bits
import           Data.ByteString (ByteString)
import qualified Data.ByteString as B
import           Data.Fix
import           Data.HashMap.Lazy (HashMap)
import qualified Data.HashMap.Lazy as M
import           Data.List (sortOn)
import           Data.Monoid (Endo, (<>))
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector as V
import           Lens.Family2 as X
import           Lens.Family2.Stock (_1, _2)

#if ENABLE_TRACING
import           Debug.Trace as X
#else
import           Prelude as X hiding (putStr, putStrLn, print)
trace :: String -> a -> a
trace = const id
traceM :: Monad m => String -> m ()
traceM = const (return ())
#endif

type DList a = Endo [a]

type AttrSet = HashMap Text

-- | An f-algebra defines how to reduced the fixed-point of a functor to a
--   value.
type Alg f a = f a -> a

type AlgM f m a = f a -> m a

-- | An "transform" here is a modification of a catamorphism.
type Transform f a = (Fix f -> a) -> Fix f -> a

(<&>) :: Functor f => f a -> (a -> c) -> f c
(<&>) = flip (<$>)

(??) :: Functor f => f (a -> b) -> a -> f b
fab ?? a = fmap ($ a) fab

loeb :: Functor f => f (f a -> a) -> f a
loeb x = go where go = fmap ($ go) x

loebM :: (MonadFix m, Traversable t) => t (t a -> m a) -> m (t a)
loebM f = mfix $ \a -> mapM ($ a) f

para :: Functor f => (f (Fix f, a) -> a) -> Fix f -> a
para f = f . fmap (id &&& para f) . unFix

paraM :: (Traversable f, Monad m) => (f (Fix f, a) -> m a) -> Fix f -> m a
paraM f = f <=< traverse (\x -> (x,) <$> paraM f x) . unFix

cataP :: Functor f => (Fix f -> f a -> a) -> Fix f -> a
cataP f x = f x . fmap (cataP f) . unFix $ x

cataPM :: (Traversable f, Monad m) => (Fix f -> f a -> m a) -> Fix f -> m a
cataPM f x = f x <=< traverse (cataPM f) . unFix $ x

transport :: Functor g => (forall x. f x -> g x) -> Fix f -> Fix g
transport f (Fix x) = Fix $ fmap (transport f) (f x)

-- | adi is Abstracting Definitional Interpreters:
--
--     https://arxiv.org/abs/1707.04755
--
--   Essentially, it does for evaluation what recursion schemes do for
--   representation: allows threading layers through existing structure, only
--   in this case through behavior.
adi :: Functor f => (f a -> a) -> ((Fix f -> a) -> Fix f -> a) -> Fix f -> a
adi f g = g (f . fmap (adi f g) . unFix)

adiM :: (Traversable t, Monad m)
     => (t a -> m a) -> ((Fix t -> m a) -> Fix t -> m a) -> Fix t -> m a
adiM f g = g ((f <=< traverse (adiM f g)) . unFix)

class Has a b where
    hasLens :: Lens' a b

instance Has a a where
    hasLens f = f

instance Has (a, b) a where
    hasLens = _1

instance Has (a, b) b where
    hasLens = _2

toEncodingSorted :: A.Value -> A.Encoding
toEncodingSorted = \case
    A.Object m ->
        A.pairs . mconcat
                . fmap (\(k, v) -> A.pair k $ toEncodingSorted v)
                . sortOn fst
                $ M.toList m
    A.Array l -> A.list toEncodingSorted $ V.toList l
    v -> A.toEncoding v

data NixPathEntryType = PathEntryPath | PathEntryURI deriving (Show, Eq)

-- | @NIX_PATH@ is colon-separated, but can also contain URLs, which have a colon
-- (i.e. @https://...@)
uriAwareSplit :: Text -> [(Text, NixPathEntryType)]
uriAwareSplit = go where
    go str = case Text.break (== ':') str of
        (e1, e2)
            | Text.null e2 -> [(e1, PathEntryPath)]
            | Text.pack "://" `Text.isPrefixOf` e2 ->
                let ((suffix, _):path) = go (Text.drop 3 e2)
                 in (e1 <> Text.pack "://" <> suffix, PathEntryURI) : path
            | otherwise -> (e1, PathEntryPath) : go (Text.drop 1 e2)

printHash32 :: ByteString -> Text
printHash32 bs = go (base32Len bs - 1) ""
  where
   go n s
     | n >= 0 = go (n-1) (Text.snoc s $ nextCharHash32 bs n)
     | otherwise = s

nextCharHash32 :: ByteString -> Int -> Char
nextCharHash32 bs n = Text.index base32Chars (c .&. 0x1f)
  where
    b = n * 5
    i = b `div` 8
    j = b `mod` 8
    c = fromIntegral $ shiftR (B.index bs i) j .|. mask
    mask = if i >= B.length bs - 1
             then 0
             else shiftL (B.index bs (i+1)) (8 - j)
    -- e, o, u, and t are omitted (see base32Chars in nix/src/libutil/hash.cc)
    base32Chars = "0123456789abcdfghijklmnpqrsvwxyz"

base32Len :: ByteString -> Int
base32Len bs = ((B.length bs * 8 - 1) `div` 5) + 1
