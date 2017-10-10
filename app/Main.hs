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
  { _sstPeers :: [ProcessId]
    -- ^ A list of peer processes to which to send the messages
  , _sstGracePeriodStart :: UTCTime
    -- ^ Absolute time up to which to send the messages
  , _sstReceived :: [NumberMsg]
    -- ^ Numbers received so far
  , _sstTFGen :: TF.TFGen
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
          return True
      , match $ \numberMsg -> do
          slave . Just $ st & sstReceived %~ (numberMsg:)
          return False ]
    case mfinished of
      Nothing ->
        -- No messages, we can as well send something unless the grace
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
      Just False ->
        slave (Just st)
      Just True ->
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
  pids <- forM nids $ \nid ->
    spawn nid ($(mkClosure 'slave) (Nothing :: Maybe SlaveState))
  say "Sending initializing messages"
  ctime <- liftIO getCurrentTime
  tfgen <- liftIO (newIORef seed)
  let gracePeriodStart = addUTCTime (fromIntegral sendFor) ctime
      gracePeriodEnd   = addUTCTime (fromIntegral (sendFor + waitFor)) ctime
      mkSlaveStateFor pid = do
        (gen0,gen1) <- TF.split <$> liftIO (readIORef tfgen)
        liftIO (writeIORef tfgen gen0)
        return SlaveState
          { _sstPeers            = filter (/= pid) pids
          , _sstGracePeriodStart = gracePeriodStart
          , _sstReceived         = []
          , _sstTFGen            = gen1 }
  forM_ pids $ \pid ->
    mkSlaveStateFor pid >>= send pid . InitializingMsg
  -- TODO Also restart died processes here.
  say "Waiting for start of the grace period"
  waitTill gracePeriodStart
  -- Need to send this special message now that we know when we have
  -- processed all messages and do not need to wait for more.
  forM_ pids $ \pid ->
    send pid FinishNow
  say "Waiting for end of the grace period"
  waitTill gracePeriodEnd
  say "Time is up, killing all slaves"
  -- Not really necessary but the document says “If result isn't printed
  -- till now, program is killed”. It's not clear whether slave nodes should
  -- be killed or just master…
  terminateAllSlaves backend

waitTill :: UTCTime -> Process ()
waitTill t = fix $ \continue -> do
  ctime <- liftIO getCurrentTime
  when (ctime < t) $ do
    liftIO (threadDelay 500000)
    continue

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
       <> value 10
       <> metavar "K"
       <> showDefault
       <> help "For how many seconds the system should send messages" )
       <*> option parseNatural
       ( long "wait-for"
       <> short 'l'
       <> value 5
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
