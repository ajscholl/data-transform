{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE Trustworthy            #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE UndecidableInstances   #-}
-----------------------------------------------------------------------------
-- |
-- Copyright   :  (c) 2014 Jonas Scholl
-- License     :  BSD3
--
-- Maintainer  :  jonas.scholl@gmx.de
-- Stability   :  experimental
-- Portability :  non-portable
--
-- This module provides a simple way to transform parts of complex data structures.
--
-----------------------------------------------------------------------------
module Data.Transform.Internal (
    -- * Types
     EndoList
    ,EndoItem
    ,EndoListM
    ,EndoMItem

    -- * Classes
    ,Transformation
    ,MonadicTransformation

    -- * Wrapper functions
    ,mkItem
    ,mkItemM

    -- * Transformation functions
    ,transform
    ,transformM
    ,unsafeTransform
    ,unsafeTransformM

    -- * Searching functions
    ,getSubterms
    ,getSubterms'
    ,getSubtermsBy
    ,getSubtermsWith
    ) where

import Data.List
import Data.Data
import Data.Monoid

import qualified Data.Semigroup as S

import Control.Monad
import Control.Monad.Writer
import Control.Monad.State

import Data.Set (Set)
import qualified Data.Set as Set

import GHC.Exts (IsList(..))
import Unsafe.Coerce

-- | Wrapper object holding some endomorphism without exposing its type.
data EndoItem where
    EndoItem :: Data a => (a -> a) -> EndoItem

-- | Heterogeneous list structure holding endomorphisms.
data EndoList where
    Nil :: EndoList
    Cons :: Data a => (a -> a) -> EndoList -> EndoList

-- | Wrapper object holding some endomorphism in a monadic context without exposing its type.
data EndoMItem m where
    EndoMItem :: (Monad m, Data a) => (a -> m a) -> EndoMItem m

-- | Heterogeneous list structure holding endomorphisms in a monadic context.
data EndoListM m where
    NilM :: EndoListM m
    ConsM :: (Monad m, Data a) => (a -> m a) -> EndoListM m -> EndoListM m

-- | Wrap a function as an 'EndoItem'.
mkItem :: Data a => (a -> a) -> EndoItem
mkItem = EndoItem

-- | Wrap a monadic function as an 'EndoMItem'.
mkItemM :: (Monad m, Data a) => (a -> m a) -> EndoMItem m
mkItemM = EndoMItem

instance S.Semigroup EndoList where
    Nil        <> b = b
    (Cons x l) <> b = Cons x (l S.<> b)

instance Monoid EndoList where
    mempty  = Nil
    mappend = (S.<>)

instance IsList EndoList where
    type Item EndoList = EndoItem
    fromList = toEndoList
    toList   = unfoldr $ \case
        Nil      -> Nothing
        Cons f l -> Just (EndoItem f, l)

instance S.Semigroup (EndoListM m) where
    NilM        <> b = b
    (ConsM x l) <> b = ConsM x (l S.<> b)

instance Monoid (EndoListM m) where
    mempty  = NilM
    mappend = (S.<>)

instance Monad m => IsList (EndoListM m) where
    type Item (EndoListM m) = EndoMItem m
    fromList = toEndoListM
    toList   = unfoldr $ \case
        NilM      -> Nothing
        ConsM f l -> Just (EndoMItem f, l)

-- | Fold a list of endomorphisms over some element. If an endomorphism needs a
--   different type than our element it is skipped. Endomorphisms later in the list
--   are applied to the result of previous applications.
--
--   The use of 'unsafeCoerce' in this function is valid. We use it to cast type
--   a to type b where a is the type of our second argument and b is the type needed
--   by f (which has type b -> b). If we can cast a to b we know a ~ b and we know
--   that x and f x have the same type, so we can coerce b back to a.
appEndoList :: Data a => EndoList -> a -> a
appEndoList Nil        a = a
appEndoList (Cons f l) a = appEndoList l $ maybe a (unsafeCoerce . f) $ cast a

-- | Same as 'appEndoList' but in a monadic context.
appEndoListM :: (Monad m, Data a) => EndoListM m -> a -> m a
appEndoListM NilM        a = pure a
appEndoListM (ConsM f l) a = maybe (pure a) (fmap unsafeCoerce . f) (cast a) >>= appEndoListM l

-- | Class of transformations, i.e. objects containing endomorphisms.
class Transformation d where
    mkEndoList :: d -> EndoList
    toEndoList :: [d] -> EndoList
    toEndoList = mconcat . map mkEndoList

-- | Monadic version of 'Transformation'.
class Monad m => MonadicTransformation d m | d -> m where
    mkEndoListM :: d -> EndoListM m
    toEndoListM :: [d] -> EndoListM m
    toEndoListM = mconcat . map mkEndoListM

instance Transformation EndoList where
    mkEndoList = id
    toEndoList = mconcat

instance Transformation EndoItem where
    mkEndoList (EndoItem f) = Cons f Nil
    toEndoList              = foldr (\ (EndoItem f) -> Cons f) Nil

instance Transformation a => Transformation [a] where
    mkEndoList = toEndoList

instance Data a => Transformation (a -> a) where
    mkEndoList f = Cons f Nil
    toEndoList   = foldr Cons Nil

instance Data a => Transformation (Endo a) where
    mkEndoList f = Cons (appEndo f) Nil
    toEndoList   = foldr (Cons . appEndo) Nil

instance Monad m => MonadicTransformation (EndoListM m) m where
    mkEndoListM = id
    toEndoListM = mconcat

instance Monad m => MonadicTransformation (EndoMItem m) m where
    mkEndoListM (EndoMItem f) = ConsM f NilM
    toEndoListM               = foldr (\ (EndoMItem f) -> ConsM f) NilM

instance (Monad m, Data a) => MonadicTransformation (a -> m a) m where
    mkEndoListM f = ConsM f NilM
    toEndoListM   = foldr ConsM NilM

-- This instance needs UndecidableInstances because it does not satisfy the coverage condition
instance MonadicTransformation a m => MonadicTransformation [a] m where
    mkEndoListM = toEndoListM

-- | Transform some data structure by applying one or more endomorphisms to the
--   data structure or any sub-term of it. Sub-terms are transformed before the
--   terms containing them are transformed. If the given endomorphisms contain
--   two or more endomorphisms working on the same type the latter endomorphisms
--   will be applied to the result of the former endomorphisms
--
--   NOTE: This function attempts to check at runtime if all given endomorphisms
--   can be applied to at least one term in the given argument. If at least one
--   endomorphism can never be applied because of its type, 'error' is called.
--   If you don't want this behavior consider using 'unsafeTransform' instead.
--
--   Example:
--
--   >>> transform (+1) (1, 4.0, (False, [4, 5, 6]))
--   (2, 4.0, (False, [5, 6, 7]))
--
--   >>> transform [mkItem (+1), mkItem (sqrt :: Double -> Double), mkItem (*2)] (1, 4.0, (False, [4, 5, 6]))
--   (4, 2.0, (False, [10, 12, 14]))
--
--   >>> transform (+1) False
--   *** Exception: Data.DataTraverse.transform: Could not find all needed types when mapping over a value of type Bool. Types of missing terms: [Integer]
transform :: (Transformation d, Data a) => d -> a -> a
transform d a = case mkEndoList d of
    f -> case getNeededTypeReps f `Set.difference` allContainedTypeReps a of
        s | not (Set.null s) -> error $ "Data.DataTraverse.transform: Could not find all needed types when mapping over a value of type " ++ show (typeOf a) ++ ". Types of missing terms: " ++ show (Set.toList s)
          | otherwise -> unsafeTransform' f a

-- | Same as 'transform' but with a monadic function. Calls 'fail' instead of
--   'error' if a type-error is detected.
transformM :: (MonadicTransformation d m, Data a, MonadFail m) => d -> a -> m a
transformM d a = case mkEndoListM d of
    f -> case getNeededTypeRepsM f `Set.difference` allContainedTypeReps a of
        s | not (Set.null s) -> fail $ "Data.DataTraverse.transformM: Could not find all needed types when mapping over a value of type " ++ show (typeOf a) ++ ". Types of missing terms: " ++ show (Set.toList s)
          | otherwise -> unsafeTransformM' f a

-- | Same as 'transform' but omits any type checking (and hence does not call 'error').
unsafeTransform :: (Transformation d, Data a) => d -> a -> a
unsafeTransform = unsafeTransform' . mkEndoList

-- | Same as 'transformM' but omits any type checking (and hence does not call 'fail').
unsafeTransformM :: (MonadicTransformation d m, Data a) => d -> a -> m a
unsafeTransformM = unsafeTransformM' . mkEndoListM

-- | Helper function doing the actual data traversal.
unsafeTransform' :: Data a => EndoList -> a -> a
unsafeTransform' f = appEndoList f . gmapT (unsafeTransform' f)

