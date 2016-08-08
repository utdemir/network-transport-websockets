{-# LANGUAGE OverloadedStrings #-}

module Main where

--------------------------------------------------------------------------------
import           Control.Concurrent                (forkIO, killThread,
                                                    myThreadId, threadDelay,
                                                    throwTo)
import           Control.Exception                 (IOException, SomeException,
                                                    bracket, catch, throwIO)
import           Data.Bool                         (bool)
import qualified Data.ByteString.Char8             as BS8
import           Data.Functor                      (($>))
import           Network.Socket
import           System.Log.Logger
--------------------------------------------------------------------------------
import           Network.Wai
import           Network.Wai.Handler.Warp          hiding (testWithApplication)
import           Network.Wai.Handler.WebSockets
import           Network.WebSockets
import           Network.WebSockets.Connection
--------------------------------------------------------------------------------
import qualified Network.Transport                 as NT
import           Network.Transport.Tests
import           Network.Transport.Tests.Auxiliary
import           Network.Transport.WebSockets
--------------------------------------------------------------------------------

main :: IO ()
main = do
  updateGlobalLogger rootLoggerName $ setLevel DEBUG

  r <- router acceptAll
  let app = websocketsOr defaultConnectionOptions r
       $ \_ _ -> fail "not websockets"

  testWithApplicationSettings (setTimeout 240 defaultSettings) (return app) $ \port -> do
    let mkTransport =
          return . Right $ client (runClient "127.0.0.1" port "/") Nothing
        numPings = 100

    Right transport <- mkTransport
    runTests
      [ ("EndPointAddress",       testEndPointAddr transport)
      , ("PingPong",              testPingPong transport numPings)
      , ("EndPoints",             testEndPoints transport numPings)
      , ("Connections",           testConnections transport numPings)
      , ("CloseOneConnection",    testCloseOneConnection transport numPings)
      , ("CloseOneDirection",     testCloseOneDirection transport numPings)
      , ("ParallelConnects",      testParallelConnects transport numPings)
      , ("SelfSend",              testSelfSend transport)
      , ("SendAfterClose",        testSendAfterClose transport 100)
      , ("Crossing",              testCrossing transport 10)
      , ("CloseTwice",            testCloseTwice transport 100)
      , ("ConnectToSelf",         testConnectToSelf transport numPings)
      -- , ("ConnectClosedEndPoint", testConnectClosedEndPoint transport)

      -- TODO: Implement closeTransport
      -- , ("CloseTransport",        testCloseTransport mkTransport)

      -- TODO: Send "EventConnectionLost" when trying to receive when remote endpoint
      --       closed
      -- , ("CloseEndPoint",         testCloseEndPoint transport numPings)

      -- TODO: network-transport-tests expects connection id's to be ordered, even if
      --       network-transport API doesn't enforce it. Fix `collect` method on nt-tests
      -- , ("ConnectToSelfTwice",    testConnectToSelfTwice transport numPings)
      -- , ("CloseReopen",           testCloseReopen transport numPings)
      -- , ("Kill",                  testKill mkTransport 1000)

      -- TODO: This test takes unusually long time, fix it.
      -- , ("ExceptionOnReceive",    testExceptionOnReceive mkTransport)

      -- TODO: I'm not sure if I should handle this.
      -- , ("SendException",         testSendException mkTransport)

      -- TODO: After closing a connection, `send` should return "SendClosed", but
      --       after closing transport, it should return "SendFailed"
      -- , ("CloseSelf",             testCloseSelf mkTransport)

      ]

  return ()

--------------------------------------------------------------------------------

testEndPointAddr :: NT.Transport -> IO ()
testEndPointAddr transport = do
  Right ep <- NT.newEndPoint transport
  let addr = NT.address ep
  print addr
  NT.closeEndPoint ep
  return ()

--------------------------------------------------------------------------------

testWithApplication :: IO Application -> (Port -> IO a) -> IO a
testWithApplication mkApp action = do
  callingThread <- myThreadId
  app <- mkApp
  let wrappedApp request respond =
        app request respond `catch` \ e -> do
          throwTo callingThread (e :: SomeException)
          throwIO e
  withApplication (return wrappedApp) action


-- | Like 'openFreePort' but closes the socket before exiting.
withFreePort :: ((Port, Socket) -> IO a) -> IO a
withFreePort = bracket openFreePort (close . snd)
