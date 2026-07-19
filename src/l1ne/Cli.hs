{-# LANGUAGE LambdaCase #-}

module Cli
  ( Command (..),
    parseArgs,
    dispatch,
  )
where

import Data.Maybe (fromMaybe)
import Parser qualified
import Syntax (Module)
import System.Exit (die)
import System.IO.Error (tryIOError)
import Tokenizer qualified

data Command
  = Compile FilePath -- Compile a source file
  | Help -- Show help
  | Version -- Show version
  deriving (Show, Eq)

parseArgs :: [String] -> Either String Command
parseArgs [] = Right Help
parseArgs [arg] = Right (fromMaybe (Compile arg) (lookup arg namedCommands))
parseArgs args = Left $ "Expected a single source file, got: " ++ unwords args

namedCommands :: [(String, Command)]
namedCommands =
  [ (flag, command)
    | (command, flags) <-
        [ (Help, ["--help", "-h", "help"]),
          (Version, ["--version", "-v", "version"])
        ],
      flag <- flags
  ]

showHelp :: String
showHelp =
  unlines
    [ "",
      "l1ne - the 67 language",
      "",
      "Usage:",
      "  l1ne <file>       Compile a l1ne source file",
      "  l1ne --help       Show this help",
      "  l1ne --version    Show version"
    ]

showVersion :: String
showVersion = "l1ne version 0.1.0"

dispatch :: Command -> IO ()
dispatch = \case
  Help -> putStrLn showHelp
  Version -> putStrLn showVersion
  Compile path -> compile path

-- | The pure frontend pipeline: everything between reading the file and
-- reporting is total and effect-free.
compileSource :: FilePath -> String -> Either String Module
compileSource path source = Tokenizer.tokenize path source >>= Parser.parseModule

compile :: FilePath -> IO ()
compile path = do
  source <- tryIOError (readFile path)
  either (die . show) (either die report . compileSource path) source
  where
    report ast = putStrLn ("Parsed: " ++ path) *> print ast
