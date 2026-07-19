module Tokenizer
  ( Token (..),
    TokenKind (..),
    Position (..),
    tokenize,
  )
where

import Data.Char (isAlpha, isAlphaNum, isDigit, isHexDigit, isOctDigit)
import Data.List (find, isInfixOf, isPrefixOf, sortOn, stripPrefix)
import Data.Maybe (listToMaybe)
import Data.Ord (Down (..))

data Position = Position
  { posLine :: Int,
    posColumn :: Int
  }
  deriving (Eq)

instance Show Position where
  show (Position line column) = show line ++ ":" ++ show column

data Token = Token
  { tokenKind :: TokenKind,
    tokenPos :: Position
  }
  deriving (Eq, Show)

data TokenKind
  = TIdent String
  | TKeyword String
  | TInt String
  | TFloat String
  | TString String
  | TRawString String
  | TChar Char
  | TSymbol String
  | TSemi
  | TEOF
  deriving (Eq, Show)

data LexState = LexState
  { lsLine :: Int,
    lsColumn :: Int,
    lsParenDepth :: Int,
    lsBracketDepth :: Int,
    lsLastCanEnd :: Bool,
    lsTokensRev :: [Token]
  }

tokenize :: FilePath -> String -> Either String [Token]
tokenize path source = finish <$> go (LexState 1 1 0 0 False []) source
  where
    finish state =
      let withEof = insertSemiAtEof state
       in reverse (Token TEOF (position withEof) : lsTokensRev withEof)

    failAt st message = Left $ path ++ ":" ++ show (position st) ++ ": " ++ message

    go st [] = Right st
    go st input@(c : cs)
      | c == '\n' = go (newline st cs) cs
      | c == ' ' || c == '\t' || c == '\r' = go (advance st c) cs
      | Just rest <- stripPrefix "//" input = uncurry go (skipLineComment (advanceN st "//") rest)
      | Just rest <- stripPrefix "/*" input = skipBlockComment (advanceN st "/*") 1 rest >>= uncurry go
      | isIdentStart c = uncurry go (scanIdent st input)
      | isDigit c = scanNumber path st input >>= uncurry go
      | c == '"' = scanString path st cs >>= uncurry go
      | c == '\'' = scanChar path st cs >>= uncurry go
      | c == '`' = scanRawString path st cs >>= uncurry go
      | otherwise = scanSymbol path st input >>= uncurry go

    skipLineComment st [] = (st, [])
    skipLineComment st rest@('\n' : _) = (st, rest)
    skipLineComment st (x : xs) = skipLineComment (advance st x) xs

    skipBlockComment :: LexState -> Int -> String -> Either String (LexState, String)
    skipBlockComment st 0 rest = Right (st, rest)
    skipBlockComment st _ [] = failAt st "unterminated block comment"
    skipBlockComment st depth input
      | Just rest <- stripPrefix "/*" input = skipBlockComment (advanceN st "/*") (depth + 1) rest
      | Just rest <- stripPrefix "*/" input = skipBlockComment (advanceN st "*/") (depth - 1) rest
    skipBlockComment st depth (x : xs) =
      skipBlockComment (advance st x) depth xs

isIdentStart :: Char -> Bool
isIdentStart c = isAlpha c || c == '_'

isIdentPart :: Char -> Bool
isIdentPart c = isAlphaNum c || c == '_'

keywords :: [String]
keywords =
  [ "module",
    "use",
    "as",
    "pub",
    "fn",
    "type",
    "effect",
    "const",
    "let",
    "if",
    "else",
    "match",
    "uses",
    "not",
    "and",
    "or",
    "implies",
    "iff",
    "forall",
    "exists",
    "in",
    "law",
    "require",
    "ensure",
    "true",
    "false"
  ]

