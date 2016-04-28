{-# LANGUAGE TupleSections, GeneralizedNewtypeDeriving #-}
module Network.MQTT.Message where

import Control.Applicative
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Exception
import Control.Monad.Catch (MonadThrow (..))
import Control.Monad

import qualified Data.Attoparsec.ByteString as A

import Data.Monoid
import Data.Bits
import Data.Function (fix)
import Data.String
import qualified Data.Source as S
import qualified Data.Source.ByteString as S
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.Encoding as LT
import Data.Word
import Data.Typeable

import Prelude

import Network.MQTT.Message.Blob
import Network.MQTT.Message.RemainingLength
import Network.MQTT.Message.Utf8String
import Network.MQTT.Message.Position

newtype ClientIdentifier = ClientIdentifier T.Text
  deriving (Eq, Ord, Show, IsString)

type SessionPresent   = Bool
type CleanSession     = Bool
type Retain           = Bool
type KeepAlive        = Word16
type Username         = T.Text
type Password         = BS.ByteString
type PacketIdentifier = Word16
type Topic            = T.Text
type TopicFilter      = T.Text

data QoS
   = AtLeastOnce
   | ExactlyOnce
   deriving (Eq, Ord, Show, Enum)

data ConnectionRefusal
   = UnacceptableProtocolVersion
   | IdentifierRejected
   | ServerUnavailable
   | BadUsernameOrPassword
   | NotAuthorized
   deriving (Eq, Ord, Show, Enum, Bounded)

data Will
   = Will
     { willTopic   :: T.Text
     , willMessage :: BS.ByteString
     , willQoS     :: Maybe QoS
     , willRetain  :: Bool
     } deriving (Eq, Show)

data Message
   = Connect
     { connectClientIdentifier :: ClientIdentifier
     , connectCleanSession     :: CleanSession
     , connectKeepAlive        :: KeepAlive
     , connectWill             :: Maybe Will
     , connectUsernamePassword :: Maybe (Username, Maybe Password)
     }
   | ConnectAcknowledgement         (Either ConnectionRefusal SessionPresent)
   | Publish
     { publishDuplicate        :: Bool
     , publishRetain           :: Bool
     , publishTopic            :: T.Text
     , publishQoS              :: Maybe (QoS, PacketIdentifier)
     , publishBody             :: BS.ByteString
     }
   | PublishAcknowledgement       PacketIdentifier
   | PublishReceived              PacketIdentifier
   | PublishRelease               PacketIdentifier
   | PublishComplete              PacketIdentifier
   | Subscribe                    PacketIdentifier [(TopicFilter, Maybe QoS)]
   | SubscribeAcknowledgement     PacketIdentifier [Maybe (Maybe QoS)]
   | Unsubscribe                  PacketIdentifier [TopicFilter]
   | UnsubscribeAcknowledgement   PacketIdentifier
   | PingRequest
   | PingResponse
   | Disconnect
   deriving (Eq, Show)

pMessage :: A.Parser Message
pMessage = do
  h   <- A.anyWord8
  len <- pRemainingLength
  let flags = h .&. 0x0f
  assureCorrentLength len $ ($ flags) $ ($ len) $ case h .&. 0xf0 of
    0x10 -> pConnect
    0x20 -> pConnectAcknowledgement
    0x30 -> pPublish
    0x40 -> pPublishAcknowledgement
    0x50 -> pPublishReceived
    0x60 -> pPublishRelease
    0x70 -> pPublishComplete
    0x80 -> pSubscribe
    0x90 -> pSubscribeAcknowledgement
    0xa0 -> pUnsubscribe
    0xb0 -> pUnsubscribeAcknowledgement
    0xc0 -> pPingRequest
    0xd0 -> pPingResponse
    0xe0 -> pDisconnect
    _    -> const $ fail "pMessage: Packet type not implemented."
  where
    assureCorrentLength len parser = do
      begin <- pPosition
      a <- parser
      end <- pPosition
      when (end - begin /= len) $
        fail $ "pMessage: Remaining length does not match expectation. Expected: "
          ++ show len  ++ ". Parsed: " ++ show (end - begin)
      pure a

pConnect :: Int -> Word8 -> A.Parser Message
pConnect len hflags
  | hflags /= 0 = fail "pConnect: The header flags are reserved and MUST be set to 0."
  | otherwise   = do
    pProtocolName
    pProtocolLevel
    flags <- pConnectFlags
    keepAlive <- pKeepAlive
    Connect
      <$> pClientIdentifier
      <*> pure (flags .&. 0x02 /= 0)
      <*> pure keepAlive
      <*> pWill flags
      <*> pUsernamePassword flags
  where
    pProtocolName  = A.word8 0x00 >> A.word8 0x04 >> A.word8 0x4d >>
                     A.word8 0x51 >> A.word8 0x54 >> A.word8 0x54 >> pure ()
    pProtocolLevel = A.word8 0x04 >> pure ()
    pConnectFlags  = A.anyWord8
    pKeepAlive     = (\msb lsb-> (fromIntegral msb * 256) + fromIntegral lsb)
                     <$> A.anyWord8 <*> A.anyWord8
    pClientIdentifier = ClientIdentifier <$> do
      txt <- pUtf8String
      when (T.null txt) $
        fail "pConnect: Client identifier MUST not be empty (in this implementation)."
      return txt
    pWill flags
      | flags .&. 0x04 == 0 = pure Nothing
      | otherwise           = (Just <$>) $  Will
        <$> pUtf8String
        <*> pBlob
        <*> case flags .&. 0x18 of
              0x00 -> pure Nothing
              0x08 -> pure $ Just AtLeastOnce
              0x10 -> pure $ Just ExactlyOnce
              _    -> fail "pConnect: Violation of [MQTT-3.1.2-14]."
        <*> pure (flags .&. 0x20 /= 0)
    pUsernamePassword flags
      | flags .&. 0x80 == 0 = pure Nothing
      | otherwise           = Just <$> ((,) <$> pUtf8String <*> pPassword flags)
    pPassword flags
      | flags .&. 0x40 == 0 = pure Nothing
      | otherwise           = Just <$> pBlob

pConnectAcknowledgement :: Int -> Word8 -> A.Parser Message
pConnectAcknowledgement len hflags
  | hflags /= 0 = fail "pConnectAcknowledgement: The header flags are reserved and MUST be set to 0."
  | otherwise   = do
    flags <- A.anyWord8
    when (flags .&. 0xfe /= 0) $
      fail "pConnectAcknowledgement: The flags 7-1 are reserved and MUST be set to 0."
    A.anyWord8 >>= f (flags /= 0)
  where
    f sessionPresent returnCode
      | returnCode == 0 = pure $ ConnectAcknowledgement $ Right sessionPresent
      | sessionPresent  = fail "pConnectAcknowledgement: Violation of [MQTT-3.2.2-4]."
      | returnCode <= 5 = pure $ ConnectAcknowledgement $ Left $ toEnum (fromIntegral returnCode - 1)
      | otherwise       = fail "pConnectAcknowledgement: Invalid (reserved) return code."

pPublish :: Int -> Word8 -> A.Parser Message
pPublish len hflags = do
  begin <- pPosition
  Publish
    ( hflags .&. 0x08 /= 0 ) -- duplicate flag
    ( hflags .&. 0x01 /= 0 ) -- retain flag
    <$> pUtf8String
    <*> case hflags .&. 0x06 of
      0x00 -> pure Nothing
      0x02 -> Just . (AtLeastOnce,) <$> pPacketIdentifier
      0x04 -> Just . (ExactlyOnce,) <$> pPacketIdentifier
      _    -> fail "pPublish: Violation of [MQTT-3.3.1-4]."
    <*> (pPosition >>= \end-> A.take (len - (end - begin)))

pPublishAcknowledgement :: Int -> Word8 -> A.Parser Message
pPublishAcknowledgement len hflags
  | hflags /= 0 = fail "pPubAck: The header flags are reserved and MUST be set to 0."
  | otherwise   = PublishAcknowledgement <$> pPacketIdentifier

pPublishReceived :: Int -> Word8 -> A.Parser Message
pPublishReceived len hflags
  | hflags /= 0 = fail "pPublishReceived: The header flags are reserved and MUST be set to 0."
  | otherwise   = PublishReceived <$> pPacketIdentifier

pPublishRelease :: Int -> Word8 -> A.Parser Message
pPublishRelease len hflags
  | hflags /= 2 = fail "pPublishRelease: The header flags are reserved and MUST be set to 2."
  | otherwise   = PublishRelease <$> pPacketIdentifier

pPublishComplete :: Int -> Word8 -> A.Parser Message
pPublishComplete len hflags
  | hflags /= 0 = fail "pPublishComplete: The header flags are reserved and MUST be set to 0."
  | otherwise   = PublishComplete <$> pPacketIdentifier

pSubscribe :: Int -> Word8 -> A.Parser Message
pSubscribe len hflags
  | hflags /= 2 = fail "pSubscribe: The header flags are reserved and MUST be set to 2."
  | otherwise = do
      stop <- (+ len) <$> pPosition
      Subscribe
        <$> pPacketIdentifier
        <*> pManyWithLimit (len - 2) pTopicFilter
  where
    pTopicFilter = (,)
      <$> pUtf8String
      <*> ( A.anyWord8 >>= \qos-> case qos of
        0x00 -> pure Nothing
        0x01 -> pure $ Just AtLeastOnce
        0x02 -> pure $ Just ExactlyOnce
        _    -> fail $ "pSubscribe: Violation of [MQTT-3.8.3-4]." ++ show qos )

pSubscribeAcknowledgement :: Int -> Word8 -> A.Parser Message
pSubscribeAcknowledgement len hflags
  | hflags /= 0 = fail "pSubscribeAcknowledgement: The header flags are reserved and MUST be set to 0."
  | otherwise   = SubscribeAcknowledgement
      <$> pPacketIdentifier
      <*> pManyWithLimit (len - 2) pReturnCode
  where
    pReturnCode = do
      c <- A.anyWord8
      case c of
        0x00 -> pure $ Just Nothing
        0x01 -> pure $ Just $ Just AtLeastOnce
        0x02 -> pure $ Just $ Just ExactlyOnce
        0x80 -> pure Nothing
        _    -> fail "pSubscribeAcknowledgement: Violation of [MQTT-3.9.3-2]."

pUnsubscribe :: Int -> Word8 -> A.Parser Message
pUnsubscribe len hflags
  | hflags /= 2 = fail "pUnsubscribe: The header flags are reserved and MUST be set to 2."
  | otherwise   = Unsubscribe <$> pPacketIdentifier <*> A.many1 pUtf8String

pUnsubscribeAcknowledgement :: Int -> Word8 -> A.Parser Message
pUnsubscribeAcknowledgement len hflags
  | hflags /= 0 = fail "pUnsubscribeAcknowledgement: The header flags are reserved and MUST be set to 0."
  | otherwise   = UnsubscribeAcknowledgement <$> pPacketIdentifier

pPingRequest :: Int -> Word8 -> A.Parser Message
pPingRequest len hflags
  | hflags /= 0 = fail "pPingRequest: The header flags are reserved and MUST be set to 0."
  | otherwise   = pure PingRequest

pPingResponse :: Int -> Word8 -> A.Parser Message
pPingResponse len hflags
  | hflags /= 0 = fail "pPingResponse: The header flags are reserved and MUST be set to 0."
  | otherwise   = pure PingResponse

pDisconnect :: Int -> Word8 -> A.Parser Message
pDisconnect len hflags
  | hflags /= 0 = fail "pDisconnect: The header flags are reserved and MUST be set to 0."
  | otherwise   = pure Disconnect

pPacketIdentifier :: A.Parser Word16
pPacketIdentifier = do
  msb <- A.anyWord8
  lsb <- A.anyWord8
  pure $  (fromIntegral msb * 256) + fromIntegral lsb

bMessage :: Message -> BS.Builder
bMessage (Connect (ClientIdentifier i) cleanSession keepAlive will credentials) =
  BS.word8 0x10
    <> BS.word8 (fromIntegral len)
    <> BS.word64BE ( 0x00044d5154540400 .|. f1 .|. f2 .|. f3 )
    <> BS.word16BE keepAlive
    <> bUtf8String i
    <> maybe mempty (\(Will t m _ _)-> bUtf8String t <> bBlob m) will
    <> maybe mempty (\(u,mp)-> bUtf8String u <> maybe mempty bBlob mp) credentials
  where
    f1 = case credentials of
      Nothing                                  -> 0x00
      Just (_, Nothing)                        -> 0x80
      Just (_, Just _)                         -> 0xc0
    f2 = case will of
      Nothing                                  -> 0x00
      Just (Will _ _ Nothing False)            -> 0x04
      Just (Will _ _ Nothing True)             -> 0x24
      Just (Will _ _ (Just AtLeastOnce) False) -> 0x0c
      Just (Will _ _ (Just AtLeastOnce) True)  -> 0x2c
      Just (Will _ _ (Just ExactlyOnce) False) -> 0x14
      Just (Will _ _ (Just ExactlyOnce) True)  -> 0x34
    f3 = if cleanSession then 0x02 else 0x00
    len = 12
      + BS.length ( T.encodeUtf8 i )
      + maybe 0 ( \(Will t m _ _)-> 4 + BS.length (T.encodeUtf8 t) + BS.length m ) will
      + maybe 0 ( \(u,mp)->
          2 + BS.length ( T.encodeUtf8 u ) + maybe 0 ( (2 +) . BS.length ) mp
        ) credentials
bMessage (ConnectAcknowledgement crs) =
  BS.word32BE $ 0x20020000 .|. case crs of
    Left cr -> fromIntegral $ fromEnum cr + 1
    Right s -> if s then 0x0100 else 0
bMessage (Publish d r t mqp b) =
  BS.word8 ( 0x30
    .|. ( if d then 0x08 else 0 )
    .|. ( if r then 0x01 else 0 )
    .|. case mqp of
      Nothing    -> 0
      Just (q,_) -> case q of
        AtLeastOnce -> 0x02
        ExactlyOnce -> 0x04
    )
  <> bRemainingLength len
  <> bUtf8String t
  <> case mqp of
       Nothing     -> mempty
       Just (_,p) -> BS.word16BE p
  <> BS.byteString b
  where
    len = 2 + BS.length (T.encodeUtf8 t) + BS.length b + maybe 0 (const 2) mqp
bMessage (PublishAcknowledgement p) =
  BS.word16BE 0x4002 <> BS.word16BE p
bMessage (PublishReceived p) =
  BS.word16BE 0x5002 <> BS.word16BE p
bMessage (PublishRelease p) =
  BS.word16BE 0x6202 <> BS.word16BE p
bMessage (PublishComplete p) =
  BS.word16BE 0x7002 <> BS.word16BE p
bMessage (Subscribe p tf)  =
  BS.word8 0x82 <> bRemainingLength len <> BS.word16BE p <> mconcat ( map f tf )
  where
    f (t, q) = (bUtf8String t <>) $ BS.word8 $ case q of
      Nothing          -> 0x00
      Just AtLeastOnce -> 0x01
      Just ExactlyOnce -> 0x02
    len  = 2 + length tf * 3 + sum ( map (BS.length . T.encodeUtf8 . fst) tf )
bMessage (SubscribeAcknowledgement p rcs) =
  BS.word8 0x90 <> bRemainingLength (2 + length rcs) <> BS.word16BE p <> mconcat ( map ( BS.word8 . f ) rcs )
  where
    f Nothing                   = 0x80
    f (Just Nothing)            = 0x00
    f (Just (Just AtLeastOnce)) = 0x01
    f (Just (Just ExactlyOnce)) = 0x02
bMessage (Unsubscribe p tfs) =
  BS.word8 0xa2 <> bRemainingLength len <> BS.word16BE p <> mconcat ( map bUtf8String tfs )
  where
    bfs = map T.encodeUtf8 tfs
    len = 2 + sum ( map ( ( + 2 ) . BS.length ) bfs )
bMessage (UnsubscribeAcknowledgement p) =
  BS.word16BE 0xb002 <> BS.word16BE p
bMessage PingRequest =
  BS.word16BE 0xc000
bMessage PingResponse =
  BS.word16BE 0xd000
bMessage Disconnect =
  BS.word16BE 0xe000