-- | Helper function doing the actual data traversal.
unsafeTransformM' :: (Monad m, Data a) => EndoListM m -> a -> m a
unsafeTransformM' f = appEndoListM f <=< gmapM (unsafeTransformM' f)

------------------------
-- * Searching functions
------------------------

-- | Returns all sub-terms (intermediate and non intermediate) of some type of a
--   value transformed by the supplied function to some 'Monoid'.
--
--   NOTE: Calls 'error' if no sub-term which the needed type can exist.
--
--   Example:
--
--   >>> getSubterms (\ x -> if x then [x] else []) (3, 4.0, True, 'c', (False, (True, 5, 6)))
--   [True, True]
getSubterms :: (Data a, Data b, Monoid m) => (b -> m) -> a -> m
getSubterms p = getSubtermsWith (Just . p)

-- | Returns all sub-terms (intermediate and non intermediate) of some type of a
--   value as a list.
--
--   NOTE: Calls 'error' if no sub-term which the needed type can exist.
--
--   Example:
--
--   >>> getSubterms' (3, 4.0, True, 'c', (False, (True, 5, 6))) :: [Integer]
--   [3, 5, 6]
getSubterms' :: (Data a, Data b) => a -> [b]
getSubterms' = getSubtermsBy (const True)

-- | Returns all sub-terms (intermediate and non intermediate) of some type of a
--   value which fulfill the predicate.
--
--   NOTE: Calls 'error' if no sub-term which the needed type can exist.
--
--   Example:
--
--   >>> getSubtermsBy (<6) (3, 4.0, True, 'c', (False, (True, 5, 6)))
--   [3, 5]
getSubtermsBy :: (Data a, Data b) => (b -> Bool) -> a -> [b]
getSubtermsBy p = getSubtermsWith (\ x -> guard (p x) >> pure [x])

