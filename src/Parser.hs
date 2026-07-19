{-# LANGUAGE LambdaCase #-}

module Parser
  ( parseModule,
  )
where

import Control.Applicative (Alternative (..), optional)
import Data.Foldable (asum)
import Data.Functor (void)
import Syntax
import Tokenizer

newtype Parser a = Parser {runParser :: [Token] -> Either String (a, [Token])}

instance Functor Parser where
  fmap f parser = Parser $ \tokens -> do
    (value, rest) <- runParser parser tokens
    Right (f value, rest)

instance Applicative Parser where
  pure value = Parser $ \tokens -> Right (value, tokens)
  left <*> right = Parser $ \tokens -> do
    (f, rest) <- runParser left tokens
    (value, rest') <- runParser right rest
    Right (f value, rest')

instance Monad Parser where
  parser >>= next = Parser $ \tokens -> do
    (value, rest) <- runParser parser tokens
    runParser (next value) rest

instance Alternative Parser where
  empty = failP "no alternative matched"
  left <|> right = Parser $ \tokens ->
    either (const (runParser right tokens)) Right (runParser left tokens)

parseModule :: [Token] -> Either String Module
parseModule = fmap fst . runParser (skipSemis *> moduleP <* eofP)

moduleP :: Parser Module
moduleP = do
  keyword "module"
  name <- qualifiedNameP
  semi
  imports <- many importP
  decls <- many declP
  pure (Module name imports decls)

importP :: Parser Import
importP = do
  keyword "use"
  path <- qualifiedNameP
  items <- optional (symbol "." *> importItemsP)
  alias <- optional (keyword "as" *> identP)
  semi
  skipSemis
  pure (Import path alias items)
  where
    importItemsP = braces (sepByP importItemP (symbol ","))
    importItemP = ImportItem <$> identP <*> optional (keyword "as" *> identP)

declP :: Parser Decl
declP = do
  skipSemis
  attrs <- many attributeP
  visibility <- optionP Private (Public <$ keyword "pub")
  asum
    [ constDeclP visibility,
      fnDeclP attrs visibility,
      typeDeclP visibility,
      effectDeclP visibility,
      lawDeclP visibility
    ]
    <?> "declaration"

attributeP :: Parser Attribute
attributeP = symbol "@" *> (Attribute <$> identP)

constDeclP :: Visibility -> Parser Decl
constDeclP visibility = do
  keyword "const"
  name <- identP
  typ <- optional (symbol "::" *> typeExprP)
  symbol "="
  expr <- exprP
  semi
  skipSemis
  pure (ConstDecl visibility name typ expr)

fnDeclP :: [Attribute] -> Visibility -> Parser Decl
fnDeclP attrs visibility = do
  keyword "fn"
  name <- identP
  generics <- optionP [] genericNamesP
  params <- parens (sepByP paramP (symbol ","))
  result <- optional (symbol "->" *> typeExprP)
  effects <- usesP
  body <- blockStmtsP
  skipSemis
  pure (FnDecl attrs visibility name generics params result effects body)

typeDeclP :: Visibility -> Parser Decl
typeDeclP visibility = do
  keyword "type"
  name <- identP
  generics <- optionP [] genericNamesP
  symbol "="
  typ <- typeSumP <|> typeExprP
  semi
  skipSemis
  pure (TypeDecl visibility name generics typ)

effectDeclP :: Visibility -> Parser Decl
effectDeclP visibility = do
  keyword "effect"
  name <- identP
  members <- braces (skipSemis *> many effectMemberP)
  skipSemis
  pure (EffectDecl visibility name members)
  where
    effectMemberP = do
      keyword "fn"
      name <- identP
      params <- parens (sepByP paramP (symbol ","))
      result <- optional (symbol "->" *> typeExprP)
      effects <- usesP
      semi
      skipSemis
      pure (EffectFn name params result effects)

lawDeclP :: Visibility -> Parser Decl
lawDeclP visibility = do
  keyword "law"
  name <- identP
  generics <- optionP [] genericNamesP
  symbol ":"
  body <- exprP
  semi
  skipSemis
  pure (LawDecl visibility name generics body)

paramP :: Parser Param
paramP = Param <$> patternP <*> optional (symbol "::" *> typeExprP)

genericNamesP :: Parser [Name]
genericNamesP = brackets (sepBy1P identP (symbol ","))

usesP :: Parser [Name]
usesP = optionP [] $ keyword "uses" *> sepBy1P identP (keyword "and")

typeSumP :: Parser TypeExpr
typeSumP = TypeSum <$> some variantP
  where
    variantP = do
      skipSemis
      symbol "|"
      name <- identP
      fields <- optionP [] (parens (sepByP paramOrTypeP (symbol ",")))
      skipSemis
      pure (TypeVariant name fields)
    paramOrTypeP =
      ( do
          name <- identP
          symbol "::"
          Param (PBind name) . Just <$> typeExprP
      )
        <|> (Param PWildcard . Just <$> typeExprP)

typeExprP :: Parser TypeExpr
typeExprP = fnTypeP <|> typePostfixP

fnTypeP :: Parser TypeExpr
fnTypeP = do
  keyword "fn"
  args <- parens (sepByP typeExprP (symbol ","))
  symbol "->"
  result <- typeExprP
  effects <- usesP
  pure (TypeFn args result effects)

typePostfixP :: Parser TypeExpr
typePostfixP = do
  base <- typeAtomP
  args <- optional (brackets (sepBy1P typeExprP (symbol ",")))
  pure $ maybe base (TypeGeneric base) args

typeAtomP :: Parser TypeExpr
typeAtomP =
  asum
    [ TypeList <$> brackets typeExprP,
      TypeRecord <$> braces (skipSemis *> sepByP typeFieldP fieldSepP <* skipSemis),
      tupleOrGroupedTypeP,
      TypeName <$> qualifiedNameP
    ]
    <?> "type"
  where
    typeFieldP = do
      name <- identP
      symbol "::"
      typ <- typeExprP
      pure (name, typ)
    fieldSepP = symbol "," <|> semi

tupleOrGroupedTypeP :: Parser TypeExpr
tupleOrGroupedTypeP = do
  symbol "("
  asum
    [ TypeUnit <$ symbol ")",
      do
        first <- typeExprP
        rest <- many (symbol "," *> typeExprP)
        symbol ")"
        pure $ case rest of
          [] -> first
          _ -> TypeTuple (first : rest)
    ]

blockStmtsP :: Parser [Stmt]
blockStmtsP = braces (skipSemis *> many stmtP <* skipSemis)

blockExprP :: Parser Expr
blockExprP = Block <$> blockStmtsP

stmtP :: Parser Stmt
stmtP =
  asum
    [ letStmtP,
      ContractStmt . Require <$> (keyword "require" *> exprP <* semi <* skipSemis),
      ContractStmt . Ensure <$> (keyword "ensure" *> exprP <* semi <* skipSemis),
      ExprStmt <$> (exprP <* optional semi <* skipSemis)
    ]

letStmtP :: Parser Stmt
letStmtP = do
  keyword "let"
  pat <- patternP
  typ <- optional (symbol "::" *> typeExprP)
  symbol "="
  value <- exprP
  semi
  skipSemis
  pure (LetStmt pat typ value)

exprP :: Parser Expr
exprP = quantifierP <|> infixP 0

quantifierP :: Parser Expr
quantifierP = do
  q <- asum [textKeyword "forall", textKeyword "exists", textKeyword "exists!"]
  binder <- patternP
  domain <- (InDomain <$> (keyword "in" *> exprP)) <|> (TypeDomain <$> (symbol "::" *> typeExprP))
  symbol ":"
  Quantifier q binder domain <$> exprP

infixP :: Int -> Parser Expr
infixP minPrec = prefixP >>= climb
  where
    climb left = do
      next <- peekKind
      case next >>= infixInfo of
        Just (prec, assoc, op)
          | prec >= minPrec -> do
              _ <- anyToken
              right <- infixP (if assoc == RightAssoc then prec else prec + 1)
              rejectChain assoc prec op
              climb (node op left right)
        _ -> pure left
    node ".." left right = Range left False right
    node "..=" left right = Range left True right
    node op left right = Binary op left right

-- A non-associative operator must not be followed by another operator of
-- the same precedence: `a iff b iff c` and `0..3..9` are parse errors.
rejectChain :: Assoc -> Int -> String -> Parser ()
rejectChain NonAssoc prec op = do
  next <- peekKind
  case next >>= infixInfo of
    Just (prec', _, op')
      | prec' == prec -> failP (op' ++ " cannot follow " ++ op ++ " without parentheses")
    _ -> pure ()
rejectChain _ _ _ = pure ()

data Assoc = LeftAssoc | RightAssoc | NonAssoc
  deriving (Eq)

infixInfo :: TokenKind -> Maybe (Int, Assoc, String)
infixInfo (TSymbol "**") = Just (10, RightAssoc, "**")
infixInfo (TSymbol "*") = Just (9, LeftAssoc, "*")
infixInfo (TSymbol "/") = Just (9, LeftAssoc, "/")
infixInfo (TSymbol "%") = Just (9, LeftAssoc, "%")
infixInfo (TSymbol "+") = Just (8, LeftAssoc, "+")
infixInfo (TSymbol "-") = Just (8, LeftAssoc, "-")
infixInfo (TSymbol "..") = Just (7, NonAssoc, "..")
infixInfo (TSymbol "..=") = Just (7, NonAssoc, "..=")
infixInfo (TSymbol "<") = Just (6, LeftAssoc, "<")
infixInfo (TSymbol "<=") = Just (6, LeftAssoc, "<=")
infixInfo (TSymbol ">") = Just (6, LeftAssoc, ">")
infixInfo (TSymbol ">=") = Just (6, LeftAssoc, ">=")
infixInfo (TSymbol "==") = Just (5, LeftAssoc, "==")
infixInfo (TSymbol "!=") = Just (5, LeftAssoc, "!=")
infixInfo (TKeyword "and") = Just (4, LeftAssoc, "and")
infixInfo (TKeyword "or") = Just (3, LeftAssoc, "or")
infixInfo (TKeyword "implies") = Just (2, RightAssoc, "implies")
infixInfo (TKeyword "iff") = Just (1, NonAssoc, "iff")
infixInfo _ = Nothing

prefixP :: Parser Expr
prefixP =
  asum
    [ Unary <$> textKeyword "not" <*> prefixP,
      Unary <$> symbolText "-" <*> prefixP,
      Unary <$> symbolText "+" <*> prefixP,
      postfixP
    ]

postfixP :: Parser Expr
postfixP = atomP >>= go
  where
    go expr =
      asum
        [ parens (sepByP argP (symbol ",")) >>= go . Call expr,
          symbol "." *> identP >>= go . Field expr,
          brackets exprP >>= go . Index expr,
          pure expr
        ]

argP :: Parser Arg
argP =
  (NamedArg <$> identP <* symbol ":" <*> exprP)
    <|> (PosArg <$> exprP)

atomP :: Parser Expr
atomP =
  asum
    [ ifP,
      matchP,
      lambdaP,
      blockExprP,
      listOrCompP,
      tupleOrGroupedExprP,
      literalP,
      nameExprP
    ]
    <?> "expression"

ifP :: Parser Expr
ifP = do
  keyword "if"
  cond <- exprP
  thenBranch <- blockExprP
  elseBranch <- optional (keyword "else" *> (ifP <|> blockExprP))
  pure (If cond thenBranch elseBranch)

matchP :: Parser Expr
matchP = do
  keyword "match"
  subject <- exprP
  arms <- braces (skipSemis *> many matchArmP <* skipSemis)
  pure (Match subject arms)
  where
    matchArmP = do
      pat <- patternP
      guard <- optional (keyword "if" *> exprP)
      symbol "=>"
      body <- exprP
      _ <- optional semi
      skipSemis
      pure (MatchArm pat guard body)

lambdaP :: Parser Expr
lambdaP = do
  keyword "fn"
  params <- parens (sepByP paramP (symbol ","))
  symbol "=>"
  Lambda params <$> exprP

listOrCompP :: Parser Expr
listOrCompP = do
  symbol "["
  asum
    [ List [] <$ symbol "]",
      do
        first <- exprP
        asum
          [ do
              symbol ":"
              clauses <- sepBy1P compClauseP (symbol ",")
              symbol "]"
              pure (Comprehension first clauses),
            do
              rest <- many (symbol "," *> exprP)
              _ <- optional (symbol ",")
              symbol "]"
              pure (List (first : rest))
          ]
    ]
  where
    compClauseP =
      (CompBind <$> patternP <* keyword "in" <*> exprP)
        <|> (CompFilter <$> exprP)

tupleOrGroupedExprP :: Parser Expr
tupleOrGroupedExprP = do
  symbol "("
  asum
    [ Unit <$ symbol ")",
      do
        first <- exprP
        rest <- many (symbol "," *> exprP)
        _ <- optional (symbol ",")
        symbol ")"
        pure $ case rest of
          [] -> first
          _ -> Tuple (first : rest)
    ]

literalP :: Parser Expr
literalP = Lit <$> literalValueP

literalValueP :: Parser Literal
literalValueP = satisfy "literal" $ \case
  TInt value -> Just (LInt value)
  TFloat value -> Just (LFloat value)
  TString value -> Just (LString value)
  TRawString value -> Just (LRawString value)
  TChar value -> Just (LChar value)
  TKeyword "true" -> Just (LBool True)
  TKeyword "false" -> Just (LBool False)
  _ -> Nothing

nameExprP :: Parser Expr
nameExprP =
  qualifiedNameP >>= \case
    [name] -> pure (Var name)
    names -> pure (Qualified names)

patternP :: Parser Pattern
patternP =
  asum
    [ PWildcard <$ identText "_",
      PLit <$> literalValueP,
      patternListP,
      patternTupleP,
      patternRecordP,
      patternNameP
    ]
    <?> "pattern"

patternNameP :: Parser Pattern
patternNameP = do
  names <- qualifiedNameP
  args <- optional (parens (sepByP argPatternP (symbol ",")))
  pure $ case args of
    Nothing
      | [name] <- names -> PBind name
      | otherwise -> PVariant names []
    Just values -> PVariant names values

argPatternP :: Parser ArgPattern
argPatternP =
  (NamedPat <$> identP <* symbol ":" <*> patternP)
    <|> (PosPat <$> patternP)

patternListP :: Parser Pattern
patternListP =
  brackets $
    asum
      [ pure (PList [] Nothing) <* lookaheadSymbol "]",
        do
          first <- patternP
          rest <- many (symbol "," *> patternP)
          tailName <- optional (symbol "," *> symbol ".." *> identP)
          _ <- optional (symbol ",")
          pure (PList (first : rest) tailName)
      ]

patternTupleP :: Parser Pattern
patternTupleP = do
  symbol "("
  asum
    [ PUnit <$ symbol ")",
      do
        first <- patternP
        rest <- many (symbol "," *> patternP)
        _ <- optional (symbol ",")
        symbol ")"
        pure $ case rest of
          [] -> first
          _ -> PTuple (first : rest)
    ]

patternRecordP :: Parser Pattern
patternRecordP =
  PRecord <$> braces (skipSemis *> sepByP fieldP fieldSepP <* skipSemis)
  where
    fieldP = do
      name <- identP
      value <- optionP (PBind name) (symbol ":" *> patternP)
      pure (name, value)
    fieldSepP = symbol "," <|> semi

qualifiedNameP :: Parser [Name]
qualifiedNameP = (:) <$> identP <*> many (symbol "." *> identP)

-- Token primitives -----------------------------------------------------------

-- | The single primitive every leaf parser is built from: consume one token
-- when the extractor accepts its kind, otherwise fail with a positioned
-- message naming what was expected.
satisfy :: String -> (TokenKind -> Maybe a) -> Parser a
satisfy expected extract = Parser $ \case
  tok : rest | Just value <- extract (tokenKind tok) -> Right (value, rest)
  tok : _ -> Left $ here tok ++ "expected " ++ expected
  [] -> Left $ "unexpected end of input, expected " ++ expected

identP :: Parser Name
identP = satisfy "identifier" $ \case
  TIdent value -> Just value
  _ -> Nothing

identText :: String -> Parser String
identText expected = satisfy expected $ \case
  TIdent value | value == expected -> Just value
  _ -> Nothing

keyword :: String -> Parser ()
keyword expected = satisfy expected $ \case
  TKeyword value | value == expected -> Just ()
  _ -> Nothing

textKeyword :: String -> Parser String
textKeyword text = text <$ keyword text

symbol :: String -> Parser ()
symbol expected = satisfy expected $ \case
  TSymbol value | value == expected -> Just ()
  _ -> Nothing

symbolText :: String -> Parser String
symbolText text = text <$ symbol text

semi :: Parser ()
semi = satisfy "semicolon" $ \case
  TSemi -> Just ()
  _ -> Nothing

skipSemis :: Parser ()
skipSemis = void (many semi)

eofP :: Parser ()
eofP = Parser $ \case
  Token TEOF _ : rest -> Right ((), rest)
  tok : _ -> Left $ here tok ++ "expected end of input"
  [] -> Right ((), [])

peekKind :: Parser (Maybe TokenKind)
peekKind = Parser $ \case
  tokens@(Token TEOF _ : _) -> Right (Nothing, tokens)
  tokens@(tok : _) -> Right (Just (tokenKind tok), tokens)
  [] -> Right (Nothing, [])

anyToken :: Parser Token
anyToken = Parser $ \case
  tok : rest -> Right (tok, rest)
  [] -> Left "unexpected end of input"

lookaheadSymbol :: String -> Parser ()
lookaheadSymbol expected = Parser $ \case
  tokens@(Token (TSymbol value) _ : _)
    | value == expected -> Right ((), tokens)
  tok : _ -> Left $ here tok ++ "expected " ++ expected
  [] -> Left $ "unexpected end of input, expected " ++ expected

failP :: String -> Parser a
failP message = Parser $ \case
  tok : _ -> Left $ here tok ++ message
  [] -> Left message

-- Combinators ----------------------------------------------------------------

parens :: Parser a -> Parser a
parens body = symbol "(" *> body <* symbol ")"

brackets :: Parser a -> Parser a
brackets body = symbol "[" *> body <* symbol "]"

braces :: Parser a -> Parser a
braces body = symbol "{" *> body <* symbol "}"

optionP :: a -> Parser a -> Parser a
optionP fallback parser = parser <|> pure fallback

sepByP :: Parser a -> Parser sep -> Parser [a]
sepByP parser separator = sepBy1P parser separator <|> pure []

sepBy1P :: Parser a -> Parser sep -> Parser [a]
sepBy1P parser separator = (:) <$> parser <*> many (separator *> parser)

(<?>) :: Parser a -> String -> Parser a
parser <?> expected = Parser $ \tokens ->
  case runParser parser tokens of
    Right value -> Right value
    Left err ->
      case tokens of
        tok : _ -> Left $ here tok ++ "expected " ++ expected ++ " (" ++ err ++ ")"
        [] -> Left $ "unexpected end of input, expected " ++ expected

here :: Token -> String
here token = show (tokenPos token) ++ ": "
