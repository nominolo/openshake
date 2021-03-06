#! /usr/bin/env runhaskell

\begin{code}
import Control.Concurrent
import Control.Concurrent.MVar

import qualified Control.Exception as Exception
import Control.Monad

import System.Environment
import System.Directory
import System.Exit
import System.FilePath
import System.Process
import System.Timeout

import System.IO.Temp

import Debug.Trace


withCurrentDirectory :: FilePath -> IO a -> IO a
withCurrentDirectory new_cwd act = Exception.bracket (do { old_cwd <- getCurrentDirectory; setCurrentDirectory new_cwd; return old_cwd }) setCurrentDirectory (\_ -> act)

isExitFailure :: ExitCode -> Bool
isExitFailure (ExitFailure _) = True
isExitFailure _ = False

doWhile_ :: IO a -> IO Bool -> IO ()
doWhile_ what test = go
  where go = what >> test >>= \b -> if b then go else return ()

removeFileIfExists :: FilePath -> IO ()
removeFileIfExists fp = doesFileExist fp >>= \exists -> when exists (removeFile fp)

touch :: FilePath -> IO ()
touch fp = runProcess "touch" [fp] Nothing Nothing Nothing Nothing Nothing >>= waitForProcess >> return ()

ms = (*1000)
seconds = (*1000000)

traceShowM :: (Monad m, Show a) => m a -> m a
traceShowM mx = mx >>= \x -> trace (show x) (return x)


assertEqualM :: (Eq a, Show a, Monad m) => a -> a -> m ()
assertEqualM expected actual = if expected == actual then return () else fail $ show expected ++ " /= " ++ show actual

assertIsM :: (Show a, Monad m) => (a -> Bool) -> a -> m ()
assertIsM expectation actual = if expectation actual then return () else fail $ show actual ++ " did not match our expectations"

clean :: [FilePath] -> IO ()
clean = mapM_ removeFileIfExists

-- | Allows us to timeout even blocking that is not due to the Haskell RTS, by running the action to time out on
-- another thread.
timeoutForeign :: Int -> IO () -> IO a -> IO (Maybe a)
timeoutForeign microsecs cleanup act = flip Exception.finally cleanup $ do
    mvar <- newEmptyMVar
    forkIO $ act >>= putMVar mvar -- NB: leaves the foreign thing running even once the timeout has passed!
    timeout microsecs $ takeMVar mvar

shake :: FilePath -> IO ExitCode
shake fp = do
   extra_args <- getArgs -- NB: this is a bit of a hack!
   
   ph <- runProcess "runghc" (["-i../../", fp] ++ extra_args) Nothing Nothing Nothing Nothing Nothing
   mb_ec <- timeoutForeign (seconds 5) (terminateProcess ph) $ waitForProcess ph
   case mb_ec of
     Nothing -> error "shake took too long to run!"
     Just ec -> return ec

-- | Shake can only detect changes that are reflected by changes to the modification time.
-- Thus if we expect a rebuild we need to wait for the modification time used by the system to actually change.
waitForModificationTimeToChange :: IO ()
waitForModificationTimeToChange = withSystemTempDirectory "openshake-test" $ \tmpdir -> do
    let testfile = tmpdir </> "modtime.txt"
    writeFile testfile ""
    init_mod_time <- getModificationTime testfile
    mb_unit <- timeout (seconds 5) $ (threadDelay (seconds 1) >> writeFile testfile "") `doWhile_` (fmap (== init_mod_time) (getModificationTime testfile))
    case mb_unit of
      Nothing -> error "The modification time doesn't seem to be changing"
      Just () -> return ()

mtimeSanityCheck :: IO ()
mtimeSanityCheck = flip Exception.finally (removeFileIfExists "delete-me") $ do
    writeFile "delete-me" ""
    mtime1 <- getModificationTime "delete-me"
    threadDelay (seconds 2)
    
    writeFile "delete-me" ""
    mtime2 <- getModificationTime "delete-me"
    threadDelay (seconds 2)
    
    touch "delete-me"
    mtime3 <- getModificationTime "delete-me"
    threadDelay (seconds 2)
    
    True `assertEqualM` (mtime1 /= mtime2 && mtime2 /= mtime3 && mtime1 /= mtime3)

main :: IO ()
main = do
    mtimeSanityCheck
    
    withCurrentDirectory "lexical-scope" $ do
        clean [".openshake-db"]
        
        ec <- shake "Shakefile.hs"
        ExitSuccess `assertEqualM` ec
    
    withCurrentDirectory "simple-c" $ do
        clean [".openshake-db", "Main", "main.o", "constants.h"]
        
        -- 1) Try a normal build. The first time around is a clean build, the second time we
        --    have to rebuild even though we already have Main:
        forM_ [42, 43] $ \constant -> do
            writeFile "constants.h" $ "#define MY_CONSTANT " ++ show constant
            
            ec <- shake "Shakefile.hs"
            ExitSuccess `assertEqualM` ec
        
            out <- readProcess "./Main" [] ""
            ("The magic number is " ++ show constant ++ "\n") `assertEqualM` out
            
            waitForModificationTimeToChange
        
        -- 2) Run without changing any files, to make sure that nothing gets spuriously rebuilt:
        let interesting_files = ["Main", "main.o"]
        old_mtimes <- mapM getModificationTime interesting_files
        ec <- shake "Shakefile.hs"
        ExitSuccess `assertEqualM` ec
        new_mtimes <- mapM getModificationTime interesting_files
        old_mtimes `assertEqualM` new_mtimes
        
        -- 3) Corrupt the database and check that Shake recovers
        writeFile ".openshake-db" "Junk!"
        ec <- shake "Shakefile.hs"
        ExitSuccess `assertEqualM` ec

    -- TODO: test that nothing goes wrong if we change the type of oracle between runs

    withCurrentDirectory "deserialization-changes" $ do
        clean [".openshake-db", "examplefile"]
        
        -- 1) First run has no database, so it is forced to create the file
        ec <- shake "Shakefile-1.hs"
        ExitSuccess `assertEqualM` ec
        
        x <- readFile "examplefile"
        "OK1" `assertEqualM` x
        
        -- 2) The second run has a "corrupt" database because answer serialisation is shorter
        ec <- shake "Shakefile-2.hs"
        ExitSuccess `assertEqualM` ec
        
        x <- readFile "examplefile"
        "OK2" `assertEqualM` x
        
        -- 2) The second run has a "corrupt" database because question serialisation is longer
        ec <- shake "Shakefile-3.hs"
        ExitSuccess `assertEqualM` ec
        
        x <- readFile "examplefile"
        "OK3" `assertEqualM` x

    withCurrentDirectory "cyclic" $ do
        clean [".openshake-db"]
        
        ec <- shake "Shakefile.hs"
        isExitFailure `assertIsM` ec
    
    withCurrentDirectory "cyclic-harder" $ do
        clean [".openshake-db"]
    
        ec <- shake "Shakefile.hs"
        isExitFailure `assertIsM` ec

\end{code}