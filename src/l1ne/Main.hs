module Main where

import System.Environment (getArgs)
import System.Exit (exitFailure)
import qualified Cli

main :: IO ()
main = do
  args <- getArgs
  case Cli.parseArgs args of
    Left err -> do
      putStrLn $ "Error: " ++ err
      putStrLn ""
      putStrLn "Run 'l1ne --help' for usage information"
      exitFailure
    Right cmd -> Cli.dispatch cmd
