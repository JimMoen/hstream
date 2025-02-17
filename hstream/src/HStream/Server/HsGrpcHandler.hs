{-# LANGUAGE DataKinds #-}

module HStream.Server.HsGrpcHandler (handlers) where

import           HsGrpc.Server

import qualified HStream.Server.Handler.Admin        as H
import qualified HStream.Server.Handler.Cluster      as H
import qualified HStream.Server.Handler.Stats        as H
import qualified HStream.Server.Handler.Stream       as H
import qualified HStream.Server.Handler.Subscription as H
import qualified HStream.Server.HStreamApi           as A
import           HStream.Server.Types                (ServerContext (..))
import qualified Proto.HStream.Server.HStreamApi     as P

-------------------------------------------------------------------------------

handlers :: ServerContext -> [ServiceHandler]
handlers sc =
  [ unary (GRPC :: GRPC P.HStreamApi "echo") handleEcho
    -- Cluster
  , unary (GRPC :: GRPC P.HStreamApi "describeCluster") (H.handleDescribeCluster sc)
  , unary (GRPC :: GRPC P.HStreamApi "lookupShard") (H.handleLookupShard sc)
  , unary (GRPC :: GRPC P.HStreamApi "lookupSubscription") (H.handleLookupSubscription sc)
  , unary (GRPC :: GRPC P.HStreamApi "lookupShardReader") (H.handleLookupShardReader sc)
  , unary (GRPC :: GRPC P.HStreamApi "lookupConnector") (H.handleLookupConnector sc)
    -- Stream
  , unary (GRPC :: GRPC P.HStreamApi "createStream") (H.handleCreateStream sc)
  , unary (GRPC :: GRPC P.HStreamApi "deleteStream") (H.handleDeleteStream sc)
  , unary (GRPC :: GRPC P.HStreamApi "listStreams") (H.handleListStreams sc)
  , unary (GRPC :: GRPC P.HStreamApi "listShards") (H.handleListShard sc)
    -- Reader
  , unary (GRPC :: GRPC P.HStreamApi "createShardReader") (H.handleCreateShardReader sc)
  , unary (GRPC :: GRPC P.HStreamApi "deleteShardReader") (H.handleDeleteShardReader sc)
    -- Subscription
  , unary (GRPC :: GRPC P.HStreamApi "createSubscription") (H.handleCreateSubscription sc)
  , unary (GRPC :: GRPC P.HStreamApi "deleteSubscription") (H.handleDeleteSubscription sc)
  , unary (GRPC :: GRPC P.HStreamApi "listSubscriptions") (H.handleListSubscriptions sc)
  , unary (GRPC :: GRPC P.HStreamApi "checkSubscriptionExist") (H.handleCheckSubscriptionExist sc)
    -- Append
  , unary (GRPC :: GRPC P.HStreamApi "append") (H.handleAppend sc)
    -- Read
  , unary (GRPC :: GRPC P.HStreamApi "readShard") (H.handleReadShard sc)
    -- Subscribe
  , bidiStream (GRPC :: GRPC P.HStreamApi "streamingFetch") (H.handleStreamingFetch sc)
    -- Stats
  , unary (GRPC :: GRPC P.HStreamApi "perStreamTimeSeriesStats") (H.handlePerStreamTimeSeriesStats $ scStatsHolder sc)
  , unary (GRPC :: GRPC P.HStreamApi "perStreamTimeSeriesStatsAll") (H.handlePerStreamTimeSeriesStatsAll $ scStatsHolder sc)
    -- Admin
  , unary (GRPC :: GRPC P.HStreamApi "sendAdminCommand") (H.handleAdminCommand sc)
    -- TODO: Query
    -- TODO: Connector
    -- TODO: View
  ]

handleEcho :: A.EchoRequest -> IO A.EchoResponse
handleEcho A.EchoRequest{..} = return $ A.EchoResponse echoRequestMsg
