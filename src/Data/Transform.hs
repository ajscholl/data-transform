{-# LANGUAGE Trustworthy #-}
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
module Data.Transform (
    -- * Wrapper functions
     mkItem
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

import Data.Transform.Internal