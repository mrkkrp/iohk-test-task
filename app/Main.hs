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
import Data.Char (toLower)
import Data.Function (fix)
import Data.List (intersect)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Monoid
import Data.Time
import Data.Typeable
import Data.Yaml hiding (Parser)
import GHC.Generics (Generic)
import Network.Socket (HostName, ServiceName)
import Network.Transport (EndPointAddress (..))
import Numeric.Natural
import Options.Applicative
import System.Environment (getArgs)
import System.Exit (exitWith, ExitCode (..))
import System.IO (hPutStrLn, stderr)
import System.Random.TF
import Text.Read (readMaybe)
import qualified Data.ByteString.Char8 as B8
import qualified Data.List.NonEmpty    as NE
import qualified Data.Vector           as V

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

data NodeList = NodeList (NonEmpty NodeId)

instance FromJSON NodeList where
  parseJSON v = NodeList . fmap (NodeId . EndPointAddress . B8.pack)
    <$> parseJSON v

data SlaveState = SlaveState
  { _sstPeers :: [ProcessId]
    -- ^ A list of peer processes to which to send the messages
  , _sstGracePeriodStart :: UTCTime
    -- ^ Absolute time up to which to send the messages
  , _sstReceived :: [Double]
    -- ^ Numbers received so far
  } deriving (Typeable, Generic)

-- NOTE An orphan instance, could be avoided with a newtype, but for the
-- purposes of this task it doesn't make any difference, it's not a library.

instance Binary UTCTime where
  put UTCTime {..} = do
    put (toModifiedJulianDay utctDay)
    put (diffTimeToPicoseconds utctDayTime)
  get = do
    utctDay     <- ModifiedJulianDay     <$> get
    utctDayTime <- picosecondsToDiffTime <$> get
    return UTCTime {..}

instance Binary SlaveState

data InitializingMsg = InitializingMsg SlaveState
  deriving (Typeable, Generic)

instance Binary InitializingMsg

data NumberMsg = NumberMsg Double
  deriving (Typeable, Generic)

instance Binary NumberMsg

makeLenses 'SlaveState

----------------------------------------------------------------------------
-- Slave logic

slave :: Maybe SlaveState -> Process ()
slave = \case
  Nothing -> do
    -- We haven't received the state yet (have to send it separately because
    -- we don't know the full list of process ids of peers when we spawn
    -- slave processes). In that case we wait for an initializing message.
    InitializingMsg st <- expect
    slave (Just st)
  Just st -> do
    -- Message receiving.
    ctime <- liftIO getCurrentTime
    if ctime >= st ^. sstGracePeriodStart
      then do
        let l = st ^. sstReceived
            s = getSum . mconcat $ zipWith
              (\i mi -> Sum (i * mi))
              [1..]
              (reverse l)
            m = length l
        pid <- getSelfPid
        say $ "Process " ++ show pid ++ " finished with results: |m|="
          ++ show m ++ ", sigma=" ++ show s
      else do
        NumberMsg x <- expect
        slave . Just $ st & sstReceived %~ (x:)

-- TODO 1) These thingies should also send the messages…

remotable ['slave]

----------------------------------------------------------------------------
-- Master logic

master :: Backend -> Natural -> Natural -> [NodeId] -> Process ()
master backend sendFor waitFor nids = do
  say "Spawning slave processes"
  pids <- forM nids $ \nid ->
    spawn nid ($(mkClosure 'slave) (Nothing :: Maybe SlaveState))
  say "Sending initializing messages"
  ctime <- liftIO getCurrentTime
  let gracePeriodStart = addUTCTime (fromIntegral sendFor) ctime
      gradePeriodEnd   = addUTCTime (fromIntegral (sendFor + waitFor)) ctime
      mkSlaveStateFor pid = SlaveState
        { _sstPeers            = filter (/= pid) pids
        , _sstGracePeriodStart = gracePeriodStart
        , _sstReceived         = [] }
  forM_ pids $ \pid ->
    send pid (mkSlaveStateFor pid)
  -- TODO 2) Also restart died processes here.
  say "Waiting for the end of grace period"
  waitTill gradePeriodEnd
  say "Time is up, killing all slaves"
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
            master backend sendFor waitFor
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
       <$> argument auto (metavar "HOST" <> help "Host name")
       <*> argument auto (metavar "SERVICE" <> help "Service name")))
     (progDesc "Run a slave process"))
  <> command "master"
     (info (helper <*> (Master
       <$> argument auto (metavar "HOST" <> help "Host name")
       <*> argument auto (metavar "SERVICE" <> help "Service name"))
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
