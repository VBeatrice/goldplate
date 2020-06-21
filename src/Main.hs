{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
module Main
    ( main
    ) where


import           Control.Applicative       ((<|>))
import           Control.Concurrent        (threadDelay)
import qualified Control.Concurrent.Async  as Async
import qualified Control.Concurrent.MVar   as MVar
import           Control.Exception         (Exception, throwIO)
import           Control.Monad             (forM, forM_, forever, mzero, unless,
                                            when)
import qualified Data.Aeson.Encode.Pretty  as Aeson.Pretty
import qualified Data.Aeson.Extended       as A
import           Data.Algorithm.Diff
import           Data.Algorithm.DiffOutput
import qualified Data.ByteString           as B
import qualified Data.ByteString.Lazy      as BL
import           Data.Function             (on)
import qualified Data.HashMap.Strict       as HMS
import qualified Data.IORef                as IORef
import qualified Data.List                 as List
import qualified Data.Text                 as T
import qualified Data.Text.Encoding        as T
import           Data.Time                 (NominalDiffTime, diffUTCTime,
                                            getCurrentTime)
import           Data.Typeable             (Typeable)
import           Data.Version              (showVersion)
import qualified Options.Applicative       as OA
import           Paths_goldplate           (version)
import           System.Directory          (doesDirectoryExist, doesFileExist,
                                            removeDirectoryRecursive,
                                            removeFile, withCurrentDirectory)
import           System.Environment        (getEnvironment)
import           System.Exit               (ExitCode (..), exitFailure)
import           System.FilePath           (dropExtension, isAbsolute,
                                            isPathSeparator, normalise,
                                            takeBaseName, takeDirectory, (</>))
import qualified System.FilePath.Glob      as Glob
import qualified System.IO                 as IO
import qualified System.Process            as Process
import           Text.Printf               (printf)
import qualified Text.Regex.PCRE.Simple    as Pcre


-- | Environment for splicing in things.
type SpliceEnv = [(String, String)]

data MissingEnvVar = MissingEnvVar String
    deriving (Typeable)

instance Show MissingEnvVar where
    show (MissingEnvVar k) = "Missing environment variable: " ++ k

instance Exception MissingEnvVar

-- | Splice in a string with "Hello ${FOO}" syntax.
splice :: SpliceEnv -> String -> Either MissingEnvVar String
splice env = go
  where
    go str = case break (== '$') str of
        -- Splice
        (xs, '$' : '{' : ys) -> case break (== '}') ys of
            (key, '}' : zs) -> case lookup key env of
                Nothing  -> Left $ MissingEnvVar key
                Just val -> fmap ((xs ++ val) ++) (go zs)
            (_, _) -> fmap ((xs ++ "${") ++) (go ys)
        -- Escape
        (xs, '$' : '$' : ys) ->
            let (dollars, zs) = break (== '{') ys in
            if all (== '$') dollars && "{" `List.isPrefixOf` zs
                then (xs ++) . (dollars ++) . ("${" ++) <$> go (drop 1 zs)
                else (xs ++) . ("$$" ++) <$> go ys
        (xs, []) -> Right xs
        (xs, (y : ys)) -> (xs ++) . (y :) <$> (go ys)


-- | The type parameter indicates the fields that we allow splicing over.
data Spec a = Spec
    { sInputFiles :: !(Maybe a)
    , sCommand    :: !a
    , sArguments  :: ![a]
    , sStdin      :: !(Maybe (A.Multiple a))
    , sEnv        :: ![(a, a)]
    , sAsserts    :: ![Assert a]
    } deriving (Foldable, Functor, Traversable)

instance A.FromJSON (Spec String) where
    parseJSON = A.withObject "FromJSON Spec" $ \o -> Spec
        <$> o A..:? "input_files"
        <*> o A..:  "command"
        <*> o A..:? "arguments" A..!= []
        <*> o A..:? "stdin"
        <*> (maybe [] HMS.toList <$> o A..:? "environment")
        <*> o A..:  "asserts"


type PostProcess = [PostProcessStep]

data PostProcessStep
    = PrettifyJsonStep
    | ReplaceStep !Pcre.Regex !T.Text

instance A.FromJSON PostProcessStep where
    parseJSON (A.String s) = case s of
        "prettify_json" -> pure PrettifyJsonStep
        _               -> fail $ "Unknown PostProcessStep: " ++ show s

    parseJSON (A.Object o) = ReplaceStep
        <$> (do
                p <- o A..: "pattern"
                either (fail . show) return (Pcre.compile copts eopts p))
        <*> o A..: "replacement"
      where
        copts = Pcre.optionUtf8 <> Pcre.optionMultiline
        eopts = mempty

    parseJSON _ = mzero

postProcess :: PostProcess -> B.ByteString -> B.ByteString
postProcess ps bs0 = List.foldl' (flip postProcessStep) bs0 ps

postProcessStep :: PostProcessStep -> B.ByteString -> B.ByteString
postProcessStep PrettifyJsonStep bs = maybe bs
    (BL.toStrict . Aeson.Pretty.encodePretty' prettyConfig)
    (A.decodeStrict bs :: Maybe A.Value)
  where
    prettyConfig = Aeson.Pretty.defConfig
        { Aeson.Pretty.confIndent  = (Aeson.Pretty.Spaces 2)
        , Aeson.Pretty.confCompare = compare
        }

postProcessStep (ReplaceStep regex replacement) bs =
    either (const bs) T.encodeUtf8 .
    Pcre.replaceAll regex replacement $ T.decodeUtf8 bs


-- | Asserts that can happen after an execution.
data Assert a
    = ExitCodeAssert !Int
    | StdoutAssert
        { stdoutFilePath    :: !a
        , stdoutPostProcess :: !PostProcess
        }
    | StderrAssert
        { stderrFilePath    :: !a
        , stderrPostProcess :: !PostProcess
        }
    | CreatedFileAssert
        { createdFilePath        :: !a
        , createdFileContents    :: !(Maybe a)
        , createdFilePostProcess :: !PostProcess
        }
    | CreatedDirectoryAssert
        { createdDirectoryPath   :: !a
        }
    deriving (Foldable, Functor, Traversable)

instance A.FromJSON a => A.FromJSON (Assert a) where
    parseJSON = A.withObject "FromJSON Assert" $ \o ->
        (ExitCodeAssert <$> o A..: "exit_code") <|>
        (StdoutAssert
            <$> o A..: "stdout"
            <*> parsePostProcess o) <|>
        (StderrAssert
            <$> o A..: "stderr"
            <*> parsePostProcess o) <|>
        (CreatedFileAssert
            <$> o A..: "created_file"
            <*> o A..:? "contents"
            <*> parsePostProcess o) <|>
        (CreatedDirectoryAssert
            <$> o A..: "created_directory")
      where
        parsePostProcess o =
            maybe [] A.multipleToList <$> o A..:? "post_process"

describeAssert :: Assert a -> String
describeAssert (ExitCodeAssert     _)     = "exit_code"
describeAssert (StdoutAssert       _ _)   = "stdout"
describeAssert (StderrAssert       _ _)   = "stderr"
describeAssert (CreatedFileAssert  _ _ _) = "created_file"
describeAssert (CreatedDirectoryAssert _) = "created_directory"

data Verbosity = Debug | Message | Error
    deriving (Eq, Ord)

type Logger = Verbosity -> [String] -> IO ()

makeLogger :: Bool -> IO Logger
makeLogger verbose = do
    lock <- MVar.newMVar ()
    return $ \verbosity msgs ->
        unless (not verbose && verbosity == Debug) $
            MVar.withMVar lock $ \() -> mapM_ (IO.hPutStrLn IO.stderr) msgs

data Execution = Execution
    { executionInputFile :: Maybe FilePath
    , executionCommand   :: FilePath
    , executionArguments :: [String]
    , executionStdin     :: Maybe (A.Multiple String)
    , executionAsserts   :: [Assert String]
    , executionEnv       :: SpliceEnv
    , executionSpecPath  :: FilePath
    , executionSpecName  :: String
    , executionDirectory :: FilePath
    }

specExecutions :: FilePath -> Spec String -> IO [Execution]
specExecutions specPath spec = do
    let specBaseName  = takeBaseName  specPath
        specDirectory = takeDirectory specPath
        specName      = dropExtension specBaseName

    -- Compute initial environment to get input files.
    env0 <- getEnvironment
    let env1 =
            List.nubBy ((==) `on` fst) $
                ("GOLDPLATE_NAME", specName) :
                ("GOLDPLATE_FILE", specBaseName) :
                sEnv spec ++ env0

    -- Get a list of concrete input files (a list maybes).
    concreteInputFiles <- case sInputFiles spec of
        Nothing    -> return [Nothing]
        Just glob0 -> do
            glob <- hoistEither $ splice env1 glob0
            inputFiles <- withCurrentDirectory specDirectory $ do
                matches <- globCurrentDir glob
                length matches `seq` return matches
            return (map (Just . normalise) inputFiles)

    -- Create an execution for every concrete input.
    forM concreteInputFiles $ \mbInputFile -> do
        -- Extend environment.
        let env2 = case mbInputFile of
                Nothing        -> env1
                Just inputFile ->
                    ("GOLDPLATE_INPUT_FILE", inputFile) :
                    ("GOLDPLATE_INPUT_NAME", dropExtension inputFile) :
                    env1

        -- Return execution after doing some splicing.
        hoistEither $ do
            spec' <- traverse (splice env2) spec
            pure Execution
                { executionInputFile = mbInputFile
                , executionCommand   = sCommand spec'
                , executionArguments = sArguments spec'
                , executionStdin     = sStdin spec'
                , executionAsserts   = sAsserts spec'
                , executionEnv       = env2
                , executionSpecPath  = specPath
                , executionSpecName  = specName
                , executionDirectory = specDirectory
                }
  where
    hoistEither :: Either MissingEnvVar a -> IO a
    hoistEither = either throwIO return

executionHeader :: Execution -> String
executionHeader execution =
    executionSpecPath execution ++
    case executionInputFile execution of
        Nothing -> ": "
        Just fp -> " (" ++ fp ++ "): "

data Env = Env
    { envLogger        :: !Logger
    , envDiff          :: !Bool
    , envPrettyDiff    :: !Bool
    , envFix           :: !Bool
    , envCountAsserts  :: !(IORef.IORef Int)
    , envCountFailures :: !(IORef.IORef Int)
    }

incrementCount :: IORef.IORef Int -> IO ()
incrementCount ref = IORef.atomicModifyIORef' ref (\x -> (x + 1, ()))

data ExecutionResult = ExecutionResult
    { erExitCode :: !ExitCode
    , erStdout   :: !B.ByteString
    , erStderr   :: !B.ByteString
    } deriving (Show)

runExecution
    :: Env -> Execution -> IO ()
runExecution env execution@Execution {..} = do
    envLogger env Debug [executionHeader execution ++ "running..."]

    -- Create a "CreateProcess" description.
    let createProcess = (Process.proc executionCommand executionArguments)
            { Process.env     = Just executionEnv
            , Process.cwd     = Just executionDirectory
            , Process.std_in  = Process.CreatePipe
            , Process.std_out = Process.CreatePipe
            , Process.std_err = Process.CreatePipe
            }

    -- Actually run the process.
    envLogger env Debug [executionHeader execution ++
        executionCommand ++ " " ++ unwords executionArguments]
    (Just hIn, Just hOut, Just hErr, hProc) <-
        Process.createProcess createProcess

    let writeStdin = do
            case executionStdin of
                Nothing -> pure ()
                Just (A.Single str) -> IO.hPutStr hIn str
                Just (A.Multiple strs) -> mapM_ (IO.hPutStrLn hIn) strs
            IO.hClose hIn
    Async.withAsync writeStdin $ \_ ->
        Async.withAsync (B.hGetContents hOut) $ \outAsync ->
        Async.withAsync (B.hGetContents hErr) $ \errAsync ->
        Async.withAsync (Process.waitForProcess hProc) $ \exitAsync -> do

        -- Get output.
        !exitCode  <- Async.wait exitAsync
        !actualOut <- Async.wait outAsync
        !actualErr <- Async.wait errAsync
        let executionResult = ExecutionResult
                { erExitCode = exitCode
                , erStdout   = actualOut
                , erStderr   = actualErr
                }

        -- Dump stderr/stdout if in debug.
        envLogger env Debug [executionHeader execution ++ "finished"]
        envLogger env Debug [executionHeader execution ++ "stdout:", show actualOut]
        envLogger env Debug [executionHeader execution ++ "stderr:", show actualErr]

        -- Perform checks.
        envLogger env Debug [executionHeader execution ++ "checking assertions..."]
        forM_ executionAsserts $ runAssert env execution executionResult
        envLogger env Debug [executionHeader execution ++ "done"]


-- | Check an assertion.
runAssert :: Env -> Execution -> ExecutionResult -> Assert String -> IO ()
runAssert env execution@Execution {..} ExecutionResult {..} assert =
    case assert of
        ExitCodeAssert expectedExitCode -> do
            let actualExitCode = case erExitCode of
                    ExitSuccess   -> 0
                    ExitFailure c -> c
            assertTrue (actualExitCode == expectedExitCode) $
                "expected " ++ show expectedExitCode ++
                " but got " ++ show actualExitCode

        StdoutAssert {..} -> checkAgainstFile
            (inExecutionDir stdoutFilePath) stdoutPostProcess erStdout

        StderrAssert {..} -> checkAgainstFile
            (inExecutionDir stderrFilePath) stderrPostProcess erStderr

        CreatedFileAssert {..} -> do
            let path = inExecutionDir createdFilePath
            exists <- doesFileExist path
            assertTrue exists $ createdFilePath ++ " was not created"
            when exists $ do
                case createdFileContents of
                    Nothing           -> return ()
                    Just expectedPath -> do
                        !actual <- readFileOrEmpty path
                        checkAgainstFile
                            (inExecutionDir expectedPath)
                            createdFilePostProcess actual
                removeFile path
                envLogger env Debug [executionHeader execution ++
                    "removed " ++ createdFilePath]

        CreatedDirectoryAssert {..} -> do
            let path = inExecutionDir createdDirectoryPath
            exists <- doesDirectoryExist path
            assertTrue exists $ createdDirectoryPath ++ " was not created"
            when exists $ do
                removeDirectoryRecursive path
                envLogger env Debug [executionHeader execution ++
                    "removed " ++ createdDirectoryPath]
  where
    inExecutionDir :: FilePath -> FilePath
    inExecutionDir fp = if isAbsolute fp then fp else executionDirectory </> fp

    checkAgainstFile :: FilePath -> PostProcess -> B.ByteString -> IO ()
    checkAgainstFile expectedPath processor actual0 = do
        expected <- readFileOrEmpty expectedPath
        let !actual1 = postProcess processor actual0
        assertTrue (actual1 == expected) "does not match"
        when (envDiff env && actual1 /= expected) $ do
            envLogger env Message
                [ executionHeader execution ++ "expected:"
                , show expected
                , executionHeader execution ++ "actual:"
                , show actual1
                ]
        let diff :: [Diff [String]] = either (const []) id $ do
                expected' <- T.unpack <$> T.decodeUtf8' expected
                actual1'  <- T.unpack <$> T.decodeUtf8' actual1
                return $
                    getGroupedDiff
                        (lines expected')
                        (lines actual1')
        when (envPrettyDiff env && actual1 /= expected && not (null diff)) $ do
            envLogger env Message
                [ executionHeader execution ++ "diff:"
                , ppDiff diff
                ]
        when (envFix env && actual1 /= expected) $ do
            B.writeFile expectedPath actual1
            envLogger env Message
                [executionHeader execution ++ "fixed " ++ expectedPath]

    assertTrue :: Bool -> String -> IO ()
    assertTrue test err = do
        incrementCount (envCountAsserts env)
        if test
            then
                envLogger env Debug [executionHeader execution ++
                    describeAssert assert ++ ": OK"]
            else do
                envLogger env Error [executionHeader execution ++
                    describeAssert assert ++ ": " ++ err]
                incrementCount (envCountFailures env)

readFileOrEmpty :: FilePath -> IO B.ByteString
readFileOrEmpty fp = do
    exists <- doesFileExist fp
    if exists then B.readFile fp else return B.empty


-- | Recursively finds all '.goldplate' files in bunch of files or directories.
findSpecs :: [FilePath] -> IO [FilePath]
findSpecs fps = fmap concat $ forM fps $ \fp -> do
    isDir <- doesDirectoryExist fp
    case isDir of
        False -> return [fp]
        True  -> Glob.globDir1 (Glob.compile "**/*.goldplate") fp


-- | Perform a glob match in the current directory.
--
-- This is a drop-in replacement for `glob` from the `Glob` library, which has a
-- an annoying tendency to return absolute file paths.
globCurrentDir :: String -> IO [FilePath]
globCurrentDir pattern =
    map dropLeadingDot <$> Glob.globDir1 (Glob.compile pattern) "."
  where
    dropLeadingDot fp0 = case break isPathSeparator fp0 of
        (".", fp1) -> drop 1 fp1
        _          -> fp0


data Options = Options
    { oPaths      :: [FilePath]
    , oVerbose    :: Bool
    , oDiff       :: Bool
    , oPrettyDiff :: Bool
    , oFix        :: Bool
    , oJobs       :: Int
    }


parseOptions :: OA.Parser Options
parseOptions = Options
    <$> OA.some (OA.strArgument (
            OA.metavar "PATH" <>
            OA.help    "Test files/directories"))
    <*> OA.switch (
            OA.short   'v' <>
            OA.help    "Be more verbose")
    <*> OA.switch (
            OA.long    "diff" <>
            OA.help    "Show differences in files")
    <*> OA.switch (
            OA.long    "pretty-diff" <>
            OA.help    "Show differences in files, output in patch format")
    <*> OA.switch (
            OA.long    "fix" <>
            OA.help    "Attempt to fix broken tests")
    <*> OA.option OA.auto (
            OA.long    "jobs" <>
            OA.short   'j'    <>
            OA.value   1      <>
            OA.help    "Number of worker jobs")

parserInfo :: OA.ParserInfo Options
parserInfo = OA.info (OA.helper <*> parseOptions) $
    OA.fullDesc <>
    OA.header ("goldplate v" <> showVersion version)


-- | Spawn a worker thread that takes workloads from a shared pool.
worker
    :: IORef.IORef [a]                         -- ^ Ref to a pool of work
    -> (a -> IO ())                            -- ^ Worker function
    -> IO ()
worker pool f = do
    mbWorkload <- IORef.atomicModifyIORef' pool $ \case
        []       -> ([], Nothing)
        (x : xs) -> (xs, Just x)
    case mbWorkload of
        Nothing       -> return ()
        Just workload -> f workload >> worker pool f


main :: IO ()
main = do
    startTime <- getCurrentTime
    options   <- OA.execParser parserInfo
    env       <- Env
        <$> makeLogger (oVerbose options)
        <*> pure (oDiff options)
        <*> pure (oPrettyDiff options)
        <*> pure (oFix options)
        <*> IORef.newIORef 0
        <*> IORef.newIORef 0

    -- Find all specs and decode them.
    specPaths <- findSpecs (oPaths options)
    specs     <- forM specPaths $ \specPath -> do
        !errOrSpec <- A.eitherDecodeStrict <$> B.readFile specPath
        case errOrSpec of
            Right !spec -> return (specPath, spec)
            Left  !err  -> do
                envLogger env Error
                    [specPath ++ ": could not parse JSON: " ++ err]
                exitFailure

    -- Each spec might produce a number of executions.  We can't really
    -- parallelize this because 'specExecutions' needs to change the working
    -- directory all the time and that might mess with our tests.
    let numSpecs = length specs
    envLogger env Message ["Found " ++ show numSpecs ++ " specs"]
    executions <- fmap concat $ forM specs $
        \(specPath, spec) -> specExecutions specPath spec

    -- Create a pool full of executions.
    let numExecutions = length executions
        numJobs       = oJobs options
    envLogger env Message ["Running " ++ show numExecutions ++
        " executions in " ++ show numJobs ++ " jobs"]
    pool <- IORef.newIORef executions

    -- Spawn a worker to report progress
    progress <- Async.async $ forever $ do
        threadDelay $ 10 * 1000 * 1000
        remaining <- length <$> IORef.readIORef pool
        envLogger env Message $ return $
            "Progress: " ++ show (numExecutions - remaining) ++ "/" ++
            show numExecutions ++ "..."

    -- Spawn some workers to run the executions.
    Async.replicateConcurrently_ numJobs $ worker pool (runExecution env)
    Async.cancel progress

    -- Tell the time.
    endTime <- getCurrentTime
    envLogger env Message
        ["Finished in " ++ showDiffTime (endTime `diffUTCTime` startTime)]

    -- Report summary.
    asserts       <- IORef.readIORef (envCountAsserts  env)
    failures      <- IORef.readIORef (envCountFailures env)
    if failures == 0
        then
            envLogger env Message [
                "Ran " ++ show numSpecs ++ " specs, " ++
                show numExecutions ++ " executions, " ++
                show asserts ++ " asserts, all A-OK!"]
        else do
            envLogger env Error [
                "Ran " ++ show numSpecs ++ " specs, " ++
                show numExecutions ++ " executions, " ++
                show asserts ++ " asserts, " ++ show failures ++ " failed."]
            exitFailure


showDiffTime :: NominalDiffTime -> String
showDiffTime dt = printf "%.2fs" (fromRational (toRational dt) :: Double)
