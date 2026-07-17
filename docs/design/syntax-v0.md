# l1ne syntax 0.1

Status: draft language contract  
Source extension: `.ln`  
Encoding: UTF-8

This document contains the decisions needed to read and implement l1ne syntax. Type inference, evaluation, hashing, bytecode, scheduling, and runtime capability grants are separate specifications.

## 1. Core rules

1. Every file declares one `module` first; imports follow it.
2. Definitions are immutable. `let` binds a value; `=` never mutates one.
3. Functions are pure unless a `uses` clause declares external effects.
4. Blocks, `if`, and `match` are expressions. The final expression is the result.
5. Calls are local by default. `@remote` only makes a function eligible for remote placement.
6. Generic arguments use `[...]`; function results use `->`.
7. The surface language has no custom operators, macros, methods, implicit mutation, hidden I/O, or implicit truthiness.
8. Comments and non-semantic whitespace do not affect a definition's structural hash. Attributes do.
9. Law bodies, contract clauses, comprehensions, and quantifier predicates are pure. Effects are rejected inside them.

## 2. Readable notation and logic

### 2.1 Canonical English reading

l1ne code must read aloud as a precise English statement. Every semantic operator or marker has a canonical reading; new syntax is rejected if it has no short, unambiguous reading.

| Syntax | Canonical reading |
|---|---|
| `value :: Int` | “value has the type Int” |
| `name = expression` | “name is defined as expression” |
| `left == right` | “left equals right” |
| `fn(x :: A) -> B` | “a function from x of type A returning B” |
| `uses Console and Clock` | “may use Console and Clock” |
| `pattern => expression` | “when pattern matches, yield expression” |
| `Option[A]` | “Option of A” |
| `not p` | “not p” |
| `p and q` | “both p and q” |
| `p or q` | “p or q, or both” |
| `p implies q` | “if p, then q” |
| `p iff q` | “p if and only if q” |
| `forall x in xs: p(x)` | “for every x in xs, p of x holds” |
| `exists x in xs: p(x)` | “there exists an x in xs for which p of x holds” |
| `exists! x in xs: p(x)` | “there exists exactly one x in xs for which p of x holds” |
| `forall n :: Int: p(n)` | “for every n of type Int, p of n holds” |
| `low <= x < high` | “x is at least low and less than high” |
| `[f(x) : x in xs, p(x)]` | “the list of every f of x such that x is in xs and p of x holds” |
| `require p` | “requires that p holds” |
| `ensure p` | “ensures that the result satisfies p” |
| `law name: p` | “the law name states that p” |

`::` is reserved for type statements, annotations, and type-domain binders. A single `:` reads “with” when it names a value — `Point(x: 1.0)` is “Point with x equal to 1.0” — and “such that” when it introduces the body of a quantifier, the clauses of a comprehension, or the statement of a law.

English readability does not replace formal semantics. The parser still produces one exact AST, and the type and effect checkers decide whether that AST is valid.

Mathematical prose admits other phrasings — “q if p”, “p only if q”, “p is sufficient for q” all mean `p implies q` — but l1ne fixes exactly one reading per form and uses it everywhere: this specification, documentation, and diagnostics.

### 2.2 Boolean logic

Logic is classical Boolean logic over `Bool` values. Predicates used by quantifiers must be pure.

| Form | Exact meaning |
|---|---|
| `not p` | true exactly when `p` is false |
| `p and q` | true exactly when both are true |
| `p or q` | true when at least one is true |
| `p implies q` | `not p or q`; false only when `p` is true and `q` is false |
| `p iff q` | both values have the same truth value |
| `forall x in xs: p(x)` | true when `p(x)` is true for every value in finite `xs` |
| `exists x in xs: p(x)` | true when `p(x)` is true for at least one value in finite `xs` |
| `exists! x in xs: p(x)` | true when `p(x)` is true for exactly one value in finite `xs` |

`p and q` does not evaluate `q` when `p` is false; `p or q` does not evaluate `q` when `p` is true; `p implies q` does not evaluate `q` when `p` is false. `iff` always evaluates both sides. For an empty domain, `forall` is true and `exists` is false.

A quantifier takes exactly one binder. Its body extends as far right as possible, so a quantified expression used as an operand must be parenthesized. Binders nest left to right, and their order is significant — `forall x in xs: exists y in ys: p(x, y)` and `exists y in ys: forall x in xs: p(x, y)` are different statements:

