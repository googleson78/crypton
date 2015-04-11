-- |
-- Module      : Crypto.Cipher.Blowfish.Primitive
-- License     : BSD-style
-- Stability   : experimental
-- Portability : Good

-- Rewritten by Vincent Hanquez (c) 2015
--
-- Original code:
--      Crypto.Cipher.Blowfish.Primitive, copyright (c) 2012 Stijn van Drongelen
--      based on: BlowfishAux.hs (C) 2002 HardCore SoftWare, Doug Hoyte
--           (as found in Crypto-4.2.4)

module Crypto.Cipher.Blowfish.Primitive
    ( Context
    , initBlowfish
    , encrypt
    , decrypt
    ) where

import Control.Monad (forM_)
import Data.Bits
import Data.Word
import qualified Data.ByteString as B

import Crypto.Error
import Crypto.Internal.Compat
import Crypto.Internal.ByteArray
import Crypto.Internal.Words
import Crypto.Internal.WordArray
import Crypto.Cipher.Blowfish.Box

-- | variable keyed blowfish state
data Context = BF (Int -> Word32) -- p
                  (Int -> Word32) -- sbox0
                  (Int -> Word32) -- sbox1
                  (Int -> Word32) -- sbox2
                  (Int -> Word32) -- sbox2

encrypt, decrypt :: ByteArray ba => Context -> ba -> ba
encrypt = cipher
decrypt = cipher . decryptContext

decryptContext :: Context -> Context
decryptContext (BF p s0 s1 s2 s3) = BF (\i -> p (17-i)) s0 s1 s2 s3

cipher :: ByteArray ba => Context -> ba -> ba
cipher ctx b
    | byteArrayLength b == 0         = empty
    | byteArrayLength b `mod` 8 /= 0 = error "invalid data length"
    | otherwise                      = byteArrayMapAsWord64 (coreCrypto ctx) b

initBlowfish :: ByteArray key => key -> CryptoFailable Context
initBlowfish key
    | len > (448 `div` 8) = CryptoFailed $ CryptoError_KeySizeInvalid
    | len == 0            = keyFromByteString (B.replicate (18*4) 0)
    | otherwise           = keyFromByteString . B.pack . take (18*4) . cycle . B.unpack . byteArrayToBS $ key
  where len = byteArrayLength key

keyFromByteString :: B.ByteString -> CryptoFailable Context
keyFromByteString k
    | B.length k /= (18 * 4) = CryptoFailed CryptoError_KeySizeInvalid
    | otherwise              = CryptoPassed . makeKeySchedule . w8tow32 . B.unpack $ k
  where
    w8tow32 :: [Word8] -> [Word32]
    w8tow32 [] = []
    w8tow32 (a:b:c:d:xs) = ( (fromIntegral a `shiftL` 24) .|.
                             (fromIntegral b `shiftL` 16) .|.
                             (fromIntegral c `shiftL`  8) .|.
                             (fromIntegral d) ) : w8tow32 xs
    w8tow32 _ = error $ "internal error: Crypto.Cipher.Blowfish:keyFromByteString"

coreCrypto :: Context -> Word64 -> Word64
coreCrypto (BF p s0 s1 s2 s3) input = doRound input 0
  where
    -- transform the input @i over 16 rounds
    doRound :: Word64 -> Int -> Word64
    doRound i roundIndex
        | roundIndex == 16 =
            let final = (fromIntegral (p 16) `shiftL` 32) .|. fromIntegral (p 17)
             in rotateL (i `xor` final) 32
        | otherwise     =
            let newr = fromIntegral (i `shiftR` 32) `xor` (p roundIndex)
                newi = ((i `shiftL` 32) `xor` (f newr)) .|. (fromIntegral newr)
             in doRound newi (roundIndex+1)

    f   :: Word32 -> Word64
    f t = let a = s0 (fromIntegral $ (t `shiftR` 24) .&. 0xff)
              b = s1 (fromIntegral $ (t `shiftR` 16) .&. 0xff)
              c = s2 (fromIntegral $ (t `shiftR` 8) .&. 0xff)
              d = s3 (fromIntegral $ t .&. 0xff)
           in fromIntegral (((a + b) `xor` c) + d) `shiftL` 32

makeKeySchedule :: [Word32] -> Context
makeKeySchedule key =
    let v = unsafeDoIO $ do
              mv <- createKeySchedule
              forM_ (zip key [0..17]) $ \(k, i) -> mutableArrayWriteXor32 mv i k
              prepare mv
              mutableArray32Freeze mv
     in BF (\i -> arrayRead32 v i)
           (\i -> arrayRead32 v (s0+i))
           (\i -> arrayRead32 v (s1+i))
           (\i -> arrayRead32 v (s2+i))
           (\i -> arrayRead32 v (s3+i))
  where
        s0 = 18
        s1 = 274
        s2 = 530
        s3 = 786

        prepare mctx = loop 0 0
          where loop i input
                  | i == 1042   = return ()
                  | otherwise = do
                      ninput <- coreCryptoMutable input
                      let (nl, nr) = w64to32 ninput
                      mutableArrayWrite32 mctx i     nl
                      mutableArrayWrite32 mctx (i+1) nr
                      loop (i+2) ninput

                coreCryptoMutable :: Word64 -> IO Word64
                coreCryptoMutable input = doRound input 0
                  where doRound i roundIndex
                          | roundIndex == 16 = do
                              pVal1 <- mutableArrayRead32 mctx 16
                              pVal2 <- mutableArrayRead32 mctx 17
                              let final = (fromIntegral pVal1 `shiftL` 32) .|. fromIntegral pVal2
                              return $ rotateL (i `xor` final) 32
                          | otherwise     = do
                              pVal <- mutableArrayRead32 mctx roundIndex
                              let newr = fromIntegral (i `shiftR` 32) `xor` pVal
                              newr' <- f newr
                              let newi = ((i `shiftL` 32) `xor` newr') .|. (fromIntegral newr)
                              doRound newi (roundIndex+1)


                f   :: Word32 -> IO Word64
                f t = do a <- mutableArrayRead32 mctx (s0 + fromIntegral ((t `shiftR` 24) .&. 0xff))
                         b <- mutableArrayRead32 mctx (s1 + fromIntegral ((t `shiftR` 16) .&. 0xff))
                         c <- mutableArrayRead32 mctx (s2 + fromIntegral ((t `shiftR` 8) .&. 0xff))
                         d <- mutableArrayRead32 mctx (s3 + fromIntegral (t .&. 0xff))
                         return (fromIntegral (((a + b) `xor` c) + d) `shiftL` 32)
