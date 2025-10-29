# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

L1NE is a monorepo containing independent projects (similar to Rust workspace crates):

- **`src/parsers/nix-zig/`** - Nix language parser producing CST
- **`src/parsers/ccl-zig/`** - CCL configuration language parser
- **`src/l1ne/`** - L1NE orchestrator/runtime for managing Nix flake-based services
- **`dumb-server/`** - Rust-based demo server (separate Nix flake)

Each project is independent and can be developed/tested separately.

## Build System

This project uses Zig 0.15.1 (strict version requirement enforced at compile time).

### Common Commands

**Build the nix-test executable:**
```bash
zig build
```

**Run Nix parser on a single file:**
```bash
zig build nix-test -- path/to/file.nix
```

**Run all Nix parser tests:**
```bash
zig build nix-test-all
```

**Development environment (via Nix):**
```bash
nix develop
```

### Dumb-server (Rust Component)

The `dumb-server/` directory is a separate Rust project with its own flake.

```bash
cd dumb-server
nix build              # Build the server
nix run                # Run the server
```

## Code Architecture

### Monorepo Structure

Each component in `src/` is independent:

- **`src/parsers/nix-zig/`** - Nix parser (standalone module)
- **`src/parsers/ccl-zig/`** - CCL parser (standalone module, code remains but moved to separate repo)
- **`src/l1ne/`** - Main orchestrator (currently under development)

This structure mirrors Rust workspace patterns where each crate is self-contained.

### Nix Parser (`src/parsers/nix-zig/`)

A complete Nix language parser producing a Concrete Syntax Tree (CST).

- **Entry point:** `root.zig` exposes `parse()` function
- **Tokenizer:** `tokenizer.zig` - lexical analysis
- **Parser:** `parser.zig` - syntax analysis producing CST nodes
- **AST:** `ast.zig` - CST node definitions
- **Test runner:** `test_runner.zig` - runs all parser tests with statistics
- **Test data:** `test_data/parser/{success,error}/` - test cases

The parser handles:
- Dynamic attributes via `${}` interpolation
- Pattern bindings (`@` syntax)
- Lambda expressions with identifiers and patterns
- Whitespace-preserving CST for tooling use cases

### CCL Parser (`src/parsers/ccl-zig/`)

A configuration language parser (standalone module).

- **Entry point:** `root.zig`
- **Parser:** `parser.zig`
- **Deserializer:** `deserialize.zig` - typed deserialization from CCL

### L1NE Orchestrator (`src/l1ne/`)

The main orchestration system (currently under development).

- **Entry point:** `main.zig`
- **CLI:** `cli.zig` - command-line argument parsing
- **Master:** `master.zig` - orchestration logic
- **Systemd integration:** `systemd.zig` - manages services via systemd
- **Types:** `types.zig` - core data structures

## Development Guidelines

### NO GAMBIARRA POLICY

This codebase follows a strict "no hacks" policy. Code must be:
- High quality and clean (not "clean code" dogma, but genuinely simple)
- Modular and functional
- Fast and efficient (similar quality to professional Rust codebases like dtolnay's crates)

**If a task seems impossible or you cannot implement it properly:**
1. DO NOT implement a half-baked solution
2. Leave code unchanged
3. Explain the situation honestly
4. Ask for feedback and clarifications

The user is a domain expert who can provide proper solutions.

### TIGERSTYLE CODING PHILOSOPHY

This codebase follows TigerBeetle's TigerStyle principles. See `docs/TIGER_STYLE.md` for the complete guide.

**Key principles:**

**Safety First:**
- Use simple, explicit control flow - no recursion
- Put limits on everything (loops, queues)
- Assert all function arguments, return values, and invariants (minimum 2 assertions per function)
- Assert both positive space (what you expect) AND negative space (what you don't expect)
- Use explicitly-sized types (`u32`, not `usize`)
- All memory statically allocated at startup
- Functions limited to 70 lines max
- Push `if`s up, push `for`s down - centralize control flow

**Performance:**
- Think performance from the outset, not after profiling
- Optimize slowest resources first: network → disk → memory → CPU
- Batch everything to amortize costs
- Extract hot loops into standalone functions with primitive arguments

**Developer Experience:**
- Get nouns and verbs exactly right - names capture essence
- Use `snake_case` for everything, no abbreviations
- Always say WHY in comments and commit messages
- Split compound conditions into nested `if/else` trees
- State invariants positively
- Zero dependencies policy

### Git Commits

**NEVER add co-author attribution to commits.** Do not include:
- `🤖 Generated with [Claude Code]` messages
- `Co-Authored-By: Claude <noreply@anthropic.com>` trailers

Commit messages should be clean and concise without AI attribution.

## Module System

Modules are defined in `build.zig`:
- `nix` module: Nix parser (`src/parsers/nix-zig/root.zig`)
- Main executables are currently commented out in favor of parser development

## Testing

Test files for the Nix parser follow this structure:
- `test_data/parser/success/*.nix` - files that should parse successfully
- `test_data/parser/error/*.nix` - files that should fail to parse
- `test_data/tokenizer/success/` - tokenizer test cases with `.nix` input and `.expect` output

The test runner (`test_runner.zig`) automatically discovers and runs all test cases, reporting statistics.