```ln
forall x in xs: exists y in ys: related(x, y)
```

The standard equivalences are guaranteed, and tooling may rewrite through them: `not (p and q)` equals `not p or not q`, `not (p or q)` equals `not p and not q`, `not (p implies q)` equals `p and not q`, `not (forall x in xs: p(x))` equals `exists x in xs: not p(x)`, and `not (exists x in xs: p(x))` equals `forall x in xs: not p(x)`.

`exists!` is defined by desugaring: `exists! x in xs: p(x)` is exactly `exists x in xs: p(x) and (forall y in xs: p(y) implies y == x)`.

### 2.3 Two quantifier domains

A binder written with `in` ranges over a finite value and evaluates; a binder written with `::` ranges over a type and only states. `forall x in xs: p(x)` is an expression that computes a `Bool`. `forall n :: Int: p(n)` is a proposition about every `Int`; it cannot be computed, so it is legal only inside a `law` declaration (section 4). `in` is extensional, `::` is intensional; the two never mix meanings.

## 3. Complete example

```ln
module example.fibonacci

use std.io.{Console}
use std.text.{show}

type FibError =
    | Negative(Int)

type Point = {
    x :: Float
    y :: Float
}

@remote
pub fn fib(n :: Int) -> Result[Int, FibError] {
    if n < 0 {
        Err(Negative(n))
    } else {
        Ok(fibLoop(0, 1, n))
    }
}

fn fibLoop(a :: Int, b :: Int, remaining :: Int) -> Int {
    require remaining >= 0
    match remaining {
        0 => a
        _ => fibLoop(b, a + b, remaining - 1)
    }
}

law fibMonotone: forall n in 0..19: fibLoop(0, 1, n) <= fibLoop(0, 1, n + 1)

pub fn main() -> Unit uses Console {
    let origin = Point(x: 0.0, y: 0.0)
    let answer = fib(20)

    match answer {
        Ok(value) => Console.println("fib(20) = " + show(value))
        Err(Negative(value)) => Console.println("negative input: " + show(value))
    }
}
```

An explicit `;` discards a final expression's value or separates multiple items on one line.

## 4. Modules and declarations

```ln
module geometry.vector

use std.math
use std.math as math
use std.math.{sqrt, sin, cos}
use std.io.{Console as Terminal}
```

Only `pub` top-level declarations are visible from another module. Imports bind names and have no runtime side effects.

### Constants and bindings

```ln
const maxRetries :: Int = 5
const tau = 6.283185307179586

let count :: Int = 3
let doubled = count * 2
```

A constant is a pure compile-time value. A local `let` may use a pattern. There is no assignment operator.

### Functions

```ln
fn add(left :: Int, right :: Int) -> Int {
    left + right
}

fn identity[A](value :: A) -> A {
    value
}

fn announce(message :: String) -> Unit uses Console {
    Console.println(message)
}

let square = fn(value :: Int) => value * value
```

Named-function parameters require types. Lambda parameter types may be inferred. Omitting `-> Type` means `-> Unit`. Omitting `uses` means the empty effect set. Top-level recursion is allowed.

### Contracts

```ln
fn head[A](list :: [A]) -> A {
    require not isEmpty(list)
    first(list)
}

fn sort(list :: [Int]) -> [Int] {
    ensure isOrdered(result) and isPermutation(result, list)
    sortBy(compare, list)
}
```

`require` states the hypothesis a caller must establish; `ensure` states the conclusion the function guarantees, with `result` bound to the returned value. Together they read as a theorem about the function: if the requirements hold, the result satisfies the guarantees.

Contract clauses appear only at the top of a named function's body, before any other statement, and each takes one pure `Bool` expression. A function with an `ensure` clause may not name a parameter or binding `result`. Contracts are part of the definition and affect its structural hash. Checking mode — always, debug-only, or proof-discharged — is a build setting, not syntax.

### Types

```ln
type Option[A] =
    | None
    | Some(A)

type Tree[A] =
    | Empty
    | Node(value :: A, left :: Tree[A], right :: Tree[A])

type Point = {
    x :: Float
    y :: Float
}

type UserId = Int
type Transform = fn(Point) -> Point
```

Core forms:

```ln
Int                              // named type
std.time.Instant                 // qualified type
Option[Int]                      // generic type
(Int, String)                    // tuple
()                               // Unit
[Int]                            // immutable list
{ x :: Float, y :: Float }       // anonymous record
fn(Int, Int) -> Int              // pure function
fn(String) -> Unit uses Console  // effectful function
```

