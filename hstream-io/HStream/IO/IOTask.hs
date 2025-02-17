{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}

module HStream.IO.IOTask where

import qualified Control.Concurrent         as C
import           Control.Exception          (throwIO)
import qualified Control.Exception          as E
import           Control.Monad              (forever, msum, unless, void, when)
import qualified Data.Aeson                 as J
import qualified Data.ByteString            as BS
import qualified Data.ByteString.Lazy       as BSL
import qualified Data.ByteString.Lazy.Char8 as BSLC
import           Data.IORef                 (newIORef, readIORef, writeIORef)
import qualified Data.Text                  as T
import           RIO.Directory              (createDirectoryIfMissing)
import qualified System.Process.Typed       as TP

import qualified Control.Concurrent.STM     as STM
import qualified GHC.IO.Handle              as IO
import qualified HStream.IO.Messages        as MSG
import qualified HStream.IO.Meta            as M
import           HStream.IO.Types
import qualified HStream.Logger             as Log
import qualified HStream.MetaStore.Types    as M

newIOTask :: T.Text -> M.MetaHandle -> TaskInfo -> T.Text -> IO IOTask
newIOTask taskId taskHandle taskInfo path = do
  process' <- newIORef Nothing
  statusM  <- C.newMVar NEW
  let taskPath = T.unpack path
  return IOTask {..}

initIOTask :: IOTask -> IO ()
initIOTask IOTask{..} = do
  let configPath = taskPath ++ "/config.json"
      TaskInfo{..} = taskInfo
  -- create task files
  createDirectoryIfMissing True taskPath
  BSL.writeFile configPath (J.encode connectorConfig)

getDockerName :: T.Text -> T.Text
getDockerName = ("IOTASK_" <>)

runIOTask :: IOTask -> IO ()
runIOTask ioTask@IOTask{..} = do
  Log.info $ "taskCmd: " <> Log.buildString taskCmd
  tp <- TP.startProcess taskProcessConfig
  writeIORef process' (Just tp)
  _ <- C.forkIO $
    E.catch
      (handleStdout ioTask (TP.getStdout tp) (TP.getStdin tp))
      (\(e :: E.SomeException) -> Log.info $ "handleStdout exited:" <> Log.buildString (show e))
  return ()
  where
    TaskInfo {..} = taskInfo
    TaskConfig {..} = taskConfig
    taskCmd = concat [
        "docker run --rm -i",
        " --network=", T.unpack tcNetwork,
        " --name ", T.unpack (getDockerName taskId),
        " -v " , taskPath, ":/data",
        " " , T.unpack tcImage,
        " run",
        " --config /data/config.json"
      ]
    taskProcessConfig = TP.setStdin TP.createPipe
      . TP.setStdout TP.createPipe
      . TP.setStderr TP.inherit
      $ TP.shell taskCmd

handleStdout :: IOTask -> IO.Handle -> IO.Handle -> IO ()
handleStdout ioTask@IOTask{..} hStdout hStdin = forever $ do
  line <- BS.hGetLine hStdout
  let logPath = taskPath ++ "/stdout.log"
  BS.appendFile logPath (line <> "\n")
  case J.eitherDecode (BSL.fromStrict line) of
    Left _ -> pure () -- Log.info $ "decode err:" <> Log.buildString err
    Right msg -> do
      Log.info $ "connectorMsg:" <> Log.buildString (show msg)
      respM <- handleConnectorMessage ioTask msg
      Log.info $ "ConnectorRes:" <> Log.buildString (show respM)
      case respM of
        Nothing -> pure ()
        Just resp -> do
          BSLC.hPutStrLn hStdin (J.encode resp)
          IO.hFlush hStdin

handleConnectorMessage :: IOTask -> MSG.ConnectorMessage -> IO (Maybe MSG.ConnectorCallResponse)
handleConnectorMessage ioTask MSG.ConnectorMessage{..} = do
  case cmType of
    MSG.CONNECTOR_SEND -> do
      Log.warning "unsupported connector send"
      pure Nothing
    MSG.CONNECTOR_CALL -> do
      result <- handleKvMessage ioTask cmMessage
      return $ Just (MSG.ConnectorCallResponse cmId result)

handleKvMessage :: IOTask -> MSG.KvMessage -> IO J.Value
handleKvMessage IOTask{..} kvMsg@MSG.KvMessage {..} = do
  case (kmAction, kmValue) of
    ("get", _) -> J.toJSON <$> M.getTaskKv taskHandle taskId kmKey
    ("set", Just val) -> J.Null <$ M.setTaskKv taskHandle taskId kmKey val
    _ -> do
      Log.warning $ "invalid kv msg:" <> Log.buildString (show kvMsg)
      pure J.Null

