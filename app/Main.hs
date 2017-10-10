{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE OverloadedStrings    #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE TypeApplications     #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Distributed.Process
import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Lens hiding (argument)
import Control.Monad
import Data.Aeson hiding (Options)
import Data.Binary
import Data.Function (fix)
import Data.IORef
import Data.List (intersect, sortBy)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Monoid
import Data.Ord (comparing)
import Data.Set (Set)
import Data.Time
import Data.Typeable
import Data.Yaml hiding (Parser)
import GHC.Generics (Generic)
import Network.Socket (HostName, ServiceName)
import Network.Transport (EndPointAddress (..))
import Numeric.Natural
import Options.Applicative
import System.Exit (exitWith, ExitCode (..))
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)
import qualified Data.ByteString.Char8 as B8
import qualified Data.List.NonEmpty    as NE
import qualified Data.Map.Strict       as M
import qualified Data.Set              as E
import qualified System.Random.TF      as TF
import qualified System.Random.TF.Gen  as TF

----------------------------------------------------------------------------
-- Data types

-- | Command line options.

data Options
  = Slave HostName ServiceName
    -- ^ Run in slave mode, with given host name and sercive name (i.e.
    -- port)
  | Master HostName ServiceName FilePath Natural Natural Natural
    -- ^ Run in master mode with the following parameters, in order:
    --     * Host name
    --     * Service name
    --     * Location of a YAML file with slave node list
    --     * Number of seconds to send messages for
    --     * Number of seconds to wait for
    --     * Seed to use for random number generation

-- | List of slave nodes to use.

newtype NodeList = NodeList (NonEmpty NodeId)

instance FromJSON NodeList where
  parseJSON v = NodeList . fmap (NodeId . EndPointAddress . B8.pack)
    <$> parseJSON v

data SlaveState = SlaveState
  { _sstPeers :: Set ProcessId
    -- ^ A list of peer processes to which to send the messages
  , _sstGracePeriodStart :: UTCTime
    -- ^ Absolute time up to which to send the messages
  , _sstReceived :: [NumberMsg]
    -- ^ Numbers received so far. The document does not mention for how long
    -- sending of messages will happen (seconds, minutes, hours?). If we're
    -- to run the program for long enough time period, linked list is not a
    -- very good choice, but then vector is not much better (if we speak of
    -- hours). Ideally, we would like to avoid accumulating the messages at
    -- all and adjust some running result as we receive values, but this
    -- approach seems challenging because there is no guarantee that the
    -- messages will come in the right order. A message α sent later than
    -- another message β from other node could arrive earlier than β and
    -- since we need indices of the messages to calculate the final result,
    -- we can't know if we won't receive some earlier message at any point
    -- in time.
  , _sstTFGen :: TF.TFGen
    -- ^ Random generator state
  } deriving (Typeable, Generic)

-- NOTE Orphan instances, could be avoided with a newtypes, but for the
-- purposes of this task it doesn't make any difference, it's not a library.

instance Binary UTCTime where
  put UTCTime {..} = do
    put (toModifiedJulianDay utctDay)
    put (diffTimeToPicoseconds utctDayTime)
  get = do
    utctDay     <- ModifiedJulianDay     <$> get
    utctDayTime <- picosecondsToDiffTime <$> get
    return UTCTime {..}

instance Binary TF.TFGen where -- TODO Ouch! This is really not nice.
  put = put . show
  get = read <$> get

instance Binary SlaveState

newtype InitializingMsg = InitializingMsg SlaveState
  deriving (Typeable, Generic)

instance Binary InitializingMsg

data NumberMsg = NumberMsg
  { _numberMsgTimestamp :: UTCTime
  , _numberMsgValue :: Double
  } deriving (Eq, Show, Typeable, Generic)

instance Binary NumberMsg

data FinishNow = FinishNow
  deriving (Typeable, Generic)

instance Binary FinishNow

data RestartedPeerMsg = RestartedPeerMsg ProcessId ProcessId
  deriving (Show, Typeable, Generic)

instance Binary RestartedPeerMsg

data SlaveInter
  = SlaveContinue SlaveState
  | SlaveFinished

makeLenses 'SlaveState
makeLenses 'NumberMsg

----------------------------------------------------------------------------
-- Slave logic

