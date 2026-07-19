{-# LANGUAGE LambdaCase #-}

module Parser
  ( parseModule,
  )
where

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

parseModule :: [Token] -> Either String Module
parseModule tokens = do
  (modl, _) <- runParser (skipSemis *> moduleP <* eofP) tokens
  Right modl

moduleP :: Parser Module
moduleP = do
  keyword "module"
  name <- qualifiedNameP
  semi
  imports <- manyP importP
  decls <- manyP declP
  pure (Module name imports decls)

importP :: Parser Import
importP = do
  keyword "use"
  path <- qualifiedNameP
  items <- optionalP (symbol "." *> importItemsP)
  alias <- optionalP (keyword "as" *> identP)
  semi
  skipSemis
  pure (Import path alias items)
  where
    importItemsP = do
      symbol "{"
      values <- sepByP importItemP (symbol ",")
      symbol "}"
      pure values
    importItemP = do
      name <- identP
      alias <- optionalP (keyword "as" *> identP)
      pure (ImportItem name alias)

declP :: Parser Decl
declP = do
  skipSemis
  attrs <- manyP attributeP
  visibility <- optionP Private (Public <$ keyword "pub")
  choiceP
    [ constDeclP visibility,
      fnDeclP attrs visibility,
      typeDeclP visibility,
      effectDeclP visibility,
      lawDeclP visibility
    ]
    <?> "declaration"

attributeP :: Parser Attribute
attributeP = do
  symbol "@"
  Attribute <$> identP

constDeclP :: Visibility -> Parser Decl
constDeclP visibility = do
  keyword "const"
  name <- identP
  typ <- optionalP (symbol "::" *> typeExprP)
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
  result <- optionalP (symbol "->" *> typeExprP)
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
  members <- braces (skipSemis *> manyP effectMemberP)
  skipSemis
  pure (EffectDecl visibility name members)
  where
    effectMemberP = do
      keyword "fn"
      name <- identP
      params <- parens (sepByP paramP (symbol ","))
      result <- optionalP (symbol "->" *> typeExprP)
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
paramP = do
  pat <- patternP
  typ <- optionalP (symbol "::" *> typeExprP)
  pure (Param pat typ)

genericNamesP :: Parser [Name]
genericNamesP = brackets (sepBy1P identP (symbol ","))

usesP :: Parser [Name]
usesP = optionP [] $ keyword "uses" *> sepBy1P identP (keyword "and")

typeSumP :: Parser TypeExpr
typeSumP = do
  variants <- someP variantP
  pure (TypeSum variants)
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
  args <- optionalP (brackets (sepBy1P typeExprP (symbol ",")))
  pure $ maybe base (TypeGeneric base) args

typeAtomP :: Parser TypeExpr
typeAtomP =
  choiceP
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
  choiceP
    [ TypeUnit <$ symbol ")",
      do
        first <- typeExprP
        rest <- manyP (symbol "," *> typeExprP)
        symbol ")"
        pure $ case rest of
          [] -> first
          _ -> TypeTuple (first : rest)
    ]

blockStmtsP :: Parser [Stmt]
blockStmtsP = braces $ do
  skipSemis
  statements <- manyP stmtP
  skipSemis
  pure statements

stmtP :: Parser Stmt
stmtP =
  choiceP
    [ letStmtP,
      ContractStmt . Require <$> (keyword "require" *> exprP <* semi <* skipSemis),
      ContractStmt . Ensure <$> (keyword "ensure" *> exprP <* semi <* skipSemis),
      do
        expr <- exprP
        _ <- optionalP semi
        skipSemis
        pure (ExprStmt expr)
    ]

letStmtP :: Parser Stmt
letStmtP = do
  keyword "let"
  pat <- patternP
  typ <- optionalP (symbol "::" *> typeExprP)
  symbol "="
  value <- exprP
  semi
  skipSemis
  pure (LetStmt pat typ value)

exprP :: Parser Expr
exprP = quantifierP <|> infixP 0

quantifierP :: Parser Expr
quantifierP = do
  q <- choiceP [textKeyword "forall", textKeyword "exists", textKeyword "exists!"]
  binder <- patternP
  domain <- (InDomain <$> (keyword "in" *> exprP)) <|> (TypeDomain <$> (symbol "::" *> typeExprP))
  symbol ":"
  Quantifier q binder domain <$> exprP

infixP :: Int -> Parser Expr
infixP minPrec = do
  left <- prefixP
  climb minPrec left
  where
    climb minP left = do
      next <- peekKind
      case next >>= infixInfo of
        Just (prec, assoc, op)
          | prec >= minP -> do
              _ <- anyToken
              right <- infixP (if assoc == RightAssoc then prec else prec + 1)
              let node = if op == ".." then Range left False right else if op == "..=" then Range left True right else Binary op left right
              climb minP node
        _ -> pure left

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
  choiceP
    [ Unary <$> textKeyword "not" <*> prefixP,
      Unary <$> symbolText "-" <*> prefixP,
      Unary <$> symbolText "+" <*> prefixP,
      postfixP
    ]

postfixP :: Parser Expr
postfixP = atomP >>= go
  where
    go expr =
      choiceP
        [ do
            args <- parens (sepByP argP (symbol ","))
            go (Call expr args),
          do
            symbol "."
            name <- identP
            go (Field expr name),
          do
            index <- brackets exprP
            go (Index expr index),
          pure expr
        ]

argP :: Parser Arg
argP =
  ( do
      name <- identP
      symbol ":"
      NamedArg name <$> exprP
  )
    <|> (PosArg <$> exprP)

atomP :: Parser Expr
atomP =
  choiceP
    [ ifP,
      matchP,
      lambdaP,
      Block <$> blockStmtsP,
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
  thenBranch <- Block <$> blockStmtsP
  elseBranch <- optionalP (keyword "else" *> ((If <$> (keyword "if" *> exprP) <*> (Block <$> blockStmtsP) <*> optionalP (keyword "else" *> atomP)) <|> (Block <$> blockStmtsP)))
  pure (If cond thenBranch elseBranch)

matchP :: Parser Expr
matchP = do
  keyword "match"
  subject <- exprP
  arms <- braces (skipSemis *> manyP matchArmP <* skipSemis)
  pure (Match subject arms)
  where
    matchArmP = do
      pat <- patternP
      guard <- optionalP (keyword "if" *> exprP)
      symbol "=>"
      body <- exprP
      _ <- optionalP semi
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
  choiceP
    [ List [] <$ symbol "]",
      do
        first <- exprP
        choiceP
          [ do
              symbol ":"
              clauses <- sepBy1P compClauseP (symbol ",")
              symbol "]"
              pure (Comprehension first clauses),
            do
              rest <- manyP (symbol "," *> exprP)
              _ <- optionalP (symbol ",")
              symbol "]"
              pure (List (first : rest))
          ]
    ]
  where
    compClauseP =
      ( do
          pat <- patternP
          keyword "in"
          CompBind pat <$> exprP
      )
        <|> (CompFilter <$> exprP)

tupleOrGroupedExprP :: Parser Expr
tupleOrGroupedExprP = do
  symbol "("
  choiceP
    [ Unit <$ symbol ")",
      do
        first <- exprP
        rest <- manyP (symbol "," *> exprP)
        _ <- optionalP (symbol ",")
        symbol ")"
        pure $ case rest of
          [] -> first
          _ -> Tuple (first : rest)
    ]

literalP :: Parser Expr
literalP = Lit <$> literalValueP

literalValueP :: Parser Literal
literalValueP =
  Parser $ \case
    Token (TInt value) _ : rest -> Right (LInt value, rest)
    Token (TFloat value) _ : rest -> Right (LFloat value, rest)
    Token (TString value) _ : rest -> Right (LString value, rest)
    Token (TRawString value) _ : rest -> Right (LRawString value, rest)
    Token (TChar value) _ : rest -> Right (LChar value, rest)
    Token (TKeyword "true") _ : rest -> Right (LBool True, rest)
    Token (TKeyword "false") _ : rest -> Right (LBool False, rest)
    tok : _ -> Left $ here tok ++ "expected literal"
    [] -> Left "unexpected end of input, expected literal"

nameExprP :: Parser Expr
nameExprP = do
  names <- qualifiedNameP
  pure $ case names of
    [name] -> Var name
    _ -> Qualified names

patternP :: Parser Pattern
patternP =
  choiceP
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
  args <- optionalP (parens (sepByP argPatternP (symbol ",")))
  pure $ case args of
    Nothing
      | [name] <- names -> PBind name
      | otherwise -> PVariant names []
    Just values -> PVariant names values

argPatternP :: Parser ArgPattern
argPatternP =
  ( do
      name <- identP
      symbol ":"
      NamedPat name <$> patternP
  )
    <|> (PosPat <$> patternP)

patternListP :: Parser Pattern
patternListP = brackets $ do
  choiceP
    [ pure (PList [] Nothing) <* lookaheadSymbol "]",
      do
        first <- patternP
        rest <- manyP (symbol "," *> patternP)
        tailName <- optionalP (symbol "," *> symbol ".." *> identP)
        _ <- optionalP (symbol ",")
        pure (PList (first : rest) tailName)
    ]

patternTupleP :: Parser Pattern
patternTupleP = do
  symbol "("
  choiceP
    [ PUnit <$ symbol ")",
      do
        first <- patternP
        rest <- manyP (symbol "," *> patternP)
        _ <- optionalP (symbol ",")
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
qualifiedNameP = do
  first <- identP
  rest <- manyP (symbol "." *> identP)
  pure (first : rest)

identP :: Parser Name
identP =
  Parser $ \case
    Token (TIdent value) _ : rest -> Right (value, rest)
    tok : _ -> Left $ here tok ++ "expected identifier"
    [] -> Left "unexpected end of input, expected identifier"

identText :: String -> Parser String
identText expected =
  Parser $ \case
    Token (TIdent value) _ : rest
      | value == expected -> Right (value, rest)
    tok : _ -> Left $ here tok ++ "expected " ++ expected
    [] -> Left $ "unexpected end of input, expected " ++ expected

keyword :: String -> Parser ()
keyword expected =
  Parser $ \case
    Token (TKeyword value) _ : rest
      | value == expected -> Right ((), rest)
    tok : _ -> Left $ here tok ++ "expected " ++ expected
    [] -> Left $ "unexpected end of input, expected " ++ expected

textKeyword :: String -> Parser String
textKeyword text = text <$ keyword text

symbol :: String -> Parser ()
symbol expected =
  Parser $ \case
    Token (TSymbol value) _ : rest
      | value == expected -> Right ((), rest)
    tok : _ -> Left $ here tok ++ "expected " ++ expected
    [] -> Left $ "unexpected end of input, expected " ++ expected

symbolText :: String -> Parser String
symbolText text = text <$ symbol text

semi :: Parser ()
semi =
  Parser $ \case
    Token TSemi _ : rest -> Right ((), rest)
    Token (TSymbol ";") _ : rest -> Right ((), rest)
    tok : _ -> Left $ here tok ++ "expected semicolon"
    [] -> Left "unexpected end of input, expected semicolon"

skipSemis :: Parser ()
skipSemis = manyP semi *> pure ()

eofP :: Parser ()
eofP =
  Parser $ \case
    [Token TEOF _] -> Right ((), [])
    Token TEOF _ : rest -> Right ((), rest)
    tok : _ -> Left $ here tok ++ "expected end of input"
    [] -> Right ((), [])

peekKind :: Parser (Maybe TokenKind)
peekKind =
  Parser $ \case
    tokens@(Token TEOF _ : _) -> Right (Nothing, tokens)
    tokens@(tok : _) -> Right (Just (tokenKind tok), tokens)
    [] -> Right (Nothing, [])

anyToken :: Parser Token
anyToken =
  Parser $ \case
    tok : rest -> Right (tok, rest)
    [] -> Left "unexpected end of input"

lookaheadSymbol :: String -> Parser ()
lookaheadSymbol expected =
  Parser $ \case
    tokens@(Token (TSymbol value) _ : _)
      | value == expected -> Right ((), tokens)
    tok : _ -> Left $ here tok ++ "expected " ++ expected
    [] -> Left $ "unexpected end of input, expected " ++ expected

parens :: Parser a -> Parser a
parens body = symbol "(" *> body <* symbol ")"

brackets :: Parser a -> Parser a
brackets body = symbol "[" *> body <* symbol "]"

braces :: Parser a -> Parser a
braces body = symbol "{" *> body <* symbol "}"

manyP :: Parser a -> Parser [a]
manyP parser = someP parser <|> pure []

someP :: Parser a -> Parser [a]
someP parser = do
  first <- parser
  rest <- manyP parser
  pure (first : rest)

optionalP :: Parser a -> Parser (Maybe a)
optionalP parser = (Just <$> parser) <|> pure Nothing

optionP :: a -> Parser a -> Parser a
optionP fallback parser = parser <|> pure fallback

sepByP :: Parser a -> Parser sep -> Parser [a]
sepByP parser separator = sepBy1P parser separator <|> pure []

sepBy1P :: Parser a -> Parser sep -> Parser [a]
sepBy1P parser separator = do
  first <- parser
  rest <- manyP (separator *> parser)
  pure (first : rest)

choiceP :: [Parser a] -> Parser a
choiceP [] = Parser $ \case
  tok : _ -> Left $ here tok ++ "no parser alternative matched"
  [] -> Left "unexpected end of input"
choiceP (parser : parsers) = parser <|> choiceP parsers

(<|>) :: Parser a -> Parser a -> Parser a
left <|> right = Parser $ \tokens ->
  case runParser left tokens of
    Right value -> Right value
    Left _ -> runParser right tokens

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
