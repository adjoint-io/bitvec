{-# LANGUAGE CPP              #-}

{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}

#ifndef BITVEC_THREADSAFE
module Data.Bit.Mutable
#else
module Data.Bit.MutableTS
#endif
  ( castFromWordsM
  , castToWordsM
  , cloneToWordsM

  , zipInPlace

  , invertInPlace
  , selectBitsInPlace
  , excludeBitsInPlace

  , reverseInPlace
  ) where

import Control.Monad
import Control.Monad.Primitive
import Control.Monad.ST
#ifndef BITVEC_THREADSAFE
import Data.Bit.Internal
#else
import Data.Bit.InternalTS
#endif
import Data.Bit.Utils
import Data.Bits
import Data.Primitive.ByteArray
import qualified Data.Vector.Primitive as P
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as MU

-- | Cast a vector of words to a vector of bits.
-- Cf. 'Data.Bit.castFromWords'.
castFromWordsM :: MVector s Word -> MVector s Bit
castFromWordsM (MU.MV_Word (P.MVector off len ws)) =
  BitMVec (mulWordSize off) (mulWordSize len) ws

-- | Try to cast a vector of bits to a vector of words.
-- It succeeds if a vector of bits is aligned.
-- Use 'cloneToWordsM' otherwise.
-- Cf. 'Data.Bit.castToWords'.
castToWordsM :: MVector s Bit -> Maybe (MVector s Word)
castToWordsM (BitMVec s n ws)
  | aligned s, aligned n = Just $ MU.MV_Word $ P.MVector (divWordSize s)
                                                         (divWordSize n)
                                                         ws
  | otherwise = Nothing

-- | Clone a vector of bits to a new unboxed vector of words.
-- If the bits don't completely fill the words, the last word will be zero-padded.
-- Cf. 'Data.Bit.cloneToWords'.
cloneToWordsM
  :: PrimMonad m
  => MVector (PrimState m) Bit
  -> m (MVector (PrimState m) Word)
cloneToWordsM v = do
  let lenBits  = MU.length v
      lenWords = nWords lenBits
  w@(BitMVec _ _ arr) <- MU.unsafeNew (mulWordSize lenWords)
  MU.unsafeCopy (MU.slice 0 lenBits w) v
  MU.set (MU.slice lenBits (mulWordSize lenWords - lenBits) w) (Bit False)
  pure $ MU.MV_Word $ P.MVector 0 lenWords arr
{-# INLINE cloneToWordsM #-}

-- | Zip two vectors with the given function.
-- rewriting contents of the second argument.
-- Cf. 'Data.Bit.zipBits'.
--
-- >>> import Data.Bits
-- >>> modify (zipInPlace (.&.) (read "[1,1,0]")) (read "[0,1,1]")
-- [0,1,0]
--
-- __Warning__: if the immutable vector is shorter than the mutable one,
-- it is a caller's responsibility to trim the result:
--
-- >>> import Data.Bits
-- >>> modify (zipInPlace (.&.) (read "[1,1,0]")) (read "[0,1,1,1,1,1]")
-- [0,1,0,1,1,1] -- note trailing garbage
zipInPlace
  :: forall m.
     PrimMonad m
  => (forall a . Bits a => a -> a -> a)
  -> Vector Bit
  -> MVector (PrimState m) Bit
  -> m ()
zipInPlace f (BitVec off l xs) (BitMVec off' l' ys) =
  go (l `min` l') off off'
  where
    go :: Int -> Int -> Int -> m ()
    go len offXs offYs
      | shft == 0 =
        go' len offXs (divWordSize offYs)
      | len <= wordSize = do
        y <- readWord vecYs 0
        writeWord vecYs 0 (f x y)
      | otherwise = do
        y <- readByteArray ys base
        modifyByteArray ys base (loMask shft) (f (x `unsafeShiftL` shft) y .&. hiMask shft)
        go' (len - wordSize + shft) (offXs + wordSize - shft) (base + 1)
      where
        vecXs = BitVec  offXs len xs
        vecYs = BitMVec offYs len ys
        x     = indexWord vecXs 0
        shft  = modWordSize offYs
        base  = divWordSize offYs

    go' :: Int -> Int -> Int -> m ()
    go' len offXs offYsW = do
      if shft == 0
        then loopAligned offYsW
        else loop offYsW (indexByteArray xs base)
      when (modWordSize len /= 0) $ do
        let ix = len - modWordSize len
        let x = indexWord vecXs ix
        y <- readWord vecYs ix
        writeWord vecYs ix (f x y)

      where

        vecXs = BitVec  offXs len xs
        vecYs = BitMVec (mulWordSize offYsW) len ys
        shft  = modWordSize offXs
        shft' = wordSize - shft
        base  = divWordSize offXs
        base0 = base - offYsW
        base1 = base0 + 1
        iMax  = divWordSize len + offYsW

        loopAligned :: Int -> m ()
        loopAligned !i
          | i >= iMax = pure ()
          | otherwise =  do
            let x = indexByteArray xs (base0 + i) :: Word
            y <- readByteArray ys i
            writeByteArray ys i (f x y)
            loopAligned (i + 1)

        loop :: Int -> Word -> m ()
        loop !i !acc
          | i >= iMax = pure ()
          | otherwise =  do
            let accNew = indexByteArray xs (base1 + i)
                x = (acc `unsafeShiftR` shft) .|. (accNew `unsafeShiftL` shft')
            y <- readByteArray ys i
            writeByteArray ys i (f x y)
            loop (i + 1) accNew

#if __GLASGOW_HASKELL__ >= 800
{-# SPECIALIZE zipInPlace :: (forall a. Bits a => a -> a -> a) -> Vector Bit -> MVector s Bit -> ST s () #-}
#endif
{-# INLINE zipInPlace #-}

-- | Invert (flip) all bits in-place.
--
-- >>> Data.Vector.Unboxed.modify invertInPlace (read "[0,1,0,1,0]")
-- [1,0,1,0,1]
invertInPlace :: PrimMonad m => U.MVector (PrimState m) Bit -> m ()
invertInPlace xs = do
  let n = MU.length xs
  forM_ [0, wordSize .. n - 1] $ \i -> do
    x <- readWord xs i
    writeWord xs i (complement x)
#if __GLASGOW_HASKELL__ >= 800
{-# SPECIALIZE invertInPlace :: U.MVector s Bit -> ST s () #-}
#endif

-- | Same as 'Data.Bit.selectBits', but deposit
-- selected bits in-place. Returns a number of selected bits.
-- It is caller's resposibility to trim the result to this number.
selectBitsInPlace
  :: PrimMonad m => U.Vector Bit -> U.MVector (PrimState m) Bit -> m Int
selectBitsInPlace is xs = loop 0 0
 where
  !n = min (U.length is) (MU.length xs)
  loop !i !ct
    | i >= n = return ct
    | otherwise = do
      x <- readWord xs i
      let !(nSet, x') = selectWord (masked (n - i) (indexWord is i)) x
      writeWord xs ct x'
      loop (i + wordSize) (ct + nSet)

-- | Same as 'Data.Bit.excludeBits', but deposit
-- excluded bits in-place. Returns a number of excluded bits.
-- It is caller's resposibility to trim the result to this number.
excludeBitsInPlace
  :: PrimMonad m => U.Vector Bit -> U.MVector (PrimState m) Bit -> m Int
excludeBitsInPlace is xs = loop 0 0
 where
  !n = min (U.length is) (MU.length xs)
  loop !i !ct
    | i >= n = return ct
    | otherwise = do
      x <- readWord xs i
      let !(nSet, x') =
            selectWord (masked (n - i) (complement (indexWord is i))) x
      writeWord xs ct x'
      loop (i + wordSize) (ct + nSet)

-- | Reverse the order of bits in-place.
--
-- >>> Data.Vector.Unboxed.modify reverseInPlace (read "[1,1,0,1,0]")
-- [0,1,0,1,1]
reverseInPlace :: PrimMonad m => U.MVector (PrimState m) Bit -> m ()
reverseInPlace xs | len == 0  = pure ()
                  | otherwise = loop 0
 where
  len = MU.length xs

  loop !i
    | i' <= j' = do
      x <- readWord xs i
      y <- readWord xs j'

      writeWord xs i  (reverseWord y)
      writeWord xs j' (reverseWord x)

      loop i'
    | i' < j = do
      let w = (j - i) `shiftR` 1
          k = j - w
      x <- readWord xs i
      y <- readWord xs k

      writeWord xs i (meld w (reversePartialWord w y) x)
      writeWord xs k (meld w (reversePartialWord w x) y)

      loop i'
    | otherwise = do
      let w = j - i
      x <- readWord xs i
      writeWord xs i (meld w (reversePartialWord w x) x)
   where
    !j  = len - i
    !i' = i + wordSize
    !j' = j - wordSize
#if __GLASGOW_HASKELL__ >= 800
{-# SPECIALIZE reverseInPlace :: U.MVector s Bit -> ST s () #-}
#endif
