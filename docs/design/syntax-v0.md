# l1ne syntax 0.1

Status: draft parser contract  
Source extension: `.ln`  
Encoding: UTF-8

This document defines the first concrete l1ne surface syntax. It is intentionally small enough for a hand-written lexer and recursive-descent parser. It does not define type inference, evaluation, hashing, bytecode, scheduling, or runtime effect grants.

## 1. Design direction

l1ne uses:

- Go's readable declarations, braces, package-like modules, and automatic semicolons.
- Haskell's immutable bindings, algebraic data types, pure-by-default functions, and pattern matching.
- Lean's explicit mathematical structure and preference for unambiguous notation.
- Rust's `fn`, expression-valued blocks, attributes, exhaustive `match`, and explicit effect-like boundaries.

Version 0.1 favors one obvious spelling over shorthand. It has no custom operators, macros, methods, implicit mutation, or hidden I/O.

### Fixed principles

1. A source file is one module and begins with `module`.
2. Definitions are immutable. Local bindings use `let`; there is no assignment operator.
3. A function without a `uses` clause is pure.
4. Outside-world access is named after `uses`: `uses Console and Clock`.
5. Blocks and conditionals are expressions. Their final unterminated expression is their value.
6. Generic parameters use square brackets, avoiding the `<` ambiguity found in C-like grammars.
7. Calls are local by default. `@remote` marks a definition as eligible for remote execution; placement remains runtime policy.
8. Comments, source spans, and whitespace discarded by the layout pass are not semantic AST nodes and must not affect a definition's structural hash. A newline that inserts a semicolon is syntax and may change the AST. Documentation comments and attributes are retained separately.

## 2. A complete example

```ln
module example.fibonacci

use std.io.{Console}
use std.text.{show}

type FibError =
    | Negative(Int)

type Point = {
    x: Float
    y: Float
}

@remote
pub fn fib(n: Int) -> Result[Int, FibError] {
    if n < 0 {
        Err(Negative(n))
    } else {
        Ok(fibLoop(0, 1, n))
    }
}

fn fibLoop(a: Int, b: Int, remaining: Int) -> Int {
    match remaining {
        0 => a
        _ => fibLoop(b, a + b, remaining - 1)
    }
}

pub fn main() -> Unit uses Console {
    let origin = Point(x: 0.0, y: 0.0)
    let answer = fib(20)

    match answer {
        Ok(value) => Console.println("fib(20) = " + show(value))
        Err(Negative(value)) => Console.println("negative input: " + show(value))
    }
}
```

The last expression in a block is its result. An explicit semicolon discards that expression's value.

## 3. Lexical syntax

### 3.1 Source text

- Files use UTF-8.
- A byte-order mark is rejected.
- `LF` and `CRLF` are accepted; the lexer normalizes both to one logical newline.
- Tabs are allowed as whitespace but indentation has no grammar meaning.
- The lexer tracks byte offset, one-based line, and one-based Unicode-scalar column for every token and error.

### 3.2 Identifiers

Version 0.1 identifiers are deliberately ASCII:

```text
identifier = [A-Za-z_][A-Za-z0-9_]*
```

An isolated `_` is the wildcard pattern. Naming conventions are semantic lint, not grammar:

- `lowerCamelCase` for values, functions, fields, and modules.
- `UpperCamelCase` for types, variants, and effects.
- `UPPER_SNAKE_CASE` for constants when desired.

Qualified names use dots: `std.io.Console.println`.

### 3.3 Keywords

| Keyword | Meaning |
|---|---|
| `module` | Name current module. |
| `use` | Import module or names. |
| `as` | Alias an import. |
| `pub` | Export a declaration. |
| `fn` | Define a named or anonymous function. |
| `const` | Define a pure compile-time value. |
| `type` | Define alias, record, or sum type. |
| `effect` | Declare an external capability interface. |
| `uses` | Declare effects a function may request. |
| `let` | Bind an immutable local value. |
| `if` | Start a conditional expression. |
| `else` | Give its alternative expression. |
| `match` | Select by pattern. |
| `in` | Bind a quantified variable to a finite domain. |
| `true`, `false` | Boolean literals. |
| `not` | Logical negation. |
| `and` | Boolean conjunction; joins effect names after `uses`. |
| `or` | Short-circuit Boolean disjunction. |
| `implies` | One-way condition: `P` guarantees `Q`. |
| `iff` | Two-way equivalence: “if and only if.” |
| `forall` | Every value satisfies predicate. |
| `exists` | At least one value satisfies predicate. |