slave :: Maybe SlaveState -> Process ()
slave = \case
  Nothing -> do
    -- NOTE We haven't received the state yet (have to send it separately
    -- because we don't know the full list of process ids of peers when we
    -- spawn slave processes). In that case we wait for an initializing
    -- message.
    InitializingMsg st <- expect
    slave (Just st)
  Just st -> do
    ctime <- liftIO getCurrentTime
    mfinished <- receiveTimeout 0 -- Just check for incoming messages
                                  -- without blocking.
      [ match $ \FinishNow -> do
          -- NOTE This could be optimized but it looks like performance of
          -- this bit is not of much interest in this particular task.
          let l = sortBy
                    (comparing (view numberMsgTimestamp))
                    (st ^. sstReceived)
              s = sum $ zipWith (*) [1..] (view numberMsgValue <$> l)
              m = length l
          nid <- getSelfNode
          pid <- getSelfPid
          say $ "Process " ++ show pid ++ " on node " ++ show nid
            ++ " finished with results: |m|="
            ++ show m ++ ", sigma=" ++ show s
          return SlaveFinished
        -- NOTE This RestartedPeerMsg thing does not quite work because it
        -- arrives mostly after start of grace period when we process the
        -- accumulated messages sent before start of grace period and then
        -- it can't make any difference. So died node typically finishes
        -- with |m|=0 in my tests. This could be avoided I guess if time
        -- between message were longer and they did not accumulate in such
        -- quantities before RestartedPeerMsg in the message queue.
      , match $ \(RestartedPeerMsg old new) ->
          return . SlaveContinue $ st & sstPeers %~ E.insert new . E.delete old
      , match $ \numberMsg ->
          return . SlaveContinue $ st & sstReceived %~ (numberMsg:)
      ]
    case mfinished of
      Nothing ->
        -- NOTE No messages, we can as well send something unless the grace
        -- period has started. By checking against the pre-calculated start
        -- of the grace period we can ensure that once GP starts literally
        -- no message will be sent.
        if ctime < st ^. sstGracePeriodStart
          then do
            let f gen pid = do
                  let (w32, gen') = TF.next gen
                      x = fromIntegral (w32 + 1) / 0x100000000
                  send pid (NumberMsg ctime x)
                  return gen'
            newGen <- foldM f (st ^. sstTFGen) (st ^. sstPeers)
            slave . Just $ st & sstTFGen .~ newGen
          else slave (Just st)
      Just (SlaveContinue st') ->
        slave (Just st')
      Just SlaveFinished ->
        return ()

remotable ['slave]

----------------------------------------------------------------------------
-- Master logic

master
  :: Backend           -- ^ Backend thing, so we can kill all slaves
  -> Natural           -- ^ For how many seconds to send the messages
  -> Natural           -- ^ Grace period duration
  -> TF.TFGen          -- ^ Seed for random number generator
  -> [NodeId]          -- ^ List of all detected nodes
  -> Process ()
master backend sendFor waitFor seed nids = do
  say "Spawning slave processes"
  say (show nids)
  pidsInitial <- fmap M.fromList . forM nids $ \nid -> do
    pid <- spawn nid ($(mkClosure 'slave) (Nothing :: Maybe SlaveState))
    return (pid, nid)
  pidsRef <- liftIO (newIORef pidsInitial)
  say "Sending initializing messages"
  ctime <- liftIO getCurrentTime
  tfgen <- liftIO (newIORef seed)
  let gracePeriodStart = addUTCTime (fromIntegral sendFor) ctime
      gracePeriodEnd   = addUTCTime (fromIntegral (sendFor + waitFor)) ctime
      mkSlaveStateWith pids = do
        (gen0,gen1) <- TF.split <$> liftIO (readIORef tfgen)
        liftIO (writeIORef tfgen gen0)
        return SlaveState
          { _sstPeers            = pids
          , _sstGracePeriodStart = gracePeriodStart
          , _sstReceived         = []
          , _sstTFGen            = gen1 }
  let pidsInitialSet = M.keysSet pidsInitial
  forM_ pidsInitialSet $ \pid -> do
    void (monitor pid)
    mkSlaveStateWith (E.delete pid pidsInitialSet)
      >>= send pid . InitializingMsg
  say $ "Waiting for start of the grace period: " ++ show gracePeriodStart
  fix $ \continue -> do
    t  <- liftIO getCurrentTime
    mr <- expectTimeout 0
    case mr of
      Nothing ->
        when (t < gracePeriodEnd) $ do
          liftIO (threadDelay 100000)
          continue
      Just (ProcessMonitorNotification monitorRef pid death) -> do
        -- NOTE Something went wrong with our node, try to restart it with
        -- the default state.
        if isRecoverable death
          then do
            say $ "Process " ++ show pid ++ " died, restarting on the same node…"
            unmonitor monitorRef
            nid <- (M.! pid) <$> liftIO (readIORef pidsRef)
            pidsRecent <- M.delete pid <$> liftIO (readIORef pidsRef)
            pid' <- mkSlaveStateWith (M.keysSet pidsRecent) >>=
              spawn nid . $(mkClosure 'slave) . Just
            void (monitor pid')
            liftIO (writeIORef pidsRef (M.insert pid' nid pidsRecent))
            forM_ (M.keys pidsRecent) $ \pidi ->
              send pidi (RestartedPeerMsg pid pid')
          else do
            say $ "Process " ++ show pid ++ " died, can't restart it…"
            liftIO (modifyIORef pidsRef (M.delete pid))
        continue
  -- NOTE Need to send this special message now so we know when we have
  -- processed all messages and do not need to wait for more.
  pidsFinal <- liftIO (readIORef pidsRef)
  forM_ (M.keys pidsFinal) $ \pid ->
    send pid FinishNow
  say $ "Waiting for end of the grace period:   " ++ show gracePeriodEnd
  fix $ \continue -> do
    t <- liftIO getCurrentTime
    when (t < gracePeriodEnd) $ do
      liftIO (threadDelay 500000)
      continue
  say "Time is up, killing all slaves"
  -- NOTE Not really necessary but the document says “If result isn't
  -- printed till now, program is killed”. It's not clear whether slave
  -- nodes should be killed or just master, but let's kill'em all.
  terminateAllSlaves backend

----------------------------------------------------------------------------
-- Main and parser

main :: IO ()
main = do
  opts <- execParser parserInfo
  case opts of
    Slave host service ->
      initializeBackend host service remoteTable
        >>= startSlave
    Master host service nodeListFile sendFor waitFor seed -> do
      r <- decodeFileEither nodeListFile
      case r of
        Left err -> do
          hPutStrLn stderr (prettyPrintParseException err)
          exitWith (ExitFailure 1)
        Right (NodeList nodeList) -> do
          backend <- initializeBackend host service remoteTable
          startMaster backend $ \allNodes ->
            -- NOTE This is in assumption that node lists you mention are
            -- used to select a subset of all automatically discovered
            -- nodes.
            master backend sendFor waitFor (TF.mkTFGen $ fromIntegral seed)
              (NE.toList nodeList `intersect` allNodes)

parserInfo :: ParserInfo Options
parserInfo = info (helper <*> optionParser)
  ( fullDesc <>
    progDesc "A solution to IOHK test task…" <>
    header "iohktt — fun with random numbers" )

optionParser :: Parser Options
optionParser = subparser
  (  command "slave"
     (info (helper <*> (Slave
       <$> argument str (metavar "HOST" <> help "Host name")
       <*> argument str (metavar "SERVICE" <> help "Service name")))
     (progDesc "Run a slave process"))
  <> command "master"
     (info (helper <*> (Master
       <$> argument str (metavar "HOST" <> help "Host name")
       <*> argument str (metavar "SERVICE" <> help "Service name"))
       <*> strOption
       ( long "node-list"
       <> short 'n'
       <> value "node-list.yaml"
       <> metavar "NODELIST"
       <> showDefault
       <> help "YAML file containing the node lists to use" )
       <*> option parseNatural
       ( long "send-for"
       <> short 'k'
       <> value 30
       <> metavar "K"
       <> showDefault
       <> help "For how many seconds the system should send messages" )
       <*> option parseNatural
       ( long "wait-for"
       <> short 'l'
       <> value 30
       <> metavar "L"
       <> showDefault
       <> help "Duration (in seconds) of the grace period" )
       <*> option parseNatural
       ( long "with-seed"
       <> short 's'
       <> value 0
       <> metavar "S"
       <> showDefault
       <> help "The seed to use for random number generation" ))
     (progDesc "Run a master process")))

----------------------------------------------------------------------------
-- Helpers, etc.

remoteTable :: RemoteTable
remoteTable = Main.__remoteTable initRemoteTable

parseNatural :: ReadM Natural
parseNatural = eitherReader $ \s ->
  case readMaybe s of
    Nothing -> Left "Expected a positive integer."
    Just x  -> Right x

isRecoverable :: DiedReason -> Bool
isRecoverable = \case
  DiedNormal      -> True
  DiedException _ -> True
  _               -> False
