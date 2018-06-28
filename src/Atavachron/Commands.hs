{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs #-}

-- |  High-level commands exposed to the command-line interface.
--
module Atavachron.Commands where

import Prelude hiding (concatMap)

import Codec.Serialise

import Control.Exception
import Control.Logging
import Control.Monad
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Trans.Resource

import qualified Data.ByteString.Lazy as LB
import Data.Maybe
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Time.Clock

import qualified System.IO as IO

import GHC.Conc (numCapabilities)

import Text.Printf

import System.FilePath.Glob
import qualified System.Directory as Dir
import qualified System.Posix.Files as Files

-- import Atavachron.Chunk.Encode (hexEncode)
import Atavachron.Path
import Atavachron.Tree (FileMeta(..), Diff(..))
import qualified Atavachron.Tree as Tree
import Atavachron.Repository (Repository(..), Snapshot(..), SnapshotName, CachedCredentials)
import qualified Atavachron.Repository as Repository
import Atavachron.Env
import Atavachron.Pipelines
import Atavachron.Streaming (mkTaskGroup)
import qualified Atavachron.Streaming as S

type FileGlob = Text

data Command
  = CInit      InitOptions
  | CBackup    BackupOptions
  | CVerify    VerifyOptions
  | CRestore   RestoreOptions
  | CSnapshots SnapshotOptions
  | CList      ListOptions
  | CDiff      DiffOptions
  | CKeys      KeyOptions
--  | Help

-- Wherefore art thou OverloadedRecordLabels?

data InitOptions = InitOptions
    { iRepoURL     :: Text
    }

data BackupOptions = BackupOptions
    { bRepoURL     :: Text
    , bSourceDir   :: Text
    , bGlobPair    :: GlobPair
    }

data VerifyOptions = VerifyOptions
    { vRepoURL     :: Text
    , vSnapshotID  :: SnapshotName
    , vGlobPair    :: GlobPair
    }

data RestoreOptions = RestoreOptions
    { rRepoURL     :: Text
    , rSnapshotID  :: SnapshotName
    , rTargetDir   :: Text
    , rGlobPair    :: GlobPair
    }
data SnapshotOptions = SnapshotOptions
    { sRepoURL     :: Text
    }

data ListOptions = ListOptions
    { lRepoURL     :: Text
    , lSnapshotID  :: SnapshotName
    , lGlobPair    :: GlobPair
    }

data DiffOptions = DiffOptions
    { dRepoURL     :: Text
    , dSnapshotID1 :: Text
    , dSnapshotID2 :: Text
    }

data KeyOptions = KeyOptions
    { kRepoURL     :: Text
    , kArgument    :: KeysArgument
    }

data KeysArgument
    = ListKeys
    | AddKey Text

data GlobPair = GlobPair
    { includeGlob :: Maybe FileGlob
    , excludeGlob :: Maybe FileGlob
    }

noGlobs :: GlobPair
noGlobs = GlobPair Nothing Nothing

runCommand :: Command -> IO ()
runCommand (CInit options)      = initialise options
runCommand (CBackup options)    = backup options
runCommand (CVerify options)    = verify options
runCommand (CRestore options)   = restore options
runCommand (CSnapshots options) = snapshots options
runCommand (CList options)      = list options
runCommand (CDiff options)      = diff options
runCommand (CKeys options)      = keys options

------------------------------------------------------------

initialise :: InitOptions -> IO ()
initialise InitOptions{..} = do
    pass <- newPassword
    cc   <- Repository.initRepository iRepoURL pass
    saveCredentials iRepoURL cc
    T.putStrLn $ "Repository created at " <> iRepoURL

backup :: BackupOptions -> IO ()
backup BackupOptions{..} = do
    sourceDir <- parseAbsDir' bSourceDir
    repo      <- authenticate bRepoURL
    runBackup repo sourceDir bGlobPair
    T.putStrLn $ "Backup complete."

verify :: VerifyOptions -> IO ()
verify VerifyOptions{..} = do
    repo      <- authenticate vRepoURL
    snap      <- getSnapshot repo  vSnapshotID
    runVerify repo snap vGlobPair
    T.putStrLn $ "Verification complete."

restore :: RestoreOptions -> IO ()
restore RestoreOptions{..} = do
    targetDir <- parseAbsDir' rTargetDir
    repo      <- authenticate rRepoURL
    snap      <- getSnapshot repo rSnapshotID
    runRestore repo snap targetDir rGlobPair
    T.putStrLn $ "Restore complete."

snapshots :: SnapshotOptions -> IO ()
snapshots SnapshotOptions{..} = listSnapshots sRepoURL

list :: ListOptions -> IO ()
list ListOptions{..} = listFiles lRepoURL lSnapshotID lGlobPair

diff :: DiffOptions -> IO ()
diff DiffOptions{..} = do
    repo      <- authenticate dRepoURL
    env       <- makeEnv repo rootDir noGlobs
    snap1     <- getSnapshot repo dSnapshotID1
    snap2     <- getSnapshot repo dSnapshotID2
    runResourceT
        . flip evalStateT initialProgress
        . flip runReaderT env
        . S.mapM_ (liftIO . printDiff)
        $ Tree.diff fst fst (S.lefts $ snapshotTree snap1)
                            (S.lefts $ snapshotTree snap2)
  where
    printDiff = \case
        Keep   _        -> return () -- don't print
        Insert (item,_) -> getFilePath (filePath item) >>= putStrLn . ("+ "<>)
        Change (item,_) -> getFilePath (filePath item) >>= putStrLn . ("c "<>)
        Delete (item,_) -> getFilePath (filePath item) >>= putStrLn . ("- "<>)

keys :: KeyOptions -> IO ()
keys KeyOptions{..} =
    case kArgument of
        ListKeys    -> listAccessKeys kRepoURL
        AddKey name -> addAccessKey kRepoURL name

listSnapshots :: Text -> IO ()
listSnapshots repoURL = do
    repo      <- authenticate repoURL
    flip S.mapM_ (Repository.listSnapshots repo) $ \(key, e'snap) ->
        case e'snap of
            Left ex            ->
                errorL' $ "Failed to fetch snapshot: " <> T.pack (show ex)
            Right Snapshot{..} -> do
                hostDir <- getFilePath sHostDir
                printf "%s | %-8.8s | %-8.8s | %-32.32s | %-16.16s | %-16.16s\n"
                       (T.unpack $ T.take 8 key)
                       (T.unpack sUserName)
                       (T.unpack sHostName)
                       hostDir
                       (show sStartTime)
                       (show sFinishTime)

listFiles :: Text -> SnapshotName -> GlobPair -> IO ()
listFiles repoURL partialKey globs = do
    repo <- authenticate repoURL
    env  <- makeEnv repo rootDir globs
    snap <- liftIO $ getSnapshot repo partialKey
    runResourceT
        . flip evalStateT initialProgress
        . flip runReaderT env
        . S.mapM_ (liftIO . printFile)
        . S.lefts
        . filterItems fst
        $ snapshotTree snap
  where
    printFile (item, {-Repository.ChunkList chunks-} _) = do
        -- print out as a relative path, i.e. without the leading '/'.
        fp <- getFilePath (relativise rootDir $ filePath item)
        putStrLn fp
        -- forM_ chunks $ T.putStrLn . hexEncode

listAccessKeys :: Text -> IO ()
listAccessKeys repoURL = do
    repo      <- authenticate repoURL
    S.mapM_ (T.putStrLn . fst) $ Repository.listAccessKeys (repoStore repo)

addAccessKey :: Text -> Text -> IO ()
addAccessKey repoURL name = do
    T.putStrLn "Checking existing credentials."
    repo <- authenticate repoURL
    T.putStrLn "Please provide the additional credentials."
    pass <- newPassword
    cc   <- Repository.newAccessKey (repoStore repo) (repoManifestKey repo) name pass
    saveCredentials repoURL cc

runBackup :: Repository -> Path Abs Dir -> GlobPair -> IO ()
runBackup repo sourceDir globs = do
    env      <- makeEnv repo sourceDir globs
    snapshot <-
        runResourceT
          . flip evalStateT initialProgress
          . flip runReaderT env
          $ backupPipeline sourceDir

    res <- Repository.putSnapshot repo snapshot
    case res of
        Left ex   -> errorL' $ "Failed to write snapshot: " <> T.pack (show ex)
        Right key -> do
            T.hPutStrLn IO.stderr $ "\nWrote snapshot " <> T.take 8 key
            runReaderT commitFilesCache env

runVerify :: Repository -> Snapshot -> GlobPair -> IO ()
runVerify repo snapshot globs = do
    env <- makeEnv repo rootDir globs
    runResourceT
        . flip evalStateT initialProgress
        . flip runReaderT env
        . S.mapM_ logFailed -- for now, just log files with errors
        $ verifyPipeline snapshot
  where
    logFailed (item, VerifyResult errors) =
        unless (null errors) $ do
            path <- liftIO $ getFilePath (filePath item)
            warn' $ "File has errors: " <> (T.pack path)

runRestore :: Repository -> Snapshot -> Path Abs Dir -> GlobPair -> IO ()
runRestore repo snapshot targetDir globs = do
    env <- makeEnv repo targetDir globs
    runResourceT
        . flip evalStateT initialProgress
        . flip runReaderT env
        $ restoreFiles snapshot

authenticate :: Text -> IO Repository
authenticate repoURL = do
    -- check for cached credentials
    m'cc <- loadCredentials repoURL
    case m'cc of
        Nothing -> newCredentials repoURL
        Just cc -> Repository.authenticate' repoURL cc

newCredentials :: Text -> IO Repository
newCredentials repoURL = do
    pass       <- askPassword
    (repo, cc) <- Repository.authenticate repoURL pass
    repo <$ saveCredentials repoURL cc

loadCredentials :: Text -> IO (Maybe CachedCredentials)
loadCredentials repoURL = do
    cachePath <- getCachePath
    filePath  <- mkCacheFileName cachePath repoURL "credentials" >>= getFilePath
    exists    <- Files.fileExist filePath
    if exists
        then do debug' $ "Using cached credentials."
                Just . deserialise <$> LB.readFile filePath
        else    return Nothing

saveCredentials :: Text -> CachedCredentials -> IO ()
saveCredentials repoURL cc = do
    cachePath <- getCachePath
    filePath  <- mkCacheFileName cachePath repoURL "credentials" >>= getFilePath
    LB.writeFile filePath (serialise cc)
    Files.setFileMode filePath (Files.ownerReadMode `Files.unionFileModes` Files.ownerWriteMode)
    T.putStrLn $ "Credentials cached at " <> T.pack filePath

-- TODO optionally read this from an Expresso config file?
makeEnv :: Repository -> Path Abs Dir -> GlobPair -> IO Env
makeEnv repo localDir globs = do
    debug' $ "Available cores: " <> T.pack (show numCapabilities)
    startT      <- getCurrentTime

    -- for now, a conservative size to minimise memory usage.
    let taskBufferSize = numCapabilities

    taskGroup   <- mkTaskGroup numCapabilities
    cachePath   <- getCachePath
    return Env
         { envRepository     = repo
         , envStartTime      = startT
         , envTaskBufferSize = taskBufferSize
         , envTaskGroup      = taskGroup
         , envRetries        = 5
         , envCachePath      = cachePath
         , envFilePredicate  = parseGlobPair globs
         , envDirectory      = localDir
         }

-- | For now, default to XDG standard
getCachePath :: IO (Path Abs Dir)
getCachePath =
    fromMaybe (errorL' "Cannot parse XDG directory") . parseAbsDir
        <$> Dir.getXdgDirectory Dir.XdgCache "atavachron"

-- | Logs and throws, if it cannot parse the path.
parseAbsDir' :: Text -> IO (Path Abs Dir)
parseAbsDir' t =
    case parseAbsDir (T.unpack t) of
        Nothing   -> errorL' $ "Cannot parse absolute path: " <> t
        Just path -> return path

-- | Logs and throws, if it cannot retrieve the snapshot
getSnapshot :: Repository -> Text -> IO Snapshot
getSnapshot repo partialKey = do
    e'snap <- Repository.getSnapshot repo partialKey
    case e'snap of
        Left ex    -> errorL' $ "Could not retrieve snapshot: " <> T.pack (show ex)
        Right snap -> return snap

parseGlobPair :: GlobPair -> FilePredicate
parseGlobPair GlobPair{..} = FilePredicate $ \path ->
    (&&) <$> applyPredicate includePred path <*> (not <$> applyPredicate excludePred path)
  where
    includePred = maybe allFiles parseGlob includeGlob
    excludePred = maybe noFiles  parseGlob excludeGlob

parseGlob :: Text -> FilePredicate
parseGlob g = FilePredicate $ \path ->
        match patt <$> getFilePath path
  where
    patt = simplify $ compile $ T.unpack g

newPassword :: IO Text
newPassword = do
    T.putStr "Enter password: "
    pass1 <- getPassword
    T.putStr "Re-enter password: "
    pass2 <- getPassword
    if pass1 /= pass2
       then T.putStrLn "Passwords do not match!" >> newPassword
       else return pass1

askPassword :: IO Text
askPassword = T.putStr "Enter password: " >> getPassword

getPassword :: IO Text
getPassword = do
    IO.hFlush IO.stdout
    bracket_ (IO.hSetEcho IO.stdin False)
             (IO.hSetEcho IO.stdin True >> IO.putChar '\n')
             T.getLine