Keywords cannot be identifiers. Built-in type names such as `Int`, `Bool`, `String`, and `Unit` are ordinary prelude names, not keywords.

### 3.4 Comments

```ln
// line comment

/* block comment */

/* block comments
   /* may nest */
*/

/// documentation for the next declaration
/** documentation for the next declaration */
```

Normal comments are discarded. Documentation comments are attached as out-of-band trivia to the source position of the next declaration, then removed from the parser token stream. The parser retrieves that metadata when it builds the declaration. Documentation is excluded from structural hashes.

### 3.5 Number literals

```ln
0
1_000_000
0b1010_0110
0o755
0xFF_A0
3.1415
1.0e-9
2e10
```

Rules:

- `_` may occur only between digits.
- Base prefixes are lowercase in source, though hexadecimal digits may use either case.
- Decimal floats require digits on both sides of `.`. Write `1.0`, not `1.`.
- An exponent may follow a decimal integer or float.
- Numeric suffixes are not part of 0.1. Types come from context, annotations, or explicit conversion functions.
- A leading `-` is always a separate unary operator.
- The lexer uses longest-match tokenization, so `1..3` is `1`, `..`, `3`, not a float.

### 3.6 Character and string literals

```ln
'a'
'\n'
'\u{03BB}'

"escaped string\n"
`raw string: backslashes and newlines are unchanged`
```

Escaped literals support `\\`, `\"`, `\'`, `\n`, `\r`, `\t`, `\0`, and `\u{HEX}`. A character literal contains exactly one Unicode scalar after escape decoding. Raw strings cannot contain a backtick. String interpolation is not part of 0.1.

### 3.7 Punctuation and operators

```text
(  )  {  }  [  ]  ,  :  ;  .  @  |
=  =>  ->
+  -  *  /  %  **
==  !=  <  <=  >  >=
..  ..=
```

Boolean logic uses the word operators `not`, `and`, `or`, `implies`, and `iff`. The only operator token beginning with `!` is `!=`.

Unknown punctuation is a lexical error. The lexer always selects the longest valid token.

### 3.8 Automatic semicolons

The lexer converts some physical newlines into synthetic `;` tokens. This keeps ordinary code semicolon-free while giving the parser explicit separators.

A newline becomes `;` when all of these are true:

1. Parenthesis and bracket depth are both zero. Braces do not suppress insertion.
2. The previous token is an identifier, literal, `true`, `false`, `)`, `]`, or `}`.
3. The next non-comment token is not `}`, `else`, `|`, `,`, `.`, `)`, or `]`.

End of file behaves like a newline. Repeated separators are allowed between declarations and block items.

Consequences:

```ln
let x = 1          // semicolon inserted
let y = x +        // no insertion after an operator
    2

if ready {         // opening brace stays on the declaration line
    work()
} else {           // no insertion before else
    wait()
}
```

Write an explicit `;` to put multiple items on one line or to discard a block's final value. A newline before `{` ends the preceding construct and is therefore invalid for function and effect declarations, `if`, and `match`.

## 4. Modules and imports

Every file starts with exactly one module declaration:

```ln
module geometry.vector
```

Imports follow it:

```ln
use std.math
use std.math as math
use std.math.{sqrt, sin, cos}
use std.io.{Console as Terminal}
```

- `use std.math` binds the final segment, `math`.
- `as` gives a module or selected name an alias.
- A selective import binds only the listed names.
- Wildcard imports are not part of 0.1.
- Imports are not textual inclusion and have no runtime side effects.

Only `pub` top-level declarations are visible to another module.

## 5. Declarations

A module contains `const`, `type`, `effect`, and `fn` declarations. Any may be preceded by attributes and `pub`.

### 5.1 Attributes

```ln
@remote
@remote(policy = "always")
@derive(Eq, Show)
pub fn compute(input: Data) -> Result { computeImpl(input) }
```

Attribute arguments are identifiers, literals, or `name = literal` pairs. Attributes are retained in the AST. Unknown attributes are accepted by the parser and rejected by a later validation phase.

