module Network.Transport.WebSockets.RoutingTable
  ( RoutingTable
  , mkRoutingTable
  , registerEndPoint
  , lookupEndPoint
  , popEndPoint
  , addConn
  , lookupConnTarget
  , closeConn
  , EndPointInfo
  , epWebSocket
  , epConnsTo
  , epConnsFrom
  , epAddress
  , RouterError (..)
  ) where

--------------------------------------------------------------------------------
import           Control.Concurrent.MVar
import qualified Data.Map.Strict         as M
import           Data.Tuple              (swap)
import           System.Random           (randomIO)
--------------------------------------------------------------------------------
import qualified Network.Transport       as NT
import qualified Network.WebSockets      as WS
--------------------------------------------------------------------------------

data EndPointInfo
  = EndPointInfo { epWebSocket :: WS.Connection
                 , epConnsTo   :: M.Map NT.ConnectionId NT.EndPointAddress
                 , epConnsFrom :: M.Map NT.ConnectionId NT.EndPointAddress
                 , epAddress   :: NT.EndPointAddress
                 }

data RoutingTable
  = RoutingTable (MVar (M.Map NT.EndPointAddress EndPointInfo))

mkRoutingTable :: IO RoutingTable
mkRoutingTable = RoutingTable <$> newMVar mempty

--------------------------------------------------------------------------------

-- | Inserts a new EndPoint to RoutingTable
registerEndPoint :: RoutingTable -> NT.EndPointAddress -> WS.Connection -> IO ()
registerEndPoint (RoutingTable m) addr conn
  = modifyMVar_ m $ return . M.insert addr info
  where
    info = EndPointInfo conn mempty mempty addr

lookupEndPoint :: RoutingTable -> NT.EndPointAddress -> IO (Maybe EndPointInfo)
lookupEndPoint (RoutingTable m) addr
  = M.lookup addr <$> readMVar m

-- | Removes an EndPoint from RoutingTable
popEndPoint :: RoutingTable
            -> NT.EndPointAddress
            -> IO (Maybe EndPointInfo)
popEndPoint (RoutingTable m') addr
  = modifyMVar m' $ \m -> return $
      case M.lookup addr m of
        Nothing -> (m, Nothing)
        Just ep ->
          let t1 = [ (a, updateConnsFrom $ M.delete c)
                   | (c, a) <- M.toList $ epConnsTo ep
                   ]
              t2 = [ (a, updateConnsTo $ M.delete c)
                   | (c, a) <- M.toList $ epConnsFrom ep
                   ]
              go m (a, f) = M.adjust f a m
          in (foldl go (M.delete addr m) (t1 ++ t2), Just ep)

--------------------------------------------------------------------------------

data RouterError
  = SourceAddressNotFound
  | TargetAddressNotFound
  | ConnectionNotFound

-- TODO: Use M.updateLookupWithKey to reduce complexity
addConn :: RoutingTable
        -> (NT.EndPointAddress, NT.EndPointAddress)
        -> IO (Either RouterError (NT.ConnectionId, EndPointInfo))
addConn (RoutingTable m') (sAddr, tAddr) = do
  cid <- randomConnectionId
  modifyMVar m' $ \m -> return $
    case (M.lookup sAddr m, M.lookup tAddr m) of
      (Nothing, _) -> (m, Left SourceAddressNotFound)
      (_, Nothing) -> (m, Left TargetAddressNotFound)
      (Just s, Just t) ->
        ( M.adjust (updateConnsTo   $ M.insert cid tAddr) sAddr
        $ M.adjust (updateConnsFrom $ M.insert cid sAddr) tAddr
        $ m
        , Right (cid, t)
        )

closeConn :: RoutingTable
          -> NT.EndPointAddress
          -> NT.ConnectionId
          -> IO (Maybe EndPointInfo)
closeConn (RoutingTable m') sAddr cid
  = modifyMVar m' $ \m -> return $
      case M.lookup sAddr m of
        Nothing -> (m, Nothing)
        Just s  ->
          let m' = M.adjust (updateConnsTo $ M.delete cid) sAddr m
          in  case M.lookup cid $ epConnsTo s of
            Nothing     -> (m', Nothing)
            Just tAddr  -> case M.lookup tAddr m of
              Nothing -> (m', Nothing)
              Just t  ->
                let m'' = M.adjust (updateConnsFrom $ M.delete cid) tAddr m'
                in (m'', Just t)

lookupConnTarget :: RoutingTable
                 -> NT.EndPointAddress
                 -> NT.ConnectionId
                 -> IO (Either RouterError EndPointInfo)
lookupConnTarget (RoutingTable m') sAddr cid
  = readMVar m' >>= \m -> return $ do
      s <- maybe (Left SourceAddressNotFound) Right $ M.lookup sAddr m
      tAddr <- maybe (Left ConnectionNotFound) Right $ M.lookup cid (epConnsTo s)
      maybe (Left TargetAddressNotFound) Right  $ M.lookup tAddr m

updateConnsTo   f s = s { epConnsTo = f $ epConnsTo s }
updateConnsFrom f s = s { epConnsFrom = f $ epConnsFrom s }

--------------------------------------------------------------------------------

randomConnectionId :: IO NT.ConnectionId
randomConnectionId = randomIO

--------------------------------------------------------------------------------

-- TODO: Remove dangling connections when noticed

