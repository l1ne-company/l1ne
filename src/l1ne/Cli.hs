{-# LANGUAGE LambdaCase #-}

module Cli
  ( Command (..),
    parseArgs,
    dispatch,
  )
where

import Parser qualified
import Tokenizer qualified

data Command
  = Compile FilePath -- Compile a source file
  | Help -- Show help
  | Version -- Show version
  deriving (Show, Eq)

parseArgs :: [String] -> Either String Command
parseArgs [] = Right Help
parseArgs ["--help"] = Right Help
parseArgs ["-h"] = Right Help
parseArgs ["help"] = Right Help
parseArgs ["--version"] = Right Version
parseArgs ["-v"] = Right Version
parseArgs ["version"] = Right Version
parseArgs [filepath] = Right (Compile filepath)
parseArgs args = Left $ "Expected a single source file, got: " ++ unwords args

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

compile :: FilePath -> IO ()
compile path = do
  source <- readFile path
  case Tokenizer.tokenize path source >>= Parser.parseModule of
    Left err -> fail err
    Right ast -> do
      putStrLn $ "Parsed: " ++ path
      print ast