`@remote` means that a function is eligible for remote placement. It does not turn every call into a network hop.

### 5.2 Constants

```ln
const maxRetries: Int = 5
const tau = 6.283185307179586
```

A constant initializer must later type-check as a pure compile-time expression. The type annotation is optional.

### 5.3 Functions

```ln
fn add(left: Int, right: Int) -> Int {
    left + right
}

fn identity[A](value: A) -> A {
    value
}

pub fn announce(message: String) -> Unit uses Console and Clock {
    Console.println(message)
}
```

- Parameters always have type annotations in named function declarations.
- Generic parameters are names inside `[...]`.
- The default return type is `Unit` when `-> Type` is omitted.
- No `uses` clause means the empty effect set.
- Effects are an unordered set semantically; source order is preserved only for diagnostics.
- Function bodies are expression-valued blocks.
- Recursive and mutually recursive top-level functions are allowed; name resolution handles them after parsing.

Anonymous functions use the same vocabulary:

```ln
let square = fn(value: Int) => value * value
let choose = fn[A](value: A) -> A => value
let log = fn(message: String) -> Unit uses Console => {
    Console.println(message)
}
```

Lambda parameter annotations may be omitted when inference has enough context:

```ln
map(values, fn(value) => value * value)
```

Functions are first-class. Composition stays an ordinary function, not special syntax:

```ln
let h = compose(g, f) // h(x) == g(f(x))
```

### 5.4 Algebraic and record types

A sum type uses leading variants:

```ln
type Option[A] =
    | None
    | Some(A)

type Tree[A] =
    | Empty
    | Node(value: A, left: Tree[A], right: Tree[A])
```

A record type uses named fields:

```ln
type Point = {
    x: Float
    y: Float
}
```

A type alias uses any other type expression:

```ln
type UserId = Int
type Transform = fn(Point) -> Point
type Fallible[A, E] = Result[A, E]
```

Constructors use ordinary call syntax:

```ln
None
Some(42)
Node(value: 1, left: Empty, right: Empty)
Point(x: 2.0, y: 3.0)
```

Within one call, positional arguments must precede named arguments. An argument name may occur at most once.

### 5.5 Effects

```ln
pub effect Console {
    fn print(text: String) -> Unit
    fn println(text: String) -> Unit
}

pub effect Clock {
    fn now() -> Instant
}
```

An effect declares operations but does not implement them. Calling an operation requires that effect after `uses` in the enclosing function:

```ln
fn timestamped(message: String) -> Unit uses Console and Clock {
    let instant = Clock.now()
    Console.println(show(instant) + ": " + message)
}
```

`uses` is a type-and-effect declaration:

| Form | Meaning |
|---|---|
| `fn hash(x: Data) -> Hash` | Pure. Requests no external capability. |
| `fn now() -> Instant uses Clock` | May request `Clock`. |
| `fn log(s: String) -> Unit uses Console and Clock` | May request either named effect. |

- `use` imports a name; `uses` declares behavior.
- A caller must declare every effect its callees may request.
- Runtime grants remain separate and may deny a declared effect.
- `uses` is an upper bound: declaration permits an effect; it does not execute one.

The earlier `with` spelling is removed. `uses` says the intent directly.

Runtime capability grants and effect handlers are intentionally outside the 0.1 surface syntax. The parser records declarations, operation calls, and effect sets; later phases connect them to the broker.

## 6. Types

Core type forms are:

```ln
Int                         // named type
std.time.Instant            // qualified type
Option[Int]                 // generic application
(Int, String)               // tuple
()                          // Unit
[Int]                       // immutable list
{ x: Float, y: Float }      // anonymous record type
fn(Int, Int) -> Int         // pure function
fn(String) -> Unit uses Console // effectful function
```

Function types use `fn(...) -> ...` rather than overloading parenthesized tuple syntax. Type application uses square brackets. There are no nullable types; define or use an algebraic type such as `Option[T]`.

Parentheses group one type or expression. A tuple requires a comma: `(value,)` is a one-element tuple, while `(value)` is only `value`. The same rule applies to tuple patterns. `()` is the `Unit` value and type.