scanIdent :: LexState -> String -> (LexState, String)
scanIdent st input =
  let (name, afterName) = span isIdentPart input
      (kind, consumed, rest)
        | name == "exists", Just bang <- stripPrefix "!" afterName = (TKeyword "exists!", name ++ "!", bang)
        | name `elem` keywords = (TKeyword name, name, afterName)
        | otherwise = (TIdent name, name, afterName)
   in (emit (advanceN st consumed) kind, rest)

scanNumber :: FilePath -> LexState -> String -> Either String (LexState, String)
scanNumber path st input =
  case input of
    '0' : base : rest
      | base `elem` ("xX" :: String) -> based isHexDigit rest
      | base `elem` ("bB" :: String) -> based (`elem` ("01" :: String)) rest
      | base `elem` ("oO" :: String) -> based isOctDigit rest
    _ -> decimal
  where
    failAt message = Left $ path ++ ":" ++ show (position st) ++ ": " ++ message
    based ok rest =
      let (digits, suffix) = span (\c -> ok c || c == '_') rest
       in if validSeparated ok digits
            then Right (finish TInt (2 + length digits) suffix)
            else failAt "invalid numeric literal"
    decimal =
      let (whole, rest1) = span digitish input
          hasFrac =
            "." `isPrefixOf` rest1
              && not (".." `isPrefixOf` rest1)
              && maybe False isDigit (listToMaybe (drop 1 rest1))
          (frac, rest2) = if hasFrac then span digitish (drop 1 rest1) else ("", rest1)
       in if validSeparated isDigit whole && (not hasFrac || validSeparated isDigit frac)
            then
              let width = length whole + if hasFrac then 1 + length frac else 0
                  kind = if hasFrac then TFloat else TInt
               in Right (finish kind width rest2)
            else failAt "invalid numeric literal"
    digitish c = isDigit c || c == '_'
    finish kind width rest =
      let text = take width input
       in (emit (advanceN st text) (kind text), rest)

validSeparated :: (Char -> Bool) -> String -> Bool
validSeparated ok text =
  case (text, reverse text) of
    (first : _, final : _) ->
      ok first
        && ok final
        && all (\c -> ok c || c == '_') text
        && not ("__" `isInfixOf` text)
    _ -> False

scanString :: FilePath -> LexState -> String -> Either String (LexState, String)
scanString path st = loop (advance st '"') []
  where
    failAt cur message = Left $ path ++ ":" ++ show (position cur) ++ ": " ++ message
    loop cur _ [] = failAt cur "unterminated string literal"
    loop cur acc ('"' : rest) = Right (emit (advance cur '"') (TString (reverse acc)), rest)
    loop cur acc ('\\' : c : rest) =
      case escape c of
        Just value -> loop (advanceN cur ['\\', c]) (value : acc) rest
        Nothing -> failAt cur ("unknown escape \\" ++ [c])
    loop cur _ ('\n' : _) = failAt cur "newline in string literal"
    loop cur acc (c : rest) = loop (advance cur c) (c : acc) rest

scanChar :: FilePath -> LexState -> String -> Either String (LexState, String)
scanChar path st input =
  case input of
    '\\' : c : '\'' : rest ->
      maybe (failAt ("unknown escape \\" ++ [c])) (\v -> Right (emit (advanceN st ['\'', '\\', c, '\'']) (TChar v), rest)) (escape c)
    c : '\'' : rest
      | c /= '\n' -> Right (emit (advanceN st ['\'', c, '\'']) (TChar c), rest)
    _ -> failAt "invalid character literal"
  where
    failAt message = Left $ path ++ ":" ++ show (position st) ++ ": " ++ message

scanRawString :: FilePath -> LexState -> String -> Either String (LexState, String)
scanRawString path st = loop (advance st '`') []
  where
    failAt cur = Left $ path ++ ":" ++ show (position cur) ++ ": unterminated raw string literal"
    loop cur _ [] = failAt cur
    loop cur acc ('`' : rest) = Right (emit (advance cur '`') (TRawString (reverse acc)), rest)
    loop cur acc (c : rest) = loop (advance cur c) (c : acc) rest