-- runIOTaskWithRetry :: IOTask -> IO ()
-- runIOTaskWithRetry task@IOTask{..} =
--   runWithRetry (1 :: Int)
--   where
--     duration = 1000
--     maxRetry = 1
--     runWithRetry retry = do
--       runIOTask task
--       if retry < maxRetry
--       then do
--         threadDelay $ duration * 1000
--         runWithRetry $ retry + 1
--       else
--         updateStatus task (\_ -> pure FAILED)

startIOTask :: IOTask -> IO ()
startIOTask task = do
  updateStatus task $ \case
    status | elem status [NEW, FAILED, STOPPED]  -> do
      runIOTask task
      return RUNNING
    status -> throwIO $ InvalidStatusException status

stopIOTask :: IOTask -> Bool -> Bool -> IO ()
stopIOTask task@IOTask{..} ifIsRunning force = do
  updateStatus task $ \case
    RUNNING -> do
      if force
      then do
        readIORef process' >>= maybe (pure ()) TP.stopProcess
        void $ TP.runProcess killProcessConfig
      else do
        Just tp <- readIORef process'
        let stdin = TP.getStdin tp
        BSLC.hPutStrLn stdin (J.encode MSG.InputCommandStop <> "\n")
        IO.hFlush stdin
        void $ TP.waitExitCode tp
        -- FIXME: timeout
        -- timeout <- delayTMVar
        -- STM.atomically $ STM.orElse (void $ TP.waitExitCodeSTM tp) (STM.takeTMVar timeout)
        -- kill task process
        -- void $ TP.runProcess killProcessConfig
        TP.stopProcess tp
        writeIORef process' Nothing
      return STOPPED
    s -> do
      unless ifIsRunning $ throwIO (InvalidStatusException s)
      return s
  where
    killDockerCmd = "docker kill " ++ T.unpack (getDockerName taskId)
    killProcessConfig = TP.shell killDockerCmd
    delayTMVar = do
      tmvar <- STM.newEmptyTMVarIO
      _ <- C.forkIO $ do
        C.threadDelay 15000000
        Log.info "exit process timeout, force to stop it"
        STM.atomically $ STM.putTMVar tmvar ()
      return tmvar

updateStatus :: IOTask -> (IOTaskStatus -> IO IOTaskStatus) -> IO ()
updateStatus IOTask{..} action = do
  C.modifyMVar_ statusM $ \status -> do
    ts <- action status
    when (ts /= status) $ M.updateStatusInMeta taskHandle taskId ts
    return ts

checkProcess :: IOTask -> IO ()
checkProcess ioTask@IOTask{..} = do
  updateStatus ioTask $ \status -> do
    case status of
      RUNNING -> do
        Just tp <- readIORef process'
        TP.getExitCode tp >>= \case
          Nothing -> return status
          Just _  -> return FAILED
      _ -> return status

checkIOTask :: IOTask -> IO ()
checkIOTask IOTask{..} = do
  Log.info $ "checkCmd:" <> Log.buildString checkCmd
  (exitCode, output, err) <- TP.readProcess checkProcessConfig
  when (exitCode /= TP.ExitSuccess) $ do
    Log.info $ Log.buildString ("check process exited: " ++ show exitCode)
    Log.info $ "stdout:" <> Log.buildString (BSLC.unpack output)
    Log.info $ "stderr:" <> Log.buildString (BSLC.unpack err)
    E.throwIO (CheckFailedException "check process exited unexpectedly")
  let (result :: Maybe MSG.CheckResult) = msum . map J.decode $ BSLC.lines output
  case result of
    Nothing -> E.throwIO (CheckFailedException "check process didn't return correct result messsage")
    Just MSG.CheckResult {result=False, message=msg} -> do
      E.throwIO (CheckFailedException $ "check failed:" <> msg)
    Just _ -> pure ()
  where
    checkProcessConfig = TP.setStdin TP.closed
      . TP.setStdout TP.createPipe
      . TP.setStderr TP.closed
      $ TP.shell checkCmd
    TaskConfig {..} = taskConfig taskInfo
    checkCmd = concat [
        "docker run --rm -i",
        " --network=", T.unpack tcNetwork,
        " --name ", T.unpack (getDockerName taskId),
        " -v " , taskPath, ":/data",
        " " , T.unpack tcImage,
        " check",
        " --config /data/config.json"
      ]
