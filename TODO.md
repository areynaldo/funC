# TODO

The goal is a projectional language: the tree is the source of truth. It can carry many annotations, plugins can change how it renders, and users define their own syntaxes and views.

Guiding rules:

- Store data in flat arrays indexed by `u32`. Keep hot data and cold data in separate columns.
- Invalidate whole chunks (one per top-level declaration) and rebuild them. Don't patch individual nodes.
- Node kinds are a fixed core set. Annotations are how plugins extend the language.
- A **syntax** works in both directions (parse and print) and must not lose information. A **view** is a syntax plus render passes, and only renders.
- Measure before adding more complex incremental machinery.

## 1. Core data layout

- [x] Intern names and literals as `Atom`s. Nodes no longer point into source text.
- [x] Make `Node_Kind` an `enum u8`.
- [x] Use a compact node (`kind`, `atom`, `slots: [2]u32`) stored `#soa`.
- [x] Store lists count-prefixed in `Tree.extra`. Index 0 is the empty list.
- [x] Build the reserved-word set once in `compile_syntax`, not per name.
- [x] Store diagnostics structured (`code`, span, borrowed `name`/`detail`, expectations) and format them only when shown, in `diagnostic_message`.
- [x] Node spans: `start`/`end` fields, which `#soa` stores as their own columns, so hot loops never load them.
- [x] A tree owns one arena (nodes, lists, atoms, diagnostics, and the source via `tree_allocator`), freed with `tree_reset`/`tree_destroy`. The editor resets a document's tree on every edit instead of appending to it.
- [x] A thread-local scratch arena with nesting savepoints (`scratch_begin`/`scratch_end`) for the parser, checker, syntax loader and C89 backend. Nothing in scratch outlives the procedure that began it.
- [ ] One arena per declaration chunk, once chunks exist (step 2): an edit resets one declaration, not the file.

## Tooling

- [x] Split into packages: `lang/` (core), `backends/c89/`, `cli/`, `lsp/`.
- [x] Core tests (`lang/lang_test.odin`) and backend tests (`backends/c89/c89_test.odin`), leak-checked by the test runner.
- [x] LSP server: full sync, parse and semantic diagnostics, `funC/syntaxes`, `funC/convert`, `funC/compile`.
- [x] Node smoke test for the server (`lsp/smoke_test.mjs`), including live `.syntax` reloading.
- [x] `.func` canonical format: s-expressions, as a syntax file (`syntaxes/func.syntax`, layout-free, `(unparsed "…")` for broken lines).
- [x] VS Code extension: `funcview:` virtual views, views listed by the server, **Compile to C89**, `.syntax` files with live diagnostics, `install.ps1`.
- [x] `funC` command-line tool: `check`, `print`, `c89`, `syntaxes`, `--syntaxes <dir>`.
- [ ] Exercise the extension end to end in VS Code (installed, but only the server side is covered by tests).
- [ ] Comments typed in a view are dropped on save until comments become annotations (step 3).
- [x] Semantic tokens: the parser records tokens as it parses (rolled back with the rest of its state), linked to their nodes; names are refined by use (callees, packages, constants). Every syntax is highlighted with no grammar of its own. `.syntax` files get a TextMate grammar.
- [ ] Hover and document symbols, now that nodes have spans.
- [ ] Incremental sync instead of full sync, once declaration chunks exist (step 2).

## 2. Stable identity and declaration chunks

- [ ] Split a file into `[]Decl_Id`, where each declaration owns an immutable `Chunk` (`nodes`, `uid`, `extra`, `spans`).
- [ ] Add a `uid: [dynamic]Node_Uid` column, kept separate from the hot node data.
- [ ] Keep uids across a re-parse: match new nodes to old ones by kind and position in the tree, falling back to sequence alignment.
- [ ] Add a `Symbol_Id` for bindings. `Identifier` stores a symbol, not text, so renaming is one write. The checker's symbol stack is the starting point.
- [ ] Re-bind names to their existing symbols in scope after a text edit.

## 3. Annotation tables

- [ ] Add one `Annotation_Table` per key (`key`, `kind`, `uids`, `values`), sorted by uid.
- [ ] Add a registry where plugins register annotation keys and their value kinds.
- [ ] Step through the annotation tables alongside the node walk instead of looking each node up.
- [ ] Make comments an annotation (`key = "comment"`). Today `skip_space` drops them.

## 4. Syntaxes loaded from files