There are no nullable types. Use `Option[T]`. Parentheses only group; a tuple requires a comma. `()` is the `Unit` type and value.

### Effects

```ln
pub effect Console {
    fn print(text :: String) -> Unit
    fn println(text :: String) -> Unit
}

fn log(message :: String) -> Unit uses Console {
    Console.println(message)
}
```

An effect declares an external capability interface, not its implementation. `uses Console` is an upper bound: the function may request `Console`; the runtime may still deny it. A caller must declare every effect its callees may request.

### Laws

```ln
law addCommutes: forall a :: Int: forall b :: Int: a + b == b + a

pub law revInvolution[A]: forall xs :: [A]: reverse(reverse(xs)) == xs

law fibBase: fibLoop(0, 1, 0) == 0 and fibLoop(0, 1, 1) == 1
```

A `law` names a pure Boolean proposition about the module's definitions. It reads “the law addCommutes states that for every a of type Int, for every b of type Int, a plus b equals b plus a.” Laws are declarations, not expressions: they never execute at runtime, take no arguments, and are the only place a type-domain binder (`::`) may appear. A law body over finite `in` domains is directly checkable; a law over type domains is checked by property testing in 0.1 and by proof later. The compiler verifies only that a law is well typed and pure. A law hashes like any other declaration, so a module's stated theorems travel with its code.

## 5. Expressions

### Blocks and conditionals

```ln
let result = {
    let doubled = input * 2
    doubled + 1
}

let magnitude = if value < 0 {
    -value
} else {
    value
}
```

A block returns its final unterminated expression; otherwise it returns `()`. An `if` condition must be `Bool`. An `if` without `else` returns `Unit`.

### Pattern matching

```ln
match value {
    None => fallback
    Some(number) if number > 0 => number
    Some(_) => 0
}
```

Supported patterns are wildcards, bindings, literals, variants, tuples, lists, records, and one list rest pattern such as `[first, ..rest]`. Matches must be exhaustive. Use `match` instead of a refutable `let`.

### Calls, fields, ranges, and iteration

```ln
sum(1, 2)
connect(host: "localhost", port: 7000)
point.x
matrix[row][column]
0..10       // excludes 10
0..=10      // includes 10
```

Positional arguments must precede named arguments. Calls, field access, and indexing may chain. Ranges are finite values consumed by library functions, quantifiers, and comprehensions.

There is no `for`, `return`, `break`, or `continue`. Use recursion or pure functions such as `map`, `filter`, and `fold`.

### Comprehensions

```ln
[n * n : n in 0..10]                        // squares of 0 through 9
[x : x in xs, x != 0]                       // xs without zeros
[(x, y) : x in xs, y in ys, related(x, y)]  // related pairs
```

A comprehension reads “the list of every n squared such that n is in 0 to 10.” After the head expression, `:` introduces comma-separated clauses: either a binder `pattern in expression` or a pure `Bool` filter. The first clause must be a binder; clauses scope left to right, and later binders iterate fastest.

The form desugars mechanically — `[f(x, y) : x in xs, p(x), y in ys]` is exactly

```ln
flatMap(xs, fn(x) => if p(x) { map(ys, fn(y) => f(x, y)) } else { [] })
```

so a comprehension is library `map`/`filter`/`flatMap`, not new semantics. In a list literal `,` separates elements and `:` never appears, so the two bracket forms cannot be confused. A comprehension is not a pattern.

## 6. Lexical contract

Identifiers are ASCII in 0.1:

```text
[A-Za-z_][A-Za-z0-9_]*
```

Use `lowerCamelCase` for values and modules, `UpperCamelCase` for types and effects, and `_` as the wildcard pattern.

Reserved words are never identifiers:

```text
module  use  as  pub  fn  type  effect  const  let
if  else  match  uses  not  and  or  implies  iff
forall  exists  in  law  require  ensure  true  false
```

Literals include integers in bases 2, 8, 10, and 16; decimal floats; characters; escaped strings; raw backtick strings; and `true`/`false`. Numeric `_` separators are allowed only between digits. A leading `-` is a separate unary operator.

Comments:

```ln
// line comment
/* nested block comment */
/// documentation for the next declaration
```

Normal comments are discarded. Documentation comments attach to the next declaration but are excluded from structural hashes.

Operators and semantic markers:

```text
:  ::  =  =>  ->
+  -  *  /  %  **
==  !=  <  <=  >  >=
..  ..=
not  and  or  implies  iff
```

Unknown punctuation is an error. The lexer chooses the longest valid token, so `::`, `=>`, `->`, `<=`, `>=`, `==`, `!=`, `..`, and `..=` are single tokens. `exists!` is likewise one token; a bare `!` appears in no other position.

### Automatic semicolons

A newline becomes `;` when it is outside parentheses and brackets, the previous token can end an expression or declaration, and the next token does not continue it. Newlines before `}`, `else`, `|`, `,`, `.`, `)`, or `]` do not insert a semicolon. End of file behaves like a newline.

Braces do not suppress insertion. Keep `{` on the same line as `fn`, `effect`, `if`, and `match` headers.

### Math display profile

Editors and formatters may render source through a fixed display profile. The map is bijective, applies only to these tokens, and never changes what is stored or hashed — source files remain ASCII:

| Source | Display |
|---|---|
| `forall` / `exists` / `exists!` | ∀ ∃ ∃! |
| `in` | ∈ |
| `implies` / `iff` | ⟹ ⟺ |
| `->` | → |
| `<=` / `>=` / `!=` | ≤ ≥ ≠ |

The glyphs are display-only: the lexer rejects them as input. One spelling exists in source; beauty is the renderer's job. Because structural hashing ignores presentation, rendering is provably semantics-free.

## 7. Precedence

From tightest to loosest:

| Level | Forms | Associativity |
|---:|---|---|
| 1 | call `()`, index `[]`, field `.` | left |
| 2 | unary `not`, `-`, `+` | right |
| 3 | `**` | right |
| 4 | `*`, `/`, `%` | left |
| 5 | `+`, `-` | left |
| 6 | `..`, `..=` | none |
| 7 | `<`, `<=`, `>`, `>=` | chain |
| 8 | `==`, `!=` | chain (`==` only) |
| 9 | `and` | left |
| 10 | `or` | left |
| 11 | `implies` | right |
| 12 | `iff` | none |

Range chaining is rejected. Comparison chains are legal when monotone: every link from `{<, <=}`, every link from `{>, >=}`, or every link `==`. A chain desugars to pairwise conjunction with each operand evaluated once — `low <= x < high` is exactly `low <= x and x < high` and reads “x is at least low and less than high.” Direction-mixing chains and any chain containing `!=` are rejected.

`not` binds tighter than comparisons: `not value < limit` parses as `(not value) < limit` and fails type checking. Write `not (value < limit)`. Quantifiers bind loosest of all; `forall`, `exists`, and `exists!` absorb everything to their right, and a quantified operand requires parentheses: `(forall x in xs: p(x)) implies q`.

## 8. Required validation

The parser or immediate validation pass rejects:

- missing or duplicate module declarations, declarations before imports, and unknown punctuation;
- positional arguments after named arguments or duplicate named arguments;
- mixed positional and named fields in one variant;
- more than one list rest pattern or a non-final rest pattern;
- range chaining, non-monotone comparison chains, and chains containing `!=`;
- a type-domain binder (`::`) outside a `law` body, or a `law` whose body is not `Bool`;
- contract clauses after the first non-clause statement or outside a named function's body, and a binding named `result` in a function with an `ensure` clause;
- a comprehension whose first clause is not a binder, or comprehension syntax in pattern position;
- a bare `_` in expression position;
- non-Boolean conditions and non-exhaustive matches during semantic checking;
- effects requested inside laws, contract clauses, comprehensions, or quantifier predicates during effect checking.

The frontend must keep lexing, parsing, name resolution, type checking, effect checking, and structural hashing as separate stages.

## 9. Deferred from 0.1

Mutation, assignment, imperative loops, early return, methods, classes, traits, ownership syntax, user-defined effect handlers, async/await, string interpolation, macros, custom operators, open-ended ranges, default or variadic arguments, wildcard imports, nullable references, implicit numeric conversions, and multi-binder quantifiers (`forall x, y in xs`).

Rejected outright, never to be added: `where` clauses (a second binding convention beside `let`); implicit universal quantification of unbound variables (mathematical prose allows it; a precise language cannot); Unicode as input syntax (the display profile renders it; the lexer refuses it).

A future syntax addition needs a motivating example, one canonical English reading, and an explicit account of lexer, grammar, precedence, and ambiguity changes.