escape :: Char -> Maybe Char
escape c =
  lookup
    c
    [ ('n', '\n'),
      ('r', '\r'),
      ('t', '\t'),
      ('\\', '\\'),
      ('"', '"'),
      ('\'', '\''),
      ('0', '\0')
    ]

scanSymbol :: FilePath -> LexState -> String -> Either String (LexState, String)
scanSymbol path st input =
  case find (`isPrefixOf` input) symbols of
    Just sym -> Right (emitSymbol (advanceN st sym) sym, drop (length sym) input)
    Nothing -> Left $ path ++ ":" ++ show (position st) ++ ": unknown punctuation " ++ take 1 input

-- Ordered longest-first so that prefix search implements maximal munch.
symbols :: [String]
symbols =
  sortOn
    (Down . length)
    [ "..=",
      "::",
      "=>",
      "->",
      "**",
      "==",
      "!=",
      "<=",
      ">=",
      "..",
      "{",
      "}",
      "(",
      ")",
      "[",
      "]",
      ".",
      ",",
      ":",
      ";",
      "=",
      "|",
      "+",
      "-",
      "*",
      "/",
      "%",
      "<",
      ">",
      "@"
    ]

emitSymbol :: LexState -> String -> LexState
emitSymbol st ";" = emitRaw st TSemi False
emitSymbol st symbol =
  emitRaw
    ( case symbol of
        "(" -> st {lsParenDepth = lsParenDepth st + 1}
        ")" -> st {lsParenDepth = max 0 (lsParenDepth st - 1)}
        "[" -> st {lsBracketDepth = lsBracketDepth st + 1}
        "]" -> st {lsBracketDepth = max 0 (lsBracketDepth st - 1)}
        _ -> st
    )
    (TSymbol symbol)
    (symbol `elem` endSymbols)

emit :: LexState -> TokenKind -> LexState
emit st kind = emitRaw st kind (canEnd kind)

emitRaw :: LexState -> TokenKind -> Bool -> LexState
emitRaw st kind ends =
  st
    { lsTokensRev = Token kind (position st) : lsTokensRev st,
      lsLastCanEnd = ends
    }

canEnd :: TokenKind -> Bool
canEnd (TIdent _) = True
canEnd (TInt _) = True
canEnd (TFloat _) = True
canEnd (TString _) = True
canEnd (TRawString _) = True
canEnd (TChar _) = True
canEnd (TKeyword "true") = True
canEnd (TKeyword "false") = True
canEnd (TSymbol s) = s `elem` endSymbols
canEnd _ = False

endSymbols :: [String]
endSymbols = [")", "]", "}"]

newline :: LexState -> String -> LexState
newline st rest =
  let advanced = st {lsLine = lsLine st + 1, lsColumn = 1}
   in if shouldInsertSemi st rest
        then emitRaw advanced TSemi False
        else advanced

shouldInsertSemi :: LexState -> String -> Bool
shouldInsertSemi st rest =
  lsParenDepth st == 0
    && lsBracketDepth st == 0
    && lsLastCanEnd st
    && nextDoesNotContinue rest

nextDoesNotContinue :: String -> Bool
nextDoesNotContinue input =
  case dropWhile (`elem` (" \t\r\n" :: String)) input of
    "" -> True
    rest@(c : _)
      | c `elem` ("}),].|" :: String) -> False
      | Just after <- stripPrefix "else" rest -> maybe True (not . isIdentPart) (listToMaybe after)
      | otherwise -> True

insertSemiAtEof :: LexState -> LexState
insertSemiAtEof st
  | lsLastCanEnd st = emitRaw st TSemi False
  | otherwise = st

position :: LexState -> Position
position st = Position (lsLine st) (lsColumn st)

advance :: LexState -> Char -> LexState
advance st '\n' = st {lsLine = lsLine st + 1, lsColumn = 1}
advance st _ = st {lsColumn = lsColumn st + 1}

advanceN :: LexState -> String -> LexState
advanceN = foldl advance
