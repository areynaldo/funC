# funC

funC is a small projectional language prototype built around one idea: syntax should not be an excuse to use or avoid a language.

The meaning of a program lives in a syntax-independent tree. A syntax is a user-defined projection of that tree: it describes how nodes are parsed from source and how the same nodes are printed back out. This makes it possible to choose the notation that fits a person, team, domain, or tool without changing the underlying semantics.

## Why

Traditional languages usually bind their semantics to one fixed textual grammar. That creates practical friction:

- Two people may want different notations for the same operation.
- A domain-specific syntax often requires a whole new language implementation.
- Converting between languages usually loses structure or requires fragile text transformations.

funC explores a different boundary. Syntax is a replaceable layer, while the semantic tree remains shared.

## How It Works

The prototype represents programs with nodes such as files, imports, declarations, blocks, calls, selectors, identifiers, and string literals. A `Syntax` maps each node kind to a sequence of parts:

- `Literal` emits fixed text such as `def ` or ` :: proc() `.
- `Name` and `Quoted` read or print node text.
- `Slot` embeds one child node.
- `SlotList` embeds a list of nodes with a separator.
- `Indent`, `Dedent`, and `Newline` describe layout.

Because syntax rules are data, a new syntax can be defined without changing the semantic node model. The parser also reports diagnostics and keeps an unparsed line in the tree when recovery is needed, so a partially broken program can still be projected into another syntax.

## Current Prototype

[`main.odin`](main.odin) currently demonstrates three projections of the same small language:

- Odin-style syntax
- Lua-style syntax
- Python-style syntax

The demo:

1. Parses an Odin program into a shared tree.
2. Prints that tree as Lua.
3. Parses the Lua projection and prints it as Python.
4. Parses the Python projection and prints it back as Odin.
5. Parses a broken Python example, reports diagnostics, and projects the recoverable tree as Lua.

This is an experiment and a foundation for a larger projectional programming system, not yet a complete compiler or editor integration.

## Running

Install the [Odin compiler](https://odin-lang.org/) and run the prototype from the repository root:

```text
odin run .
```

The program prints each projection and any diagnostics produced while parsing the intentionally broken example.

## Direction

Possible next steps include:

- defining syntax rules from source instead of directly in Odin;
- expanding the semantic node model and expression support;
- preserving source positions and comments more precisely;
- adding an editor that projects the same tree into a user-selected syntax;
- validating which transformations are semantic-preserving.

The long-term goal is a language where notation is customizable, semantics are shared, and syntax choice does not decide whether the language is usable.
