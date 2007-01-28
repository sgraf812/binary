{-# OPTIONS_GHC -fglasgow-exts #-}
-- for unboxed shifts

-----------------------------------------------------------------------------
-- |
-- Module      : Data.Binary.Get
-- Copyright   : Lennart Kolmodin
-- License     : BSD3-style (see LICENSE)
-- 
-- Maintainer  : Lennart Kolmodin <kolmodin@dtek.chalmers.se>
-- Stability   : experimental
-- Portability : portable to Hugs and GHC.
--
-- The Get monad. A monad for efficiently building structures from
-- encoded lazy ByteStrings
--
-----------------------------------------------------------------------------

#if defined(__GLASGOW_HASKELL__) && !defined(__HADDOCK__)
#include "MachDeps.h"
#endif

module Data.Binary.Get (

    -- * The Get type
      Get
    , runGet

    -- * Parsing
    , skip
    , uncheckedSkip
    , lookAhead
    , lookAheadM
    , lookAheadE
    , uncheckedLookAhead

    , getBytes
    , remaining
    , isEmpty

    -- * Parsing particular types
    , getWord8

    -- ** ByteStrings
    , getByteString
    , getLazyByteString

    -- ** Big-endian reads
    , getWord16be
    , getWord32be
    , getWord64be

    -- ** Little-endian reads
    , getWord16le
    , getWord32le
    , getWord64le

    -- ** Host-endian, unaligned reads
    , getWordhost
    , getWord16host
    , getWord32host
    , getWord64host

  ) where

import Control.Monad (liftM,when)
import Data.Maybe (isNothing)

import qualified Data.ByteString as B
import qualified Data.ByteString.Base as B
import qualified Data.ByteString.Lazy as L

import Foreign

-- used by splitAtST
import Control.Monad.ST
import Data.STRef

#if defined(__GLASGOW_HASKELL__) && !defined(__HADDOCK__)
import GHC.Base
import GHC.Word
import GHC.Int
#endif

-- | The parse state
data S = S {-# UNPACK #-} !L.ByteString  -- the rest of the input
           {-# UNPACK #-} !Int64         -- bytes read

-- | The Get monad is just a State monad carrying around the input ByteString
newtype Get a = Get { unGet :: S -> (a, S ) }

instance Functor Get where
    fmap f m = Get (\s -> let (a, s') = unGet m s
                          in (f a, s'))

instance Monad Get where
    return a  = Get (\s -> (a, s))
    m >>= k   = Get (\s -> let (a, s') = unGet m s
                           in unGet (k a) s')
    fail      = failDesc

------------------------------------------------------------------------

get :: Get S
get   = Get (\s -> (s, s))

put :: S -> Get ()
put s = Get (\_ -> ((), s))

------------------------------------------------------------------------

-- | Run the Get monad applies a 'get'-based parser on the input ByteString
runGet :: Get a -> L.ByteString -> a
runGet m str = case unGet m (S str 0) of (a, _) -> a

------------------------------------------------------------------------

failDesc :: String -> Get a
failDesc err = do
    S _ bytes <- get
    Get (error (err ++ ". Failed reading at byte position " ++ show bytes))

-- | Skip ahead @n@ bytes. Fails if fewer than @n@ bytes are available.
skip :: Int -> Get ()
skip n = readN (fromIntegral n) (const ())

-- | Skip ahead @n@ bytes. 
uncheckedSkip :: Int64 -> Get ()
uncheckedSkip n = do
    S s bytes <- get
    let rest = L.drop n s
    put $! S rest (bytes + n)
    return ()

-- | Run @ga@, but return without consuming its input.
-- Fails if @ga@ fails.
lookAhead :: Get a -> Get a
lookAhead ga = do
    s <- get
    a <- ga
    put s
    return a

-- | Like 'lookAhead', but consume the input if @gma@ returns 'Just _'.
-- Fails if @gma@ fails.
lookAheadM :: Get (Maybe a) -> Get (Maybe a)
lookAheadM gma = do
    s <- get
    ma <- gma
    when (isNothing ma) $
        put s
    return ma

-- | Like 'lookAhead', but consume the input if @gea@ returns 'Right _'.
-- Fails if @gea@ fails.
lookAheadE :: Get (Either a b) -> Get (Either a b)
lookAheadE gea = do
    s <- get
    ea <- gea
    case ea of
        Left _ -> put s
        _      -> return ()
    return ea

-- | Get the next up to @n@ bytes as a lazy ByteString, without consuming them. 
uncheckedLookAhead :: Int64 -> Get L.ByteString
uncheckedLookAhead n = do
    S s _ <- get
    return $ L.take n s

-- | Get the number of remaining unparsed bytes.
-- Useful for checking whether all input has been consumed.
-- Note that this forces the rest of the input.
remaining :: Get Int64
remaining = do
    S s _ <- get
    return (L.length s)

-- | Test whether all input has been consumed,
-- i.e. there are no remaining unparsed bytes.
isEmpty :: Get Bool
isEmpty = do
    S s _ <- get
    return (L.null s)

------------------------------------------------------------------------
-- Helpers

-- | Fail if the ByteString does not have the right size.
takeExactly :: Int64 -> L.ByteString -> Get L.ByteString
takeExactly n bs
    | l == n    = return bs
    | otherwise = fail $ concat [ "Data.Binary.Get.takeExactly: Wanted "
                                , show n, " bytes, found ", show l, "." ]
  where l = L.length bs
{-# INLINE takeExactly #-}

-- | Pull @n@ bytes from the input, as a lazy ByteString. If not enough
-- bytes are available, as much as possible will be returned. No error
-- will be thrown.
getBytes :: Int64 -> Get L.ByteString
getBytes n = do
    S s bytes <- get
    case splitAtST n s of
      (consuming, rest) -> 
          do put $! (S rest (bytes + n)) -- n should be L.length consuming, but that
                                         -- would destory the laziness
             return consuming
{-# INLINE getBytes #-}
-- ^ important

-- | Split a ByteString. If the first result is consumed before the
-- second, this runs in constant heap space.
-- NOTE: you must force the returned tuple for that to work, e.g.
-- > case splitAtST n xs of
-- >   (ys,zs) -> consume ys ... consume zs
splitAtST :: Int64 -> L.ByteString -> (L.ByteString, L.ByteString)
splitAtST i p        | i <= 0 = (L.empty, p)
splitAtST i (B.LPS ps) = runST (
     do r <- newSTRef undefined
        xs <- first r i ps
        ys <- unsafeInterleaveST (readSTRef r)
        return (B.LPS xs, B.LPS ys))
  where first r 0 xs     = writeSTRef r xs >> return []
        first r _ []     = writeSTRef r [] >> return []
        first r n (x:xs)
          | n < l     = do writeSTRef r (B.drop (fromIntegral n) x : xs)
                           return [B.take (fromIntegral n) x]
          | otherwise = do writeSTRef r (L.toChunks (L.drop (n - l) (B.LPS xs)))
                           fmap (x:) $ unsafeInterleaveST (first r (n - l) xs)
         where l = fromIntegral (B.length x) 

-- Pull n bytes from the input, and apply a parser to those bytes,
-- yielding a value. If less than @n@ bytes are available, fail with an
-- error. This wraps @getBytes@.
readN :: Int64 -> (L.ByteString -> a) -> Get a
readN n f = liftM f (getBytes n >>= takeExactly n)
{-# INLINE readN #-}
-- ^ important

------------------------------------------------------------------------

-- | An efficient 'get' method for strict ByteStrings. Fails if fewer
-- than @n@ bytes are left in the input.
getByteString :: Int -> Get B.ByteString
getByteString n = readN (fromIntegral n) (B.concat . L.toChunks)
{-# INLINE getByteString #-}

-- | An efficient 'get' method for lazy ByteStrings. Fails if fewer than
-- @n@ bytes are left in the input.
getLazyByteString :: Int -> Get L.ByteString
getLazyByteString n = readN (fromIntegral n) id
{-# INLINE getLazyByteString #-}

------------------------------------------------------------------------
-- Primtives

-- | Read a Word8 from the monad state
getWord8 :: Get Word8
getWord8 = readN 1 L.head
{-# INLINE getWord8 #-}

-- | Read a Word16 in big endian format
getWord16be :: Get Word16
getWord16be = do
    s <- readN 2 (L.take 2)
    return $! (fromIntegral (s `L.index` 0) `shiftl_w16` 8) .|.
              (fromIntegral (s `L.index` 1))
{-# INLINE getWord16be #-}

-- | Read a Word16 in little endian format
getWord16le :: Get Word16
getWord16le = do
    w1 <- liftM fromIntegral getWord8
    w2 <- liftM fromIntegral getWord8
    return $! w2 `shiftl_w16` 8 .|. w1
{-# INLINE getWord16le #-}

-- | Read a Word32 in big endian format
getWord32be :: Get Word32
getWord32be = do
    s <- readN 4 (L.take 4)
    return $! (fromIntegral (s `L.index` 0) `shiftl_w32` 24) .|.
              (fromIntegral (s `L.index` 1) `shiftl_w32` 16) .|.
              (fromIntegral (s `L.index` 2) `shiftl_w32`  8) .|.
              (fromIntegral (s `L.index` 3) )
{-# INLINE getWord32be #-}

-- | Read a Word32 in little endian format
getWord32le :: Get Word32
getWord32le = do
    w1 <- liftM fromIntegral getWord8
    w2 <- liftM fromIntegral getWord8
    w3 <- liftM fromIntegral getWord8
    w4 <- liftM fromIntegral getWord8
    return $! (w4 `shiftl_w32` 24) .|.
              (w3 `shiftl_w32` 16) .|.
              (w2 `shiftl_w32`  8) .|.
              (w1)
{-# INLINE getWord32le #-}

-- | Read a Word64 in big endian format
getWord64be :: Get Word64
getWord64be = do
    s <- readN 8 (L.take 8)
    return $! (fromIntegral (s `L.index` 0) `shiftl_w64` 56) .|.
              (fromIntegral (s `L.index` 1) `shiftl_w64` 48) .|.
              (fromIntegral (s `L.index` 2) `shiftl_w64` 40) .|.
              (fromIntegral (s `L.index` 3) `shiftl_w64` 32) .|.
              (fromIntegral (s `L.index` 4) `shiftl_w64` 24) .|.
              (fromIntegral (s `L.index` 5) `shiftl_w64` 16) .|.
              (fromIntegral (s `L.index` 6) `shiftl_w64`  8) .|.
              (fromIntegral (s `L.index` 7) )
{-# INLINE getWord64be #-}

-- | Read a Word64 in little endian format
getWord64le :: Get Word64
getWord64le = do
    w1 <- liftM fromIntegral getWord8
    w2 <- liftM fromIntegral getWord8
    w3 <- liftM fromIntegral getWord8
    w4 <- liftM fromIntegral getWord8
    w5 <- liftM fromIntegral getWord8
    w6 <- liftM fromIntegral getWord8
    w7 <- liftM fromIntegral getWord8
    w8 <- liftM fromIntegral getWord8
    return $! (w8 `shiftl_w64` 56) .|.
              (w7 `shiftl_w64` 48) .|.
              (w6 `shiftl_w64` 40) .|.
              (w5 `shiftl_w64` 32) .|.
              (w4 `shiftl_w64` 24) .|.
              (w3 `shiftl_w64` 16) .|.
              (w2 `shiftl_w64`  8) .|.
              (w1)
{-# INLINE getWord64le #-}

------------------------------------------------------------------------
-- Host-endian reads

-- helper, get a raw Ptr onto a strict ByteString copied out of the
-- underlying lazy byteString. So many indirections from the raw parser
-- state that my head hurts...

getPtr :: Storable a => Int -> Get a
getPtr n = do
    (fp,o,_) <- liftM B.toForeignPtr (getByteString n)
    return . B.inlinePerformIO $ withForeignPtr fp $ \p -> peek (castPtr $ p `plusPtr` o)
{-# INLINE getPtr #-}
{-# SPECIALISE getPtr :: Int -> Get Word #-}
{-# SPECIALISE getPtr :: Int -> Get Word16 #-}
{-# SPECIALISE getPtr :: Int -> Get Word32 #-}
{-# SPECIALISE getPtr :: Int -> Get Word64 #-}

-- | /O(1)./ Read a single native machine word. The word is read in
-- host order, host endian form, for the machine you're on. On a 64 bit
-- machine the Word is an 8 byte value, on a 32 bit machine, 4 bytes.
getWordhost :: Get Word
getWordhost =
#if WORD_SIZE_IN_BITS < 64
    getPtr 4
#else
    getPtr 8
#endif
{-# INLINE getWordhost #-}

-- | /O(1)./ Read a 2 byte Word16 in native host order and host endianness.
getWord16host :: Get Word16
getWord16host = getPtr 2
{-# INLINE getWord16host #-}

-- | /O(1)./ Read a Word32 in native host order and host endianness.
getWord32host :: Get Word32
getWord32host = getPtr 4
{-# INLINE getWord32host #-}

-- | /O(1)./ Read a Word64 in native host order.
-- On a 32 bit machine two host order Word32s are read in big endian form.
getWord64host   :: Get Word64
getWord64host = do
#if WORD_SIZE_IN_BITS < 64
    w1 <- getPtr 4 :: Get Word32
    w2 <- getPtr 4 :: Get Word32
    return $! (shiftl_w64 (fromIntegral w1) 32 .|. fromIntegral w2)
#else
    getPtr 8
#endif
{-# INLINE getWord64host #-}

------------------------------------------------------------------------
-- Unchecked shifts

shiftl_w16 :: Word16 -> Int -> Word16
shiftl_w32 :: Word32 -> Int -> Word32
shiftl_w64 :: Word64 -> Int -> Word64

#if defined(__GLASGOW_HASKELL__) && !defined(__HADDOCK__)
shiftl_w16 (W16# w) (I# i) = W16# (w `uncheckedShiftL#`   i)
shiftl_w32 (W32# w) (I# i) = W32# (w `uncheckedShiftL#`   i)

#if WORD_SIZE_IN_BITS < 64
shiftl_w64 (W64# w) (I# i) = W64# (w `uncheckedShiftL64#` i)

foreign import ccall unsafe "stg_uncheckedShiftL64"     
    uncheckedShiftL64#     :: Word64# -> Int# -> Word64#
#else
shiftl_w64 (W64# w) (I# i) = W64# (w `uncheckedShiftL#` i)
#endif

#else
shiftl_w16 = shiftL
shiftl_w32 = shiftL
shiftl_w64 = shiftL
#endif