-- | Returns all sub-terms (intermediate and non intermediate) of some type of a
--   value which could be transformed to some 'Monoid'.
--
--   NOTE: Calls 'error' if no sub-term which the needed type can exist.
--
--   Example:
--
--   >>> getSubtermsWith (\ x -> guard (x < 6) >> pure [x]) (3, 4.0, True, 'c', (False, (True, 5, 6)))
--   [3, 5]
getSubtermsWith :: (Data a, Data b, Monoid m) => (b -> Maybe m) -> a -> m
getSubtermsWith p = runErrorIdentity . execWriterT . transformM (\ x -> maybe (pure ()) tell (p x) >> pure x)

newtype ErrorIdentity a = ErrorIdentity { runErrorIdentity :: a }

instance Functor ErrorIdentity where
    fmap f (ErrorIdentity a) = ErrorIdentity (f a)

instance Applicative ErrorIdentity where
    pure = ErrorIdentity
    (ErrorIdentity f) <*> (ErrorIdentity a) = ErrorIdentity (f a)

instance Monad ErrorIdentity where
    (ErrorIdentity a) >>= f = f a

instance MonadFail ErrorIdentity where
    fail = error

------------------
-- * Type checking
------------------

-- | Wrapper around data values so we can create a list of them.
data WrappedData where
    WrappedData :: Data a => a -> WrappedData

-- | Return a set of all type representations found inside a term. The term
--   is not evaluated.
allContainedTypeReps :: Data a => a -> Set TypeRep
allContainedTypeReps a = execState (allContainedTypeReps' a) Set.empty

-- | Helper function for 'allContainedTypeReps'.
allContainedTypeReps' :: Data a => a -> State (Set TypeRep) ()
allContainedTypeReps' a = do
    s <- get
    unless (Set.member (typeOf a) s) $ do
        modify (Set.insert (typeOf a))
        mapM_ helper (constructEmpties `asTypeOf` [a])
    where
        helper :: Data a => a -> State (Set TypeRep) ()
        helper x = do
            let subterms = execWriter $ gmapM (\ y -> tell [WrappedData y] >> pure y) x
            mapM_ (\ (WrappedData y) -> allContainedTypeReps' y) subterms

-- | Construct a list of empty values, one for each constructor found in the data type.
constructEmpties :: Data a => [a]
constructEmpties = helper undefined
    where
        helper :: Data a => a -> [a]
        helper a = case dataTypeOf a of
            dt -> case dataTypeRep dt of
                IntRep    -> [fromConstr $ mkIntegralConstr dt (0 :: Integer)]
                FloatRep  -> [fromConstr $ mkRealConstr dt (0 :: Rational)]
                CharRep   -> [fromConstr $ mkCharConstr dt '\0']
                AlgRep xs -> map (fromConstrB (xhead constructEmpties)) xs
                NoRep     -> []
        xhead :: Data a => [a] -> a
        xhead (x:_) = x
        xhead l@[] = error $ "Data.DataTraverse.constructEmpties.xhead: Can not construct data type " ++ show (dataTypeOf $ head l)

-- | Get the set of needed 'TypeRep's for all functions in the 'EndoList'.
getNeededTypeReps :: EndoList -> Set TypeRep
getNeededTypeReps Nil = Set.empty
getNeededTypeReps (Cons a l) = Set.insert (getTypeRep a Proxy) $ getNeededTypeReps l
    where
        getTypeRep :: Data a => (a -> a) -> Proxy a -> TypeRep
        getTypeRep _ = typeRep

-- | Get the set of needed 'TypeRep's for all functions in the 'EndoList'.
getNeededTypeRepsM :: EndoListM m -> Set TypeRep
getNeededTypeRepsM NilM = Set.empty
getNeededTypeRepsM (ConsM a l) = Set.insert (getTypeRep a Proxy) $ getNeededTypeRepsM l
    where
        getTypeRep :: Data a => (a -> m a) -> Proxy a -> TypeRep
        getTypeRep _ = typeRep
