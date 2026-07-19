module Syntax
  ( Module (..),
    Import (..),
    ImportItem (..),
    Decl (..),
    Attribute (..),
    Visibility (..),
    Param (..),
    EffectMember (..),
    TypeVariant (..),
    Contract (..),
    Stmt (..),
    TypeExpr (..),
    Expr (..),
    QuantifierDomain (..),
    Arg (..),
    ArgPattern (..),
    CompClause (..),
    MatchArm (..),
    Pattern (..),
    FieldPattern (..),
    Literal (..),
    Name,
  )
where

type Name = String

data Module = Module
  { moduleName :: [Name],
    moduleImports :: [Import],
    moduleDecls :: [Decl]
  }
  deriving (Eq, Show)

data Import = Import
  { importPath :: [Name],
    importAlias :: Maybe Name,
    importItems :: Maybe [ImportItem]
  }
  deriving (Eq, Show)

data ImportItem = ImportItem Name (Maybe Name)
  deriving (Eq, Show)

data Visibility = Public | Private
  deriving (Eq, Show)

data Attribute = Attribute Name
  deriving (Eq, Show)

data Decl
  = ConstDecl Visibility Name (Maybe TypeExpr) Expr
  | FnDecl [Attribute] Visibility Name [Name] [Param] (Maybe TypeExpr) [Name] [Stmt]
  | TypeDecl Visibility Name [Name] TypeExpr
  | EffectDecl Visibility Name [EffectMember]
  | LawDecl Visibility Name [Name] Expr
  deriving (Eq, Show)

data Param = Param Pattern (Maybe TypeExpr)
  deriving (Eq, Show)

data EffectMember = EffectFn Name [Param] (Maybe TypeExpr) [Name]
  deriving (Eq, Show)

data Contract
  = Require Expr
  | Ensure Expr
  deriving (Eq, Show)

data Stmt
  = LetStmt Pattern (Maybe TypeExpr) Expr
  | ContractStmt Contract
  | ExprStmt Expr
  deriving (Eq, Show)

data TypeExpr
  = TypeName [Name]
  | TypeGeneric TypeExpr [TypeExpr]
  | TypeTuple [TypeExpr]
  | TypeUnit
  | TypeList TypeExpr
  | TypeRecord [(Name, TypeExpr)]
  | TypeFn [TypeExpr] TypeExpr [Name]
  | TypeSum [TypeVariant]
  deriving (Eq, Show)

data TypeVariant = TypeVariant Name [Param]
  deriving (Eq, Show)

data Expr
  = Var Name
  | Qualified [Name]
  | Lit Literal
  | Unit
  | Tuple [Expr]
  | List [Expr]
  | Record [(Name, Expr)]
  | Block [Stmt]
  | If Expr Expr (Maybe Expr)
  | Match Expr [MatchArm]
  | Lambda [Param] Expr
  | Call Expr [Arg]
  | Field Expr Name
  | Index Expr Expr
  | Unary String Expr
  | Binary String Expr Expr
  | Range Expr Bool Expr
  | Quantifier String Pattern QuantifierDomain Expr
  | Comprehension Expr [CompClause]
  deriving (Eq, Show)

data QuantifierDomain
  = InDomain Expr
  | TypeDomain TypeExpr
  deriving (Eq, Show)

data Arg
  = PosArg Expr
  | NamedArg Name Expr
  deriving (Eq, Show)

data CompClause
  = CompBind Pattern Expr
  | CompFilter Expr
  deriving (Eq, Show)

data MatchArm = MatchArm Pattern (Maybe Expr) Expr
  deriving (Eq, Show)

data Pattern
  = PWildcard
  | PBind Name
  | PLit Literal
  | PUnit
  | PTuple [Pattern]
  | PList [Pattern] (Maybe Name)
  | PRecord [(Name, Pattern)]
  | PVariant [Name] [ArgPattern]
  deriving (Eq, Show)

data ArgPattern
  = PosPat Pattern
  | NamedPat Name Pattern
  deriving (Eq, Show)

data FieldPattern = FieldPattern Name Pattern
  deriving (Eq, Show)

data Literal
  = LInt String
  | LFloat String
  | LString String
  | LChar Char
  | LBool Bool
  | LRawString String
  deriving (Eq, Show)