Ownership, borrowing, lifetimes, type classes/traits, higher-kinded parameters, row polymorphism, and dependent types are not 0.1 syntax. They may be added only after the core grammar and semantics are exercised.

## 7. Expressions and control flow

### 7.1 Blocks and bindings

```ln
let result = {
    let doubled = input * 2
    doubled + 1
}
```

A block contains zero or more items separated by inserted or explicit semicolons. If its final item is an expression without an explicit semicolon, that expression is the block's value. Otherwise the block's value is `()`.

`let` supports patterns and an optional type:

```ln
let count: Int = 3
let (left, right) = pair
let Some(value) = optional
```

A refutable `let` pattern such as `Some(value)` must later be proven irrefutable or rejected; use `match` for ordinary branching.

### 7.2 Conditionals

```ln
let magnitude = if value < 0 {
    -value
} else {
    value
}
```

`if` is an expression. If `else` is omitted, the result type is `Unit`. Conditions must have type `Bool`; numbers and references are not implicitly truthy.

### 7.3 Pattern matching

```ln
match value {
    None => fallback
    Some(number) if number > 0 => number
    Some(_) => 0
}
```

Match arms are separated by newline or comma. Guards follow the pattern with `if`. Exhaustiveness and unreachable arms are semantic checks, not parser checks.

Patterns in 0.1:

```ln
_                              // wildcard
name                           // binding
42                             // literal
"text"
true
None                           // variant
Some(value)
Point(x: px, y: py)            // named fields
(left, right)                  // tuple
[]                             // list
[first, second, ..rest]
```

Qualified constructors are allowed. Alternative patterns, ranges, and view patterns are deferred.

### 7.4 Logic and finite quantifiers

Logic uses short ASCII words:

