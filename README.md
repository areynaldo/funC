# funC

A projectional programming language: programs are stored as a syntax-independent tree, and each person reads and edits them in the syntax they prefer. Syntaxes are user-defined data files that both parse and print, so switching notation never changes the program.

Written in [Odin](https://odin-lang.org/), with a language server, a VS Code extension and a C89 backend.

## Example

The same program, stored once as [examples/fib.func](examples/fib.func), in two of the seven built-in views:

```text
def fib(n: int) -> int:                    fib (n :: int) -> int = do
    if n < 2:                                  if n < 2 then
        return n                                   return n
    return fib(n - 1) + fib(n - 2)             return fib (n - 1) + fib (n - 2)

def main():                                main = do
    fmt.println("fib(20) =", fib(20))          fmt.println "fib(20) =" (fib 20)
```

Edit either one and the tree changes. Every other view prints from that tree, and `funC c89` compiles it to C.

## Features

- **User-defined syntaxes.** A short `.syntax` file per notation, with one rule per node kind ([c.syntax](syntaxes/c.syntax) documents the format). There are seven built in: the tree form, Odin, C, Lua, Python, Haskell and Lisp.
- **Conversion loses nothing.** The loader checks that every rule uses each field exactly once. Precedence lives in the core, so each syntax gets its parentheses right without spelling them out. Typed blank lines are kept, and lines that don't parse are stored as typed instead of being dropped.
- **A small typed language.** `int`, `bool` and `string`, operators, `if`/`else`, `while` and typed procedures. A checker reports errors in words that read the same in any syntax, such as `adding needs two ints, got an int and a bool`.
- **C89 backend.** The generated C builds with `-std=c89 -pedantic -Wall -Wextra -Werror`.
- **Editor support.** A language server and VS Code extension with:
  - editable views of a `.func` file in any syntax;
  - live diagnostics;
  - semantic highlighting for every syntax, including ones you write;
  - `.syntax` files that reload as you edit them.

## Design

- **Data-oriented core.** Nodes live in flat `#soa` arrays indexed by `u32`, with hot fields (kind, atom, slots) apart from cold ones (spans, flags). Names are interned. Types and highlighting tokens are side tables, not node fields.
- **Arenas.** Each tree owns one arena, and the editor resets it on every keystroke. Temporary work uses a thread-local scratch arena with savepoints.
- **Syntax as data.** One small interpreter both parses and prints from the rules. It backtracks, recovers from errors per line, and ranks what it expected so error messages stay short.

## Quick start

```text
./install.ps1                                  # build everything and install the VS Code extension
bin/funC.exe print examples/fib.func lisp      # print in another syntax
bin/funC.exe check examples/fizzbuzz.func      # parse and type-check
bin/funC.exe c89 examples/fib.func fib.c       # compile to C89
```

In VS Code, reload the window and open a `.func` file. A view opens beside it, and **funC: Switch View Syntax…** changes the syntax. Saving a view writes the tree back to the `.func` file, and the other open views refresh.

## Layout

| Path | |
|---|---|
| [lang/](lang/) | Core: tree, syntax loader, parser, printer, checker, highlighting |
| [syntaxes/](syntaxes/) | Built-in syntaxes, embedded at compile time |
| [backends/c89/](backends/c89/) | C89 code generator |
| [cli/](cli/), [lsp/](lsp/), [editors/vscode/](editors/vscode/) | Command-line tool, language server, VS Code extension |

Tests: `odin test lang`, `odin test backends/c89` and `node lsp/smoke_test.mjs`. The roadmap is in [TODO.md](TODO.md).
