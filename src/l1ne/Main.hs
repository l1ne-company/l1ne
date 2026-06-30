module Main where

import Cli qualified
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = getArgs >>= either die Cli.dispatch . Cli.parseArgs