Model: [Book of Proof, Chapter 2](https://richardhammack.github.io/BookOfProof/Main.pdf). l1ne keeps conditional, biconditional, and quantifier meanings, but spells them with words.

```ln
not p
p and q
p or q
p implies q
p iff q
```

`p implies q` fails only when `p` is `true` and `q` is `false`. `p iff q` means **p if and only if q**:

```ln
(p implies q) and (q implies p)
```

Thus `implies` is one-way; `iff` requires both directions. `and`, `or`, and `implies` short-circuit left to right. No Unicode logic aliases exist in 0.1.

Finite quantifiers follow mathematical reading without symbols:

```ln
let allPositive = forall x in values: x > 0
let hasZero = exists x in values: x == 0
let related = forall x in xs, y in ys: relation(x, y)
```

Binders nest left to right, so order matters:

```ln
forall x in xs: exists y in ys: relation(x, y)
```

Negation laws stay readable:

```ln
not (forall x in xs: p(x)) iff exists x in xs: not p(x)
not (exists x in xs: p(x)) iff forall x in xs: not p(x)
```

`forall` and `exists` return `Bool`; predicates must be pure. Empty domain: `forall` is `true`, `exists` is `false`.

### 7.5 Functional iteration

l1ne has no `for`, `return`, `break`, or `continue`. Use recursion or pure library functions such as `map`, `filter`, and `fold`.

```ln
fn firstPositive(values: [Int]) -> Option[Int] {
    match values {
        [] => None
        [value, ..rest] => if value > 0 {
            Some(value)
        } else {
            firstPositive(rest)
        }
    }
}
```

### 7.6 Calls, fields, and indexing

```ln
sum(1, 2)
connect(host: "localhost", port: 7000)
point.x
matrix[row][column]
std.math.sqrt(value)
```

Postfix call, field, and index operations may chain. Optional chaining, implicit method receivers, operator sections, and user-defined postfix operators are not part of 0.1.

### 7.7 Ranges

```ln
0..10       // excludes 10
0..=10      // includes 10
```

Ranges are expressions consumed by pure library functions and finite quantifiers. Open-ended ranges are deferred.

## 8. Operator precedence

From tightest to loosest:

| Level | Operators/forms | Associativity |
|---:|---|---|
| 1 | call `()`, index `[]`, field `.` | left |
| 2 | unary `not`, unary `-`, unary `+` | right |
| 3 | `**` | right |
| 4 | `*`, `/`, `%` | left |
| 5 | `+`, `-` | left |
| 6 | `..`, `..=` | non-associative |
| 7 | `<`, `<=`, `>`, `>=` | non-associative |
| 8 | `==`, `!=` | non-associative |
| 9 | `and` | left |
| 10 | `or` | left |
| 11 | `implies` | right |
| 12 | `iff` | non-associative |

Comparison chaining is rejected: write `low <= value and value <= high`. Operator overloading and custom operators are deferred.

## 9. Parser grammar

This EBNF operates on tokens after comment removal and semicolon insertion. `sep` means one or more `;` tokens. Commas shown as optional trailing commas are real tokens; newlines inside `()` and `[]` do not replace them.

```ebnf
source          = moduleDecl, sep,
                  { useDecl, sep },
                  { declaration, sep }, EOF ;

moduleDecl      = "module", modulePath ;
modulePath      = identifier, { ".", identifier } ;

useDecl         = "use", modulePath,
                  [ "as", identifier
                  | ".", "{", importItem,
                    { ",", importItem }, [ "," ], "}" ] ;
importItem      = identifier, [ "as", identifier ] ;

declaration     = { attribute, { ";" } }, [ "pub" ],
                  ( constDecl | typeDecl | effectDecl | fnDecl ) ;

attribute       = "@", modulePath,
                  [ "(", [ attributeArg,
                    { ",", attributeArg }, [ "," ] ], ")" ] ;
attributeArg    = literal | identifier | identifier, "=", literal ;

constDecl       = "const", identifier, [ ":", typeExpr ], "=", expr ;

fnDecl          = "fn", identifier, [ typeParams ],
                  "(", [ parameter, { ",", parameter }, [ "," ] ], ")",
                  [ "->", typeExpr ], [ effectClause ], block ;
parameter       = identifier, ":", typeExpr ;
typeParams      = "[", identifier, { ",", identifier }, [ "," ], "]" ;
effectClause     = "uses", typePath, { "and", typePath } ;

effectDecl      = "effect", identifier, "{", { ";" },
                  { effectOperation, sep }, [ effectOperation ],
                  { ";" }, "}" ;
effectOperation = "fn", identifier, [ typeParams ],
                  "(", [ parameter, { ",", parameter }, [ "," ] ], ")",
                  [ "->", typeExpr ] ;

typeDecl        = "type", identifier, [ typeParams ], "=", typeBody ;
typeBody        = sumType | recordType | typeExpr ;
sumType         = "|", variant, { "|", variant } ;
variant         = identifier,
                  [ "(", [ variantField,
                    { ",", variantField }, [ "," ] ], ")" ] ;
variantField    = typeExpr | identifier, ":", typeExpr ;
recordType      = "{", { ";" }, [ recordField,
                  { fieldSep, recordField }, [ fieldSep ] ], "}" ;
recordField     = identifier, ":", typeExpr ;
fieldSep        = "," | sep ;

typeExpr        = typePath, [ typeArgs ]
                | "(", [ typeExpr, { ",", typeExpr }, [ "," ] ], ")"
                | "[", typeExpr, "]"
                | recordType
                | functionType ;
typePath        = identifier, { ".", identifier } ;
typeArgs        = "[", typeExpr, { ",", typeExpr }, [ "," ], "]" ;
functionType    = "fn", "(", [ typeExpr,
                  { ",", typeExpr }, [ "," ] ], ")",
                  "->", typeExpr, [ effectClause ] ;

block           = "{", { ";" },
                  { blockItem, sep }, [ blockItem ], { ";" }, "}" ;
blockItem       = letItem | expr ;
letItem         = "let", pattern, [ ":", typeExpr ], "=", expr ;

expr            = binaryExpr ;
ifExpr          = "if", expr, block, [ "else", ( ifExpr | block ) ] ;
matchExpr       = "match", expr, "{", { ";" },
                  [ matchArm, { armSep, matchArm }, [ armSep ] ], "}" ;
matchArm        = pattern, [ "if", expr ], "=>", expr ;
armSep          = "," | sep ;
quantifiedExpr  = ( "forall" | "exists" ), quantifierBinding,
                  { ",", quantifierBinding }, ":", expr ;
quantifierBinding = pattern, "in", expr ;

lambdaExpr      = "fn", [ typeParams ],
                  "(", [ lambdaParam,
                    { ",", lambdaParam }, [ "," ] ], ")",
                  [ "->", typeExpr ], [ effectClause ], "=>", expr ;
lambdaParam     = identifier, [ ":", typeExpr ] ;

binaryExpr      = unaryExpr, { binaryOp, unaryExpr } ;
unaryExpr       = { "not" | "+" | "-" }, postfixExpr ;
postfixExpr     = primaryExpr, { callSuffix | indexSuffix | fieldSuffix } ;
callSuffix      = "(", [ callArg, { ",", callArg }, [ "," ] ], ")" ;
callArg         = [ identifier, ":" ], expr ;
indexSuffix     = "[", expr, "]" ;
fieldSuffix     = ".", identifier ;

primaryExpr     = literal | identifier | "_"
                | "(", [ expr, { ",", expr }, [ "," ] ], ")"
                | "[", [ expr, { ",", expr }, [ "," ] ], "]"
                | block | ifExpr | matchExpr
                | quantifiedExpr | lambdaExpr ;

pattern         = "_" | literal | patternPath
                | "(", [ pattern, { ",", pattern }, [ "," ] ], ")"
                | "[", [ listPattern,
                    { ",", listPattern }, [ "," ] ], "]" ;
patternPath     = identifier, { ".", identifier },
                  [ "(", [ patternField,
                    { ",", patternField }, [ "," ] ], ")" ] ;
patternField    = pattern | identifier, ":", pattern ;
listPattern     = pattern | "..", identifier ;

literal         = integer | float | character | string | rawString
                | "true" | "false" ;
binaryOp        = "**" | "*" | "/" | "%" | "+" | "-"
                | ".." | "..=" | "<" | "<=" | ">" | ">="
                | "==" | "!=" | "and" | "or" | "implies" | "iff" ;
sep             = ";", { ";" } ;
```

`binaryExpr` above is a compact grammar placeholder for a precedence parser. Implement it as a Pratt parser or as one recursive-descent function per precedence level. Non-associative levels reject a second unparenthesized operator at the same level.

### Required grammar validations

The parser or immediate syntax-validation pass rejects:

- mixed positional and named variant fields in one declaration;
- positional call arguments after a named argument;
- duplicate named arguments;
- more than one list rest pattern or a rest pattern before a later element;
- chained range or comparison operators without parentheses;
- a bare `_` in expression position;
- missing `module`, declarations before imports, and duplicate module declarations.

## 10. Lexer and parser construction order

Build the frontend in this order so each layer can be exercised independently:

1. **Source positions** — byte offset, line, column, and half-open spans.
2. **Raw lexer** — identifiers, keywords, literals, comments, punctuation, and lexical errors.
3. **Layout pass** — discard normal comments, attach documentation comments as out-of-band declaration trivia, remove them from the token stream, and insert synthetic semicolons.
4. **Module parser** — `module`, `use`, attributes, and declaration boundaries.
5. **Type parser** — named, generic, tuple, list, record, and function types.
6. **Expression parser** — postfix forms first, then unary and precedence climbing/Pratt parsing.
7. **Structured forms** — blocks, `if`, `match`, `forall`, `exists`, lambdas, and patterns.
8. **Syntax validation** — context rules that are clearer outside the grammar.
9. **Surface AST normalization** — remove separators and redundant parentheses while retaining spans and documentation metadata.

Do not combine lexing, name resolution, type checking, effect checking, or structural hashing. The parser should accept unknown names and attributes and produce a complete surface AST or a structured diagnostic.

## 11. Explicitly deferred syntax

The following stay out until real programs demonstrate a need:

- mutation, assignment, imperative loops, and early return;
- methods, classes, traits/type classes, and operator overloading;
- ownership, borrowing, and lifetime annotations;
- effect handlers in user source;
- async/await syntax and first-class futures;
- string interpolation and format-string mini-languages;
- macros, conditional compilation, and custom attributes with expression arguments;
- custom operators, Unicode aliases, comparison chaining, and open-ended ranges;
- default arguments, variadic parameters, and wildcard imports;
- nullable references and implicit numeric conversions.

This boundary is part of version 0.1. Additions should include a motivating `.ln` example, lexer impact, grammar delta, precedence impact when applicable, and the smallest ambiguity introduced.