{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

module Main (main) where

import Control.Distributed.Process
import Control.Distributed.Process.Backend.SimpleLocalnet
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node (initRemoteTable)
import Control.Lens (makeLenses, (^.))
import Control.Monad
import Data.Aeson hiding (Options)
import Data.Binary
import Data.Char (toLower)
import Data.List (intersect)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Monoid
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

----------------------------------------------------------------------------
-- Slave logic

slave :: Process ()
slave = return ()

remotable ['slave]

----------------------------------------------------------------------------
-- Master logic

master :: [NodeId] -> Process ()
master _ = return ()

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
            master $ NE.toList nodeList `intersect` allNodes

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
