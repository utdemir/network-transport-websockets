{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase    #-}

-- | A centralized websocket implementation of the network-transport API.
--
-- This implementation is on early stages and has known bugs!
--
-- Known issues:
--
--   * It does not gracefully handle closeConnection calls and connection failures.
--   It may even give @thread blocked indefinitely in an MVar operation@ sometimes.
--   * It can not pass some tests on "Network.Transport.Tests". They are mostly
--   about connection failures.
--   * The implementation is not nearly as fast as "Network.Transport.TCP".
module Network.Transport.WebSockets
  ( router
  , client
  -- * Helpers
  , acceptAll
  -- * Re-exports
  , NT.EndPointAddress (..)
  , WS.runClient
  ) where

--------------------------------------------------------------------------------
import           Control.Concurrent
import           Control.Concurrent.Chan
import           Control.Concurrent.MVar
import           Control.DeepSeq                           (deepseq)
import           Control.Exception                         (IOException,
                                                            SomeException,
                                                            catch, finally, try)
import           Control.Monad
import           Data.Binary
import qualified Data.ByteString                           as BS
import qualified Data.ByteString.Char8                     as BS8
import qualified Data.ByteString.Lazy                      as BL
import           Data.Functor                              (($>))
import qualified Data.Map                                  as M
import           GHC.Generics                              (Generic)
import           Prelude                                   hiding (log)
import           System.IO
import           System.Random
import           System.Timeout
-------------------------------------------------------------------------------
import qualified Network.Transport                         as NT
import           Network.Transport.WebSockets.RoutingTable
import qualified Network.WebSockets                        as WS
import           System.Log.Logger
--------------------------------------------------------------------------------

newtype QuestionId = QuestionId Word64
  deriving (Show, Eq, Ord, Generic)

instance Binary QuestionId

data RMessage
  = SetEndPointAddress NT.EndPointAddress
  | Connect QuestionId NT.EndPointAddress
  | Send QuestionId NT.ConnectionId [BS.ByteString]
  | CloseConnection NT.ConnectionId
  deriving (Show, Eq, Generic)

data CMessage
  = Receive NT.Event
  | ConnectAnswer QuestionId (Either () NT.ConnectionId)
  | SendAnswer QuestionId (Either () ())
  deriving (Show, Eq, Generic)

instance Binary CMessage
instance WS.WebSocketsData CMessage where
  fromLazyByteString = decode
  toLazyByteString   = encode

instance Binary RMessage
instance WS.WebSocketsData RMessage where
  fromLazyByteString = decode
  toLazyByteString   = encode

--------------------------------------------------------------------------------

sendRMessage :: WS.Connection -> RMessage -> IO ()
sendRMessage = WS.sendBinaryData

receiveRMessage :: WS.Connection -> IO RMessage
receiveRMessage = WS.receiveData

sendCMessage :: WS.Connection -> CMessage -> IO ()
sendCMessage = WS.sendBinaryData

receiveCMessage :: WS.Connection -> IO CMessage
receiveCMessage = WS.receiveData

--------------------------------------------------------------------------------

-- | `client` is a function that returns a transport given the means
-- of connecting to a router (usually either `Network.WebSockets.runClientWith`,
-- `Network.WebSockets.runClientWithSocket` or
-- `Network.WebSockets.runClientWithStream`).
--
-- Example:
--
-- >>> let transport = client (runClient "localhost" 80 "/websocket") Nothing
--
client :: (WS.ClientApp () -> IO ()) -> Maybe NT.EndPointAddress -> NT.Transport
client run addr' = NT.Transport
  { NT.newEndPoint = do
      addr <- maybe randomEndPointAddress return addr'

      connectAnswers <- newMVar mempty
        :: IO (MVar (M.Map QuestionId (MVar (Either () NT.ConnectionId))))
      sendAnswers    <- newMVar mempty
        :: IO (MVar (M.Map QuestionId (MVar (Either () ()))))
      events         <- newChan
        :: IO (Chan NT.Event)

      transportEstablished <- newEmptyMVar
        :: IO (MVar (Either String ()))
      mailbox <- newChan
        :: IO (Chan (Either () RMessage))

      forkIO $
        let act = run $ \conn -> do -- TODO: KILL HIM!
              debugM "client" "connected to router"

              sendRMessage conn $ SetEndPointAddress addr
              putMVar transportEstablished $ Right ()

              forkIO . forever $ readChan mailbox >>= \case
                Left ()   -> WS.sendClose conn (BS8.pack "")
                Right msg -> sendRMessage conn msg

              let go = do
                    msg <- try $ receiveCMessage conn
                    debugM "client" ("client: " ++ show msg)
                    case msg of
                      Left (WS.ParseException a) ->
                        warningM "router" ("unknown message(" ++ a ++ "), ignoring.")
                          >> go
                      Left (WS.CloseRequest _ _) -> return ()
                      Left (WS.ConnectionClosed) -> return ()
                      Right (Receive event)
                        -> writeChan events event
                             >> go
                      Right (ConnectAnswer qid ans)
                        -> readMVar connectAnswers
                             >>= maybe
                                   (warningM "client" "connect answer timed out")
                                   (flip putMVar ans)
                               . M.lookup qid
                             >> go
                      Right (SendAnswer qid ans)
                        -> readMVar sendAnswers
                             >>= maybe
                                   (warningM "client" "send answer timed out")
                                   (flip putMVar ans)
                               . M.lookup qid
                             >> go
              go
              warningM "client" "stopping client"
        in act `catch` (\ex -> void . tryPutMVar transportEstablished . Left $ show (ex :: SomeException))
               `finally` (writeChan events NT.EndPointClosed)

      ret <- readMVar transportEstablished
      case ret of
        Left err -> return $ Left (NT.TransportError NT.NewEndPointFailed err)
        Right () -> return . Right $
          NT.EndPoint
            { NT.address
              = addr
            , NT.connect
              = \other reliability hints ->
                askRouter mailbox connectAnswers (flip Connect other) >>= \case
                  Nothing
                    -> return . Left $ NT.TransportError NT.ConnectFailed
                         "connect: connection closed"
                  Just (Left ())
                    -> return . Left $ NT.TransportError NT.ConnectNotFound
                         "connect: remote endpoint not found"
                  Just (Right cid)
                    -> return . Right $ NT.Connection
                         { NT.send = \msgs -> deepseq msgs $
                            askRouter mailbox sendAnswers (\q -> Send q cid msgs) >>= \case
                              Nothing
                                -> return . Left $ NT.TransportError NT.SendFailed
                                     "send: router did not answer"
                              Just (Left ())
                                -> return . Left $ NT.TransportError NT.SendClosed
                                     "send: remote endpoint or connection is not found"
                              Just (Right ())
                                -> return $ Right ()
                         , NT.close
                            = writeChan mailbox (Right $ CloseConnection cid)
                         }
            , NT.closeEndPoint
              = writeChan mailbox (Left ()) >> return ()
            , NT.receive
              = readChan events
            , NT.newMulticastGroup
              = return . Left $ newMulticastGroupError
            , NT.resolveMulticastGroup
              = return . Left . const resolveMulticastGroupError
            }
  , NT.closeTransport = return () -- TODO
  }

newMulticastGroupError
  = NT.TransportError NT.NewMulticastGroupUnsupported "Multicast not supported"
resolveMulticastGroupError
  = NT.TransportError NT.ResolveMulticastGroupUnsupported "Multicast not supported"

askRouter :: Chan (Either () RMessage)
          -> MVar (M.Map QuestionId (MVar a))
          -> (QuestionId -> RMessage)
          -> IO (Maybe a)
askRouter mailbox map msg = do
  qid <- randomQuestionId
  ans <- newEmptyMVar
  modifyMVar_ map $ return . M.insert qid ans
  (writeChan mailbox (Right $ msg qid) >> timeout (10*1000*1000) (takeMVar ans))
    `finally` modifyMVar_ map (return . M.delete qid)

--------------------------------------------------------------------------------

-- | A router is a 'Network.Websockets.ServerApp'; it acts as a router between
-- endpoints. 'client's doesn't connect to each other directly, instead
-- they connect to the router and router passes the messages between them.
--
-- To accept or reject an incoming connection use the first parameter.  Or just
-- use 'acceptAll' helper.
--
-- Example:
--
-- >>> import Network.Wai.Handler.Warp (run)
-- >>> import Network.Wai.Handler.WebSockets (websocketsOr, defaultConnectionOptions)
-- >>> r <- router acceptAll
-- >>> run 80 $ websocketsOr defaultConnectionOptions r
--       (\_ _ -> fail "not websockets")
--
router :: (WS.RequestHead -> IO (Either String ())) -> IO WS.ServerApp
router accept = do
  routes <- mkRoutingTable
  return $ \pending -> do
    selfAddr <- newEmptyMVar  :: IO (MVar NT.EndPointAddress)
    accept (WS.pendingRequest pending) >>= \case
      Left err  ->
        WS.rejectRequest pending (BS8.pack err)
        >> warningM "router" "rejected client"
      Right () -> do
        conn <- WS.acceptRequest pending
        let closeEP = tryReadMVar selfAddr >>= \case
              Nothing   -> return ()
              Just addr -> do
                popEndPoint routes addr >>= \case
                  Nothing -> undefined
                  Just ep ->
                    forM_ (M.toList (epConnsTo ep) ++ M.toList (epConnsFrom ep)) $ \(c, a) ->
                      lookupEndPoint routes a >>= \case
                        Nothing -> return ()
                        Just ep -> sendCMessage (epWebSocket ep) . Receive
                                     $ NT.ConnectionClosed c
            go = do
              message <- try $ receiveRMessage conn
              debugM "router" (show message)
              case message of
                Left (WS.CloseRequest _ _) -> do -- Client requested graceful close
                  closeEP
                Left WS.ConnectionClosed -> do   -- TCP connection died abruptly
                  closeEP
                Left (WS.ParseException a) -> do
                  warningM "router" $ "unknown message: '" ++ a ++ "', ignoring."
                  go
                Right (SetEndPointAddress addr) -> do
                  tryPutMVar selfAddr addr >>= \case
                    False -> warningM "router" "client sent SetEndPointAddr twice, ignoring"
                    True  -> registerEndPoint routes addr conn
                  go
                Right (Connect qid addr) -> do
                  tryReadMVar selfAddr >>= \case
                    Nothing     -> warningM "router" "connect: SetEndPointAddr not set, ignoring"
                    Just myAddr -> addConn routes (myAddr, addr) >>= \case
                      Left SourceAddressNotFound ->
                        warningM "router" "connect: router didn't know me"
                        >> sendCMessage conn (ConnectAnswer qid $ Left ())
                      Left TargetAddressNotFound ->
                        warningM "router" "connect: remote endpoint not found"
                        >> sendCMessage conn (ConnectAnswer qid $ Left ())
                      Left ConnectionNotFound -> error "impossible happened: 94"
                      Right (cid, other) -> do
                        sendCMessage conn
                          $ ConnectAnswer qid (Right cid)
                        sendCMessage (epWebSocket other) . Receive
                          $ NT.ConnectionOpened cid NT.ReliableOrdered myAddr
                  go
                Right (Send qid cid msgs) -> do
                  tryReadMVar selfAddr >>= \case
                    Nothing     -> warningM "router" "send: SetEndPointAddr not set, ignoring"
                    Just myAddr ->
                      lookupConnTarget routes myAddr cid >>= \case
                        Left SourceAddressNotFound ->
                          warningM "router" "send: router didn't know me"
                          >> sendCMessage conn (SendAnswer qid $ Left ())
                        Left TargetAddressNotFound ->
                          warningM "router" "send: remote endpoint not found"
                          >> sendCMessage conn (SendAnswer qid $ Left ())
                        Left ConnectionNotFound ->
                          warningM "router" "send: connection not found"
                          >> sendCMessage conn (SendAnswer qid $ Left ())
                        Right ep -> do
                          sendCMessage conn $ SendAnswer qid $ Right ()
                          sendCMessage (epWebSocket ep) . Receive $ NT.Received cid msgs
                  go
                Right (CloseConnection cid) -> do
                  tryReadMVar selfAddr >>= \case
                    Nothing     -> warningM "router" "closeConnection: SetEndPointAddr not set, ignoring"
                    Just myAddr -> closeConn routes myAddr cid >>= \case
                      Nothing -> warningM "router" "closeConnection: remote endpoint not found"
                      Just ep -> sendCMessage (epWebSocket ep) . Receive $ NT.ConnectionClosed cid
                  go
        go `catch` (const closeEP :: IOException -> IO ())

-- | Helper function to accept all incoming websocket requests
acceptAll :: WS.RequestHead -> IO (Either String ())
acceptAll _ = return $ Right ()

--------------------------------------------------------------------------------

randomEndPointAddress :: IO NT.EndPointAddress
randomEndPointAddress = NT.EndPointAddress . BS8.pack . show <$> (randomIO :: IO Word64)

randomQuestionId :: IO QuestionId
randomQuestionId = QuestionId <$> randomIO

--------------------------------------------------------------------------------

-- data WSConnection
--   = WSConnection { wsConn :: WS.Connection
--                  , wsStop :: MVar ()
--                  }

-- wsMkConnection :: (WS.ClientApp () -> IO ()) -> IO WSConnection
-- wsMkConnection run  = do
--   connVar <- newEmptyMVar
--   stopVar <- newEmptyMVar
--   run $ \conn -> putMVar connVar conn >> readMVar stopVar
--   conn <- takeMVar connVar
--   return $ WSConnection conn stopVar

-- wsCloseConnection :: WSConnection -> IO ()
-- wsCloseConnection (WSConnection _ stop) = putMVar stop ()