- [x] A small `key = value` format whose parts map one-to-one onto `Syntax_Part` (`lang/syntax_file.odin`). Built-ins are embedded with `#load_directory`, user files are loaded from directories at runtime, and a name that's taken replaces the old syntax.
- [x] Check syntaxes at load time: unknown settings, kinds and fields, every field used exactly once, optional fields only inside `[ ]` and required ones outside, list separators.
- [x] Groups and per-field precedence: `field!kind` makes a kind need the syntax's group in that place (Haskell's `f (g x)`); the printer adds the group and the parser accepts it.
- [x] Empty-list text (`list*' '|'()'`) for syntaxes where an empty list would be ambiguous.
- [x] Optional parts: `[' else ' otherwise]`, with an absent spelling (`[result ' ' else 'void ']`). The parser backtracks out of a group that parsed but doesn't fit what follows.
- [x] Precedence from the core (`PRECEDENCE`): the loader works out where each syntax needs the group, from which rules are open at either end. Syntax files only spell operators. `group` defaults to `'(' ')'`.
- [x] A kind a syntax doesn't spell falls back to its tree form (`func.syntax`), so a new syntax can start small.
- [x] Longest-match symbols: `<` doesn't match the start of `<-`, `=` not the start of `==`. Words from every written text (absent spellings, separators) are reserved.
- [x] `:number` atoms.
- [x] Blank lines: a `spacing` setting puts blank lines around procedures, and a blank line typed anywhere else is kept (a `Blank_Before` flag, its own SoA column), at most one. A blank line that spacing would print anyway is not recorded, so trees round-trip exactly.
- [ ] Add a `.Annotation` syntax part (a key plus an optional template) that prints the annotation if present and parses it if it appears.
- [ ] Report ambiguous syntaxes at load time: two rules that can start the same way in the same place, or a print that doesn't parse back. A cheap version: print a sample tree and parse it back when loading.
- [ ] Add a lexer pass into SoA tokens (`kind`, `start`, `atom`) so backtracking only resets a token index.
- [ ] Compute first-token sets per kind, so `parse_kinds` dispatches by table lookup instead of trying every kind.
- [ ] Keep the old `column()` value instead of scanning back to the line start on every call.
- [x] A list printed with a separator before every item (`list+' '`), so the `.func` and Lisp forms of a call with no arguments don't end in a space.

## 5. Parser errors

- [x] Collect everything that would have been accepted at the furthest position (`expected`, up to eight), and report what was found there (`expected X or Y, found Z`).
- [x] A failure that had to skip a line break is reported at the end of the line it left.
- [x] Rank expectations: what would only have continued a complete expression (an operator, `(`, `.`) is shown only when nothing else was expected, and can't push a real expectation out of the list.
- [ ] Name the rule that failed (`in this call: expected …`), using the innermost rule that was active at the furthest position.
- [ ] Recover inside a line, not just per line: resynchronize at a closing literal such as `)` and keep the rest of the node.
- [ ] A secondary label pointing at the opening `(` of an unclosed group.

## 6. Semantics

- [x] Name resolution over a flat scope stack (`lang/check.odin`): undefined names, duplicates, unknown packages and members, calling a non-procedure, argument counts, procedures used as values, calls used as values.
- [x] Types (`int`, `bool`, `string`), typed parameters and results, every expression's type in `tree.types`. Errors for operands, conditions, assignments, arguments, returns, and a result missing on some path.
- [ ] Use before declaration at file scope: variables are visible from where they're declared, unlike procedures.
- [ ] Warnings (unused variables and imports) with a severity on `Diagnostic`.
- [ ] Describe packages in data (a `.func` file of declarations) instead of the `KNOWN_PACKAGES` table.

## 7. Backends

- [x] C89 (`backends/c89/`): prototypes first, file-scope initializers inlined down to constant expressions, a nested scope per local variable (C89 has no declarations after statements), every operation parenthesized, `long` for int, `strcmp` for string equality, printing by type, names that collide with C get a `_`. [examples/fizzbuzz.func](examples/fizzbuzz.func) builds with `-std=c89 -pedantic -Wall -Wextra -Werror` and runs.
- [ ] A test that compiles the output with a C compiler when one is on the PATH.
- [ ] A small backend interface (`generate(tree, root, diagnostics) -> text`) once there is a second backend.

## 8. Render output

- [ ] Have the printer emit `Render { text, runs, lines, decorations }`.
- [ ] `runs`: sorted `{offset, node uid, syntax part}`. Cursor to node is a binary search; node to range uses the same table.
- [ ] `lines`: line start offsets, used to convert to LSP line/column (UTF-16 only at the LSP boundary).

## 9. Views and plugins

- [ ] Define `View { syntax, passes, hidden annotation keys }` as data, loadable from a file.
- [ ] Define the plugin pass contract: `proc(chunk, annotations, render)`, which reads flat arrays and only appends decorations.
- [ ] Run passes in a fixed order, batched across all dirty declarations.
- [ ] Cache renders keyed by `(decl, decl_version, annotation_version, view_id)`. The file is the concatenation of cached renders.

## 10. Operations

- [ ] Add a command buffer of `Op { kind, decl, node, arg }`, covering both tree edits and annotation set/remove.
- [ ] Apply a batch, mark the affected declarations dirty, rebuild their chunks, and re-render them.
- [ ] Undo: keep old chunks, plus small undo deltas for the annotation tables.

## 11. LSP

- [x] A canonical format on disk (`.func`). Each projection is a virtual document.
- [ ] `didChange`: map the edit to the declaration whose span covers it, re-lex and re-parse that declaration only, and fall back to the whole file if the edit crosses a declaration boundary.
- [ ] Hover and go-to-definition using `runs` and the checker's symbols.
- [ ] Map decorations onto LSP features: semantic tokens (styles), inlay hints (inline annotations), code lens / code actions (actions), folding ranges (hidden nodes).
- [ ] Formatting is a reprint. Rename and code actions are ops, returned as re-rendered declaration text.

## 12. Later

- [ ] A custom client or VS Code webview for views the LSP can't express (tables, diagrams, widgets).
- [ ] Plugin isolation (DLL, then maybe wasm), once the pass contract has stopped changing.
