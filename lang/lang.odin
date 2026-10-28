package lang

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:unicode/utf8"

Node_Id :: distinct u32

// interned string: names and literals live once in the atom table, nodes never point into source text
Atom :: distinct u32

Atoms :: struct {
	text:   [dynamic]string,
	lookup: map[string]Atom,
}

intern :: proc(atoms: ^Atoms, text: string) -> Atom {
	if atom, ok := atoms.lookup[text]; ok do return atom
	owned := strings.clone(text, atoms.text.allocator) // atoms live as long as the table, not the caller's allocator
	atom := Atom(len(atoms.text))
	append(&atoms.text, owned)
	atoms.lookup[owned] = atom
	return atom
}

// The order matters: where several kinds could start at the same place, the parser takes the first
// that parses, so a kind comes before any kind that would also accept a prefix of it
// (`x = 1` is an assignment before it's the expression `x`)
Node_Kind :: enum u8 {
	None,
	Unparsed,
	File,
	Import,
	VariableDeclaration,
	FunctionDeclaration,
	Parameter,
	Type,
	Block,
	Assignment,
	If,
	While,
	Return,
	ExpressionStatement,
	FunctionCall,
	Selector,
	Or,
	And,
	Equal,
	NotEqual,
	Less,
	LessEqual,
	Greater,
	GreaterEqual,
	Add,
	Subtract,
	Multiply,
	Divide,
	Remainder,
	Negate,
	Not,
	Identifier,
	StringLiteral,
	IntegerLiteral,
}

// stored #soa, so every field is its own array: loops over `kind` and `slots` stay dense
// and never load `start`/`end`, which only diagnostics and the editor read
Node :: struct {
	kind:  Node_Kind,
	atom:  Atom,
	slots: [3]u32, // a child Node_Id, or an index into Tree.extra for a list
	start: u32, // byte range of the source the node was parsed from
	end:   u32,
	flags: bit_set[Node_Flag;u8],
}

Node_Flag :: enum u8 {
	// a blank line separates it from the item before, in a list of one item per line.
	// Only set where a syntax's spacing wouldn't put one there anyway
	Blank_Before,
}

// Everything a tree owns lives in its own arena: nodes, lists, atoms, the diagnostics of its
// parses, and whatever a caller puts there with tree_allocator (like the source text).
// It all goes at once, with tree_reset or tree_destroy; nothing in it is freed one by one.
// The arrays point into tree.arena: don't copy a Tree after tree_init.
Tree :: struct {
	nodes: #soa[dynamic]Node,
	extra: [dynamic]u32, // lists: count followed by that many Node_Ids
	atoms: Atoms,
	types: [dynamic]Type, // per node, filled by check: what each expression evaluates to
	tokens: [dynamic]Token, // what each piece of the parsed text is, for highlighting
	arena: virtual.Arena,
}

tree_init :: proc(tree: ^Tree) {
	if err := virtual.arena_init_growing(&tree.arena); err != nil do panic("out of memory for a tree")
	tree_setup(tree)
}

tree_destroy :: proc(tree: ^Tree) {
	virtual.arena_destroy(&tree.arena)
	tree^ = {}
}

// empty the tree for the next parse of a document. The arena keeps its first block, so
// re-parsing on every keystroke reuses the same memory instead of growing
tree_reset :: proc(tree: ^Tree) {
	virtual.arena_free_all(&tree.arena)
	tree_setup(tree)
}

tree_allocator :: proc(tree: ^Tree) -> runtime.Allocator {
	return virtual.arena_allocator(&tree.arena)
}

@(private)
tree_setup :: proc(tree: ^Tree) {
	allocator := tree_allocator(tree)
	tree.nodes = make_soa(#soa[dynamic]Node, allocator)
	tree.extra = make([dynamic]u32, allocator)
	tree.atoms.text = make([dynamic]string, allocator)
	tree.atoms.lookup = make(map[string]Atom, allocator)
	tree.types = make([dynamic]Type, allocator)
	tree.tokens = make([dynamic]Token, allocator)
	append(&tree.nodes, Node{}) // index 0 = none
	append(&tree.extra, 0) // index 0 = empty list
	intern(&tree.atoms, "") // atom 0 = empty
}

// ---- scratch ----

// Temporary memory for the work inside one call: begin, allocate, end, and it's all gone.
// Savepoints nest like a stack, so a callee can take its own. The one rule: nothing
// allocated in scratch may outlive the procedure that began it (results go to the caller's allocator)
@(thread_local)
scratch_arena: virtual.Arena

Scratch :: struct {
	temp:      virtual.Arena_Temp,
	allocator: runtime.Allocator,
}

scratch_begin :: proc() -> Scratch {
	// a temp that begins before the arena has a block would never be reset
	if scratch_arena.curr_block == nil {
		if err := virtual.arena_init_growing(&scratch_arena); err != nil do panic("out of memory for scratch")
	}
	return {virtual.arena_temp_begin(&scratch_arena), virtual.arena_allocator(&scratch_arena)}
}

scratch_end :: proc(scratch: Scratch) {
	virtual.arena_temp_end(scratch.temp)
}

add_node :: proc(tree: ^Tree, node: Node) -> Node_Id {
	append(&tree.nodes, node)
	return Node_Id(len(tree.nodes) - 1)
}

add_list :: proc(tree: ^Tree, items: []Node_Id) -> u32 {
	if len(items) == 0 do return 0
	start := len(tree.extra)
	append(&tree.extra, u32(len(items)))
	for item in items do append(&tree.extra, u32(item))
	return u32(start)
}

list_items :: proc(tree: ^Tree, list: u32) -> []Node_Id {
	return transmute([]Node_Id)tree.extra[list + 1:][:tree.extra[list]]
}

atom_text :: proc(tree: ^Tree, atom: Atom) -> string {
	return tree.atoms.text[atom]
}

// ---- what each node kind holds ----

BINARY :: bit_set[Node_Kind] {
	.Or, .And, .Equal, .NotEqual, .Less, .LessEqual, .Greater, .GreaterEqual,
	.Add, .Subtract, .Multiply, .Divide, .Remainder,
}
UNARY :: bit_set[Node_Kind]{.Negate, .Not}
EXPRESSION :: BINARY + UNARY + bit_set[Node_Kind]{.FunctionCall, .Selector, .Identifier, .StringLiteral, .IntegerLiteral}
// Unparsed is allowed where whole lines are: syntaxes with an Unparsed rule (like .func) can read it back
STATEMENT :: bit_set[Node_Kind]{.Unparsed, .VariableDeclaration, .Assignment, .If, .While, .Return, .ExpressionStatement}
DECLARATION :: bit_set[Node_Kind]{.Unparsed, .Import, .VariableDeclaration, .FunctionDeclaration}

// how tightly an expression binds, the same in every syntax: `a + b * c` is `a + (b * c)`.
// Syntax files only spell operators; where a syntax needs parentheses follows from this (see compile_syntax)
PRECEDENCE := #partial [Node_Kind]u8 {
	.Or             = 1,
	.And            = 2,
	.Equal          = 3, .NotEqual = 3,
	.Less           = 4, .LessEqual = 4, .Greater = 4, .GreaterEqual = 4,
	.Add            = 5, .Subtract = 5,
	.Multiply       = 6, .Divide = 6, .Remainder = 6,
	.Negate         = 7, .Not = 7,
	.FunctionCall   = 8,
	.Selector       = 9,
	.Identifier     = 10, .StringLiteral = 10, .IntegerLiteral = 10,
}

Type :: enum u8 {
	Invalid, // unknown or wrong: errors about it were reported already, so it's accepted everywhere
	None, // what a call to a procedure without a result gives
	Int,
	Bool,
	String,
}

TYPE_NAMES := [Type]string {
	.Invalid = "an invalid value",
	.None    = "nothing",
	.Int     = "int",
	.Bool    = "bool",
	.String  = "string",
}

Field_Kind :: enum u8 {
	Atom, // the node's text: a name, a path, a string
	Child, // one node, in slots[slot]
	List, // a list in slots[slot]
}

Field :: struct {
	name:     string,
	kind:     Field_Kind,
	slot:     u8,
	allow:    bit_set[Node_Kind],
	optional: bool, // may be absent: a syntax writes it inside [ ]
}

// the names syntax files use for node kinds, and the fields of each.
// A syntax must use every field exactly once, so printing a tree in it and parsing that back loses nothing
KIND_NAMES := [Node_Kind]string {
	.None                = "",
	.Unparsed            = "unparsed",
	.File                = "file",
	.Import              = "import",
	.VariableDeclaration = "var",
	.FunctionDeclaration = "proc",
	.Parameter           = "param",
	.Type                = "type",
	.Block               = "block",
	.Assignment          = "assign",
	.If                  = "if",
	.While               = "while",
	.Return              = "return",
	.ExpressionStatement = "expr",
	.FunctionCall        = "call",
	.Selector            = "select",
	.Or                  = "or",
	.And                 = "and",
	.Equal               = "eq",
	.NotEqual            = "ne",
	.Less                = "lt",
	.LessEqual           = "le",
	.Greater             = "gt",
	.GreaterEqual        = "ge",
	.Add                 = "add",
	.Subtract            = "sub",
	.Multiply            = "mul",
	.Divide              = "div",
	.Remainder           = "mod",
	.Negate              = "neg",
	.Not                 = "not",
	.Identifier          = "id",
	.StringLiteral       = "str",
	.IntegerLiteral      = "int",
}

FIELDS := #partial [Node_Kind][]Field {
	.Unparsed            = {{"text", .Atom, 0, {}, false}},
	.File                = {{"package", .Atom, 0, {}, false}, {"declarations", .List, 0, DECLARATION, false}},
	.Import              = {{"path", .Atom, 0, {}, false}},
	.VariableDeclaration = {{"name", .Atom, 0, {}, false}, {"value", .Child, 0, EXPRESSION, false}},
	.FunctionDeclaration = {
		{"name", .Atom, 0, {}, false},
		{"parameters", .List, 0, {.Parameter}, false},
		{"result", .Child, 2, {.Type}, true},
		{"body", .Child, 1, {.Block}, false},
	},
	.Parameter           = {{"name", .Atom, 0, {}, false}, {"type", .Child, 0, {.Type}, false}},
	.Type                = {{"name", .Atom, 0, {}, false}},
	.Block               = {{"statements", .List, 0, STATEMENT, false}},
	.Assignment          = {{"target", .Child, 0, EXPRESSION, false}, {"value", .Child, 1, EXPRESSION, false}},
	.If                  = {
		{"condition", .Child, 0, EXPRESSION, false},
		{"then", .Child, 1, {.Block}, false},
		{"otherwise", .Child, 2, {.Block}, true},
	},
	.While               = {{"condition", .Child, 0, EXPRESSION, false}, {"body", .Child, 1, {.Block}, false}},
	.Return              = {{"value", .Child, 0, EXPRESSION, true}},
	.ExpressionStatement = {{"expression", .Child, 0, EXPRESSION, false}},
	.FunctionCall        = {{"function", .Child, 0, EXPRESSION, false}, {"arguments", .List, 1, EXPRESSION, false}},
	.Selector            = {{"base", .Child, 0, EXPRESSION, false}, {"name", .Atom, 0, {}, false}},
	.Or                  = {{"left", .Child, 0, EXPRESSION, false}, {"right", .Child, 1, EXPRESSION, false}},
	.And                 = {{"left", .Child, 0, EXPRESSION, false}, {"right", .Child, 1, EXPRESSION, false}},
	.Equal               = {{"left", .Child, 0, EXPRESSION, false}, {"right", .Child, 1, EXPRESSION, false}},
	.NotEqual            = {{"left", .Child, 0, EXPRESSION, false}, {"right", .Child, 1, EXPRESSION, false}},
	.Less                = {{"left", .Child, 0, EXPRESSION, false}, {"right", .Child, 1, EXPRESSION, false}},
	.LessEqual           = {{"left", .Child, 0, EXPRESSION, false}, {"right", .Child, 1, EXPRESSION, false}},
	.Greater             = {{"left", .Child, 0, EXPRESSION, false}, {"right", .Child, 1, EXPRESSION, false}},
	.GreaterEqual        = {{"left", .Child, 0, EXPRESSION, false}, {"right", .Child, 1, EXPRESSION, false}},
	.Add                 = {{"left", .Child, 0, EXPRESSION, false}, {"right", .Child, 1, EXPRESSION, false}},
	.Subtract            = {{"left", .Child, 0, EXPRESSION, false}, {"right", .Child, 1, EXPRESSION, false}},
	.Multiply            = {{"left", .Child, 0, EXPRESSION, false}, {"right", .Child, 1, EXPRESSION, false}},
	.Divide              = {{"left", .Child, 0, EXPRESSION, false}, {"right", .Child, 1, EXPRESSION, false}},
	.Remainder           = {{"left", .Child, 0, EXPRESSION, false}, {"right", .Child, 1, EXPRESSION, false}},
	.Negate              = {{"operand", .Child, 0, EXPRESSION, false}},
	.Not                 = {{"operand", .Child, 0, EXPRESSION, false}},
	.Identifier          = {{"name", .Atom, 0, {}, false}},
	.StringLiteral       = {{"value", .Atom, 0, {}, false}},
	.IntegerLiteral      = {{"value", .Atom, 0, {}, false}},
}

kind_by_name :: proc(name: string) -> (Node_Kind, bool) {
	for kind_name, kind in KIND_NAMES do if kind != .None && kind_name == name do return kind, true
	return .None, false
}

// ---- syntaxes ----

Syntax_Part_Kind :: enum u8 {
	Literal,
	Name,
	Quoted,
	Escaped, // like Quoted, but `"` and `\` inside the text are escaped: for raw text such as Unparsed lines
	Number, // digits
	Slot,
	SlotList,
	Newline,
	Indent,
	Dedent,
	Optional, // the next `length` parts are there when any of the fields in `present` is set
}

Syntax_Part :: struct {
	kind:    Syntax_Part_Kind,
	slot:    u8,
	length:  u8, // Optional: how many of the parts after it belong to it
	present: u8, // Optional: the fields inside it, bit n for slots[n] and bit 3 for the atom
	before:  bool, // SlotList: the separator goes before every item, not between them
	text:    string, // Literal: the text. SlotList: the separator, "\n" for one item per line. Optional: written when absent
	empty:   string, // SlotList: the text that stands for an empty list, if an empty list would be ambiguous
	allow:   bit_set[Node_Kind], // Slot, SlotList: the kinds the field can hold
	bare:    bit_set[Node_Kind], // the subset that can appear without the syntax's group around it
}

PRESENT_ATOM :: 1 << 3

Layout :: enum u8 {
	Lines, // one statement per line, blocks delimited by the rules
	Indent, // like Lines, and a block ends where the indentation does
	Free, // newlines are plain whitespace; Newline parts are optional when parsing
}

Syntax :: struct {
	name:        string,
	title:       string,
	extension:   string,
	comment:     string,
	group_open:  string,
	group_close: string,
	layout:      Layout,
	spacing:     int, // blank lines around each procedure at file level
	rules:       [Node_Kind][]Syntax_Part,
	reserved:    map[string]bool, // words used in literals ("def", "end", "local") can't be names
	symbols:     [dynamic]string, // runs of punctuation used in literals ("<-", "::"), for longest-match
	arena:       virtual.Arena, // everything above is allocated here
}

// ---- diagnostics ----

Diagnostic_Code :: enum u8 {
	Expected, // parse error: `expected` lists what would have been accepted, `name` what was there
	Trailing_Text,
	Undefined_Name,
	Duplicate_Name,
	Unknown_Package,
	Unknown_Member,
	Not_A_Package,
	Not_Callable,
	Not_A_Value,
	No_Value,
	Argument_Count,
	Unknown_Type,
	Reserved_Name,
	Type_Error, // `detail` is the whole message, built by the checker in the tree arena
	Invalid_Syntax, // a syntax file is wrong: `detail` says how
	Unsupported, // a backend can't compile this yet: `detail` says what
}

Expectation :: struct {
	text:         string,
	literal:      bool, // shown in backticks
	// it would only have continued an expression that was already complete, like an operator
	// after `f(x`: shown only when nothing else was expected there
	continuation: bool,
}

// structured, and only turned into text by diagnostic_message when shown.
// Strings are borrowed: from the tree's atoms, the source, or the syntax
Diagnostic :: struct {
	code:           Diagnostic_Code,
	start:          u32,
	end:            u32,
	name:           string,
	detail:         string,
	numbers:        [3]i32, // Argument_Count: least, most (-1 = any), given
	expected:       [8]Expectation,
	expected_count: u8,
}

diagnostic_message :: proc(diagnostic: Diagnostic, allocator := context.temp_allocator) -> string {
	builder := strings.builder_make(allocator)
	switch diagnostic.code {
	case .Expected:
		strings.write_string(&builder, "expected ")
		// what would have finished the code is the point; what could have continued it only if there's nothing else
		expected := diagnostic.expected
		shown := make([dynamic]Expectation, 0, len(expected), allocator)
		for expectation in expected[:diagnostic.expected_count] do if !expectation.continuation do append(&shown, expectation)
		if len(shown) == 0 do for expectation in expected[:diagnostic.expected_count] do append(&shown, expectation)
		count := len(shown)
		if count == 0 do strings.write_string(&builder, "something else")
		for expectation, index in shown {
			if index > 0 do strings.write_string(&builder, index + 1 == count ? " or " : ", ")
			if expectation.literal do fmt.sbprintf(&builder, "`%s`", expectation.text)
			else do strings.write_string(&builder, expectation.text)
		}
		if diagnostic.name != "" do fmt.sbprintf(&builder, ", found `%s`", diagnostic.name)
		else if diagnostic.detail != "" do fmt.sbprintf(&builder, ", found %s", diagnostic.detail)
	case .Trailing_Text:
		fmt.sbprintf(&builder, "expected a declaration, found `%s`", diagnostic.name)
	case .Undefined_Name:
		fmt.sbprintf(&builder, "`%s` is not defined", diagnostic.name)
	case .Duplicate_Name:
		fmt.sbprintf(&builder, "`%s` is already defined here", diagnostic.name)
	case .Unknown_Package:
		fmt.sbprintf(&builder, "unknown package \"%s\"", diagnostic.name)
	case .Unknown_Member:
		fmt.sbprintf(&builder, "package `%s` has no `%s`", diagnostic.name, diagnostic.detail)
	case .Not_A_Package:
		fmt.sbprintf(&builder, "`%s` is not a package: only packages have members", diagnostic.name)
	case .Not_Callable:
		fmt.sbprintf(&builder, "`%s` is %s, not a procedure", diagnostic.name, diagnostic.detail)
	case .Not_A_Value:
		fmt.sbprintf(&builder, "`%s` is %s, it can't be used as a value", diagnostic.name, diagnostic.detail)
	case .No_Value:
		fmt.sbprintf(&builder, "`%s` does not return a value", diagnostic.name)
	case .Argument_Count:
		least, most, given := diagnostic.numbers[0], diagnostic.numbers[1], diagnostic.numbers[2]
		fmt.sbprintf(&builder, "`%s` takes ", diagnostic.name)
		switch {
		case most == 0:     strings.write_string(&builder, "no arguments")
		case most < 0:      fmt.sbprintf(&builder, "at least %d argument%s", least, least == 1 ? "" : "s")
		case least == most: fmt.sbprintf(&builder, "%d argument%s", least, least == 1 ? "" : "s")
		case:               fmt.sbprintf(&builder, "%d to %d arguments", least, most)
		}
		fmt.sbprintf(&builder, ", got %d", given)
	case .Unknown_Type:
		fmt.sbprintf(&builder, "unknown type `%s`: the types are int, bool and string", diagnostic.name)
	case .Reserved_Name:
		fmt.sbprintf(&builder, "`%s` is reserved, pick another name", diagnostic.name)
	case .Type_Error, .Invalid_Syntax, .Unsupported:
		strings.write_string(&builder, diagnostic.detail)
	}
	return strings.to_string(builder)
}

// 1-based line and column of a byte offset, for printing; the LSP does its own (UTF-16) conversion
line_column :: proc(source: string, offset: u32) -> (line, column: int) {
	line, column = 1, 1
	for character in source[:min(int(offset), len(source))] {
		if character == '\n' {
			line, column = line + 1, 1
		} else {
			column += 1
		}
	}
	return
}

// ---- printing ----

Printer :: struct {
	tree:        ^Tree,
	syntax:      ^Syntax,
	output:      strings.Builder,
	indentation: int,
}

print_tree :: proc(tree: ^Tree, syntax: ^Syntax, root: Node_Id, allocator := context.allocator) -> string {
	printer := Printer {
		tree   = tree,
		syntax = syntax,
		output = strings.builder_make(allocator),
	}
	print_node(&printer, root)
	return strings.to_string(printer.output)
}

print_newline :: proc(printer: ^Printer) {
	strings.write_byte(&printer.output, '\n')
	for _ in 0 ..< printer.indentation do strings.write_string(&printer.output, "    ")
}

// a child this syntax can't write bare at this place (like a call as a Haskell argument) gets the group around it
print_child :: proc(printer: ^Printer, part: Syntax_Part, child: Node_Id) {
	kind := printer.tree.nodes[child].kind
	grouped := kind != .None && kind not_in part.bare
	if grouped do strings.write_string(&printer.output, printer.syntax.group_open)
	print_node(printer, child)
	if grouped do strings.write_string(&printer.output, printer.syntax.group_close)
}

// the blank lines a syntax always puts between two items of a line list: around procedures
blank_lines :: proc(syntax: ^Syntax, before, after: Node_Kind) -> int {
	return before == .FunctionDeclaration || after == .FunctionDeclaration ? syntax.spacing : 0
}

// whether some line between two items has nothing on it (a comment line doesn't count)
has_blank_line :: proc(between: string) -> bool {
	first := strings.index_byte(between, '\n')
	if first < 0 do return false
	rest := between[first + 1:]
	for {
		next := strings.index_byte(rest, '\n')
		if next < 0 do return false
		if strings.trim_space(rest[:next]) == "" do return true
		rest = rest[next + 1:]
	}
}

print_node :: proc(printer: ^Printer, node_id: Node_Id) {
	node := printer.tree.nodes[node_id]
	if node.kind == .Unparsed && len(printer.syntax.rules[.Unparsed]) == 0 {
		strings.write_string(&printer.output, atom_text(printer.tree, node.atom)) // broken text stays as typed
		return
	}
	print_parts(printer, node, printer.syntax.rules[node.kind])
}

// whether an Optional group's fields are set on this node
is_present :: proc(node: Node, group: Syntax_Part) -> bool {
	for slot in 0 ..< 3 do if group.present & (1 << uint(slot)) != 0 && node.slots[slot] != 0 do return true
	return group.present & PRESENT_ATOM != 0 && node.atom != 0
}

print_parts :: proc(printer: ^Printer, node: Node, parts: []Syntax_Part) {
	text := atom_text(printer.tree, node.atom)
	for index := 0; index < len(parts); index += 1 {
		part := parts[index]
		switch part.kind {
		case .Literal:
			strings.write_string(&printer.output, part.text)
		case .Name, .Number:
			strings.write_string(&printer.output, text)
		case .Quoted:
			strings.write_byte(&printer.output, '"')
			strings.write_string(&printer.output, text)
			strings.write_byte(&printer.output, '"')
		case .Escaped:
			strings.write_byte(&printer.output, '"')
			for character in transmute([]u8)text {
				if character == '"' || character == '\\' do strings.write_byte(&printer.output, '\\')
				strings.write_byte(&printer.output, character)
			}
			strings.write_byte(&printer.output, '"')
		case .Slot:
			print_child(printer, part, Node_Id(node.slots[part.slot]))
		case .SlotList:
			items := list_items(printer.tree, node.slots[part.slot])
			if len(items) == 0 do strings.write_string(&printer.output, part.empty)
			for item, item_index in items {
				if part.text == "\n" {
					if item_index > 0 {
						blank := blank_lines(printer.syntax, printer.tree.nodes[items[item_index - 1]].kind, printer.tree.nodes[item].kind)
						if blank == 0 && .Blank_Before in printer.tree.nodes[item].flags do blank = 1
						// bare newlines: a blank line has no indentation to trail
						for _ in 0 ..< blank do strings.write_byte(&printer.output, '\n')
					}
					print_newline(printer)
				} else if part.before || item_index > 0 {
					strings.write_string(&printer.output, part.text)
				}
				print_child(printer, part, item)
			}
		case .Newline:
			print_newline(printer)
		case .Indent:
			printer.indentation += 1
		case .Dedent:
			printer.indentation -= 1
		case .Optional:
			group := parts[index + 1:][:part.length]
			if is_present(node, part) do print_parts(printer, node, group)
			else do strings.write_string(&printer.output, part.text)
			index += int(part.length)
		}
	}
}

// ---- parsing ----

Parser :: struct {
	tree:           ^Tree,
	syntax:         ^Syntax,
	source:         string,
	position:       int,
	bracket_depth:  int, // > 0 inside delimited lists like `(a, b)`: newlines count as spaces
	indent_column:  int, // column of the enclosing statement list
	scratch:        [dynamic]Node_Id, // list items being collected, in scratch memory
	temporary:      runtime.Allocator, // scratch, for the rest of the parse's temporaries
	// everything that would have been accepted at the furthest position any rule reached:
	// that's where the real mistake is
	fail_position:  int,
	expected:       [8]Expectation,
	expected_count: u8,
	continue_at:    int, // where an expression could go on with an operator, a call or a member
	diagnostics:    [dynamic]Diagnostic,
}

Parser_State :: struct {
	position, nodes, extra, scratch, diagnostics, tokens: int,
}

// atoms are not rolled back: interning is idempotent, a discarded name just stays in the table
save :: proc(parser: ^Parser) -> Parser_State {
	return {
		parser.position,
		len(parser.tree.nodes),
		len(parser.tree.extra),
		len(parser.scratch),
		len(parser.diagnostics),
		len(parser.tree.tokens),
	}
}

restore :: proc(parser: ^Parser, state: Parser_State) {
	parser.position = state.position
	resize(&parser.tree.nodes, state.nodes)
	resize(&parser.tree.extra, state.extra)
	resize(&parser.scratch, state.scratch)
	resize(&parser.diagnostics, state.diagnostics)
	resize(&parser.tree.tokens, state.tokens)
}

fail :: proc(parser: ^Parser, what: string, literal := false) {
	// a `)` missing at the end of a line is reported there, not where the next line starts
	position := parser.position
	content_end := position
	for content_end > 0 && strings.index_byte(" \t\r\n", parser.source[content_end - 1]) >= 0 do content_end -= 1
	if strings.index_byte(parser.source[content_end:position], '\n') >= 0 do position = content_end

	if position < parser.fail_position do return
	if position > parser.fail_position {
		parser.fail_position = position
		parser.expected_count = 0
	}
	text := literal ? strings.trim_space(what) : what
	if text == "" do return
	continuation := parser.position == parser.continue_at
	for &expectation in parser.expected[:parser.expected_count] {
		if expectation.text == text && expectation.literal == literal {
			expectation.continuation &&= continuation
			return
		}
	}
	if int(parser.expected_count) < len(parser.expected) {
		parser.expected[parser.expected_count] = {text, literal, continuation}
		parser.expected_count += 1
		return
	}
	// full: a real expectation pushes out one that would only have continued
	if !continuation {
		for &expectation in parser.expected do if expectation.continuation {
			expectation = {text, literal, false}
			return
		}
	}
}

// what the source has at `position`, for "expected X, found Y"
found_at :: proc(source: string, position: int) -> (token, description: string) {
	if position >= len(source) do return "", "the end of the file"
	if source[position] == '\n' || source[position] == '\r' do return "", "the end of the line"
	end := position
	if is_word(source[end]) {
		for end < len(source) && is_word(source[end]) do end += 1
	} else {
		_, size := utf8.decode_rune_in_string(source[position:])
		end += size
	}
	return source[position:end], ""
}

expected_diagnostic :: proc(parser: ^Parser) -> Diagnostic {
	token, description := found_at(parser.source, parser.fail_position)
	return {
		code = .Expected,
		start = u32(parser.fail_position),
		end = u32(parser.fail_position + len(token)),
		name = token,
		detail = description,
		expected = parser.expected,
		expected_count = parser.expected_count,
	}
}

// a rule that starts with a slot accepting its own kind (like `$function(...)`) is postfix:
// it's applied after a base expression was parsed, which avoids infinite left recursion
is_postfix :: proc(kind: Node_Kind, rule: []Syntax_Part) -> bool {
	return len(rule) > 0 && rule[0].kind == .Slot && kind in rule[0].allow
}

parse_list :: proc(parser: ^Parser, part: Syntax_Part) -> (list: u32, ok: bool) {
	scratch_start := len(parser.scratch)

	if part.text == "\n" {
		saved_bracket_depth, saved_column := parser.bracket_depth, parser.indent_column
		parser.bracket_depth = 0
		list_column := -1
		for {
			state := save(parser)
			if !match_newline(parser) do break
			if parser.syntax.layout == .Indent {
				current_column := column(parser)
				if list_column < 0 &&
				   current_column <= saved_column {restore(parser, state); break}
				if list_column >= 0 &&
				   current_column != list_column {restore(parser, state); break}
				list_column = current_column
				parser.indent_column = list_column
			}
			item_start := parser.position
			item_state := save(parser)
			parser.fail_position, parser.expected_count = item_start, 0
			item, item_ok := parse_kinds(parser, part.allow, part.bare)
			if item_ok && !at_line_end(parser) {
				fail(parser, "the end of the line")
				restore(parser, item_state)
				item_ok = false
			}
			if !item_ok {
				if parser.fail_position == item_start {restore(parser, state); break}
				item = recover_line(parser, item_start)
			}
			// a blank line the user put there is kept, unless the syntax's spacing puts one there anyway
			if len(parser.scratch) > scratch_start {
				previous := parser.tree.nodes[parser.scratch[len(parser.scratch) - 1]]
				current := &parser.tree.nodes[item]
				if blank_lines(parser.syntax, previous.kind, current.kind) == 0 &&
				   has_blank_line(parser.source[previous.end:item_start]) {
					current.flags += {.Blank_Before}
				}
			}
			append(&parser.scratch, item)
		}
		parser.bracket_depth, parser.indent_column = saved_bracket_depth, saved_column
	} else {
		// `(a,\n b)` can span lines; a list separated only by spaces (`f a b`) ends at the line
		delimited := strings.trim_space(part.text) != ""
		if delimited do parser.bracket_depth += 1
		for {
			state := save(parser)
			if (part.before || len(parser.scratch) > scratch_start) && !match_literal(parser, part.text) do break
			item, item_ok := parse_kinds(parser, part.allow, part.bare)
			if !item_ok {restore(parser, state); break}
			append(&parser.scratch, item)
		}
		if delimited do parser.bracket_depth -= 1
	}

	count := len(parser.scratch) - scratch_start
	list = add_list(parser.tree, parser.scratch[scratch_start:])
	resize(&parser.scratch, scratch_start)
	if count == 0 && part.empty != "" do return 0, match_literal(parser, part.empty)
	return list, true
}

recover_line :: proc(parser: ^Parser, start: int) -> Node_Id {
	append(&parser.diagnostics, expected_diagnostic(parser))
	parser.position = start
	for parser.position < len(parser.source) && parser.source[parser.position] != '\n' do parser.position += 1
	line := strings.trim_right(parser.source[start:parser.position], "\r")
	return add_node(
		parser.tree,
		Node {
			kind = .Unparsed,
			atom = intern(&parser.tree.atoms, line),
			start = u32(start),
			end = u32(start + len(line)),
		},
	)
}

parse_rule :: proc(parser: ^Parser, kind: Node_Kind, first_child: Node_Id) -> (Node_Id, bool) {
	skip_space(parser)
	node := Node {
		kind  = kind,
		start = u32(parser.position),
	}
	rule := parser.syntax.rules[kind]
	start_index := 0
	if first_child != 0 {
		node.slots[rule[0].slot] = u32(first_child)
		node.start = parser.tree.nodes[first_child].start
		start_index = 1
	}
	tokens_start := len(parser.tree.tokens)
	if !parse_parts(parser, &node, rule[start_index:]) do return 0, false
	node.end = u32(parser.position)
	id := add_node(parser.tree, node)
	// the node's own tokens learn its id; its children's already have theirs
	for &token in parser.tree.tokens[tokens_start:] do if token.node == TOKEN_OWNER do token.node = id
	return id, true
}

parse_parts :: proc(parser: ^Parser, node: ^Node, parts: []Syntax_Part) -> bool {
	for index := 0; index < len(parts); index += 1 {
		part := parts[index]
		ok := true
		switch part.kind {
		case .Literal:
			ok = match_literal(parser, part.text, node.kind)
		case .Name, .Quoted, .Escaped, .Number:
			skip_space(parser)
			token_start := parser.position
			#partial switch part.kind {
			case .Name:    node.atom, ok = read_name(parser)
			case .Quoted:  node.atom, ok = read_quoted(parser)
			case .Escaped: node.atom, ok = read_escaped(parser)
			case .Number:  node.atom, ok = read_number(parser)
			}
			if ok {
				kind, declaration := atom_token(node.kind, part.kind)
				record_token(parser, token_start, parser.position, kind, TOKEN_OWNER, declaration)
			}
		case .Slot:
			child: Node_Id
			child, ok = parse_kinds(parser, part.allow, part.bare)
			node.slots[part.slot] = u32(child)
		case .SlotList:
			node.slots[part.slot], ok = parse_list(parser, part)
		case .Newline:
			ok = match_newline(parser)
		case .Indent, .Dedent:
		case .Optional:
			// with the group and then the rest, or else without it: `[result ' ' else 'void ']` reads
			// `int f()` and `void f()`, and a group that parsed can still be wrong for what follows
			group := parts[index + 1:][:part.length]
			rest := parts[index + 1 + int(part.length):]
			state, before := save(parser), node^
			if parse_parts(parser, node, group) && parse_parts(parser, node, rest) do return true
			restore(parser, state)
			node^ = before
			if part.text != "" && !match_literal(parser, part.text) do return false
			return parse_parts(parser, node, rest)
		}
		if !ok do return false
	}
	return true
}

is_word :: proc(character: u8) -> bool {
	return(
		character == '_' ||
		(character >= 'a' && character <= 'z') ||
		(character >= 'A' && character <= 'Z') ||
		(character >= '0' && character <= '9') \
	)
}

skip_space :: proc(parser: ^Parser) {
	for parser.position < len(parser.source) {
		character := parser.source[parser.position]
		if character == ' ' ||
		   character == '\t' ||
		   character == '\r' ||
		   (character == '\n' && (parser.bracket_depth > 0 || parser.syntax.layout == .Free)) {
			parser.position += 1
		} else if len(parser.syntax.comment) > 0 &&
		   strings.has_prefix(parser.source[parser.position:], parser.syntax.comment) {
			comment_start := parser.position
			for parser.position < len(parser.source) && parser.source[parser.position] != '\n' do parser.position += 1
			record_token(parser, comment_start, len(strings.trim_right(parser.source[:parser.position], "\r")), .Comment)
		} else {
			break
		}
	}
}

// spaces, comments and blank lines, whatever the layout: before the file header and after the last declaration
skip_blank :: proc(parser: ^Parser) {
	for {
		skip_space(parser)
		if parser.position >= len(parser.source) || parser.source[parser.position] != '\n' do return
		parser.position += 1
	}
}

// `owner` is the kind of node the literal belongs to: an operator's symbols are highlighted, other punctuation isn't
match_literal :: proc(parser: ^Parser, text: string, owner := Node_Kind.None) -> bool {
	start := parser.position
	skip_space(parser)
	token_start := parser.position
	tokens_before := len(parser.tree.tokens)
	// runs of word or symbol characters matched so far, for highlighting
	run_start, run_end, run_is_word := -1, -1, false
	flush :: proc(parser: ^Parser, run_start, run_end: int, run_is_word: bool, owner: Node_Kind) {
		if run_start < 0 do return
		if run_is_word do record_token(parser, run_start, run_end, .Keyword)
		else if owner in BINARY || owner in UNARY || owner == .Assignment do record_token(parser, run_start, run_end, .Operator)
	}
	for index := 0; index < len(text); index += 1 {
		character := text[index]
		if character == ' ' {
			flush(parser, run_start, run_end, run_is_word, owner)
			run_start = -1
			skip_space(parser)
			continue
		}
		if run_start >= 0 && (parser.position != run_end || is_word(character) != run_is_word) {
			flush(parser, run_start, run_end, run_is_word, owner)
			run_start = -1
		}
		if run_start < 0 do run_start, run_is_word = parser.position, is_word(character)
		run_end = parser.position + 1
		matched := parser.position < len(parser.source) && parser.source[parser.position] == character
		if matched {
			parser.position += 1
			next_is_word := index + 1 < len(text) && is_word(text[index + 1])
			if is_word(character) {
				// "def" must not match "default"
				word_ends := !next_is_word
				matched = !word_ends || parser.position >= len(parser.source) || !is_word(parser.source[parser.position])
			} else if index + 1 == len(text) || text[index + 1] == ' ' || next_is_word {
				// and "<" must not match the start of "<-": a symbol ends where no longer one of the syntax goes on
				symbol_start := index
				for symbol_start > 0 && text[symbol_start - 1] != ' ' && !is_word(text[symbol_start - 1]) do symbol_start -= 1
				symbol := text[symbol_start:index + 1]
				rest := parser.source[parser.position - len(symbol):]
				for longer in parser.syntax.symbols {
					if len(longer) > len(symbol) && strings.has_prefix(longer, symbol) && strings.has_prefix(rest, longer) do matched = false
				}
			}
		}
		if !matched {
			resize(&parser.tree.tokens, tokens_before)
			parser.position = token_start
			fail(parser, text, true)
			parser.position = start
			return false
		}
	}
	flush(parser, run_start, run_end, run_is_word, owner)
	return true
}

match_newline :: proc(parser: ^Parser) -> bool {
	skip_space(parser)
	if parser.syntax.layout == .Free do return true
	if parser.position >= len(parser.source) || parser.source[parser.position] != '\n' {
		fail(parser, "a new line")
		return false
	}
	for parser.position < len(parser.source) && parser.source[parser.position] == '\n' {
		parser.position += 1
		skip_space(parser) // also skips blank and comment-only lines
	}
	return true
}

at_line_end :: proc(parser: ^Parser) -> bool {
	skip_space(parser)
	return(
		parser.syntax.layout == .Free ||
		parser.position >= len(parser.source) ||
		parser.source[parser.position] == '\n' \
	)
}

column :: proc(parser: ^Parser) -> int {
	line_start := parser.position
	for line_start > 0 && parser.source[line_start - 1] != '\n' do line_start -= 1
	return parser.position - line_start
}

read_name :: proc(parser: ^Parser) -> (Atom, bool) {
	skip_space(parser)
	start := parser.position
	for parser.position < len(parser.source) && is_word(parser.source[parser.position]) do parser.position += 1
	name := parser.source[start:parser.position]
	if name == "" || (name[0] >= '0' && name[0] <= '9') || name in parser.syntax.reserved {
		parser.position = start
		fail(parser, "a name")
		return 0, false
	}
	return intern(&parser.tree.atoms, name), true
}

read_number :: proc(parser: ^Parser) -> (Atom, bool) {
	skip_space(parser)
	start := parser.position
	for parser.position < len(parser.source) && parser.source[parser.position] >= '0' && parser.source[parser.position] <= '9' do parser.position += 1
	// `12abc` is not a number followed by a name
	if parser.position == start || (parser.position < len(parser.source) && is_word(parser.source[parser.position])) {
		parser.position = start
		fail(parser, "a number")
		return 0, false
	}
	return intern(&parser.tree.atoms, parser.source[start:parser.position]), true
}

read_quoted :: proc(parser: ^Parser) -> (atom: Atom, ok: bool) {
	text := scan_quoted(parser) or_return
	return intern(&parser.tree.atoms, text), true
}

read_escaped :: proc(parser: ^Parser) -> (atom: Atom, ok: bool) {
	text := scan_quoted(parser) or_return
	unescaped := make([dynamic]u8, 0, len(text), parser.temporary)
	for index := 0; index < len(text); index += 1 {
		if text[index] == '\\' && index + 1 < len(text) do index += 1
		append(&unescaped, text[index])
	}
	return intern(&parser.tree.atoms, string(unescaped[:])), true
}

// the text between the quotes, escapes left as written
scan_quoted :: proc(parser: ^Parser) -> (string, bool) {
	skip_space(parser)
	start := parser.position
	if parser.position >= len(parser.source) || parser.source[parser.position] != '"' {
		fail(parser, "a string")
		return "", false
	}
	parser.position += 1
	for parser.position < len(parser.source) &&
	    parser.source[parser.position] != '"' &&
	    parser.source[parser.position] != '\n' {
		if parser.source[parser.position] == '\\' do parser.position += 1
		parser.position += 1
	}
	if parser.position >= len(parser.source) || parser.source[parser.position] != '"' {
		fail(parser, "\"", true)
		parser.position = start
		return "", false
	}
	parser.position += 1
	return parser.source[start + 1:parser.position - 1], true
}

// one node of any kind in `bare`, or of any kind in `allow` inside the syntax's group
parse_kinds :: proc(parser: ^Parser, allow, bare: bit_set[Node_Kind]) -> (Node_Id, bool) {
	result: Node_Id
	found, grouped := false, false
	for kind in bare {
		rule := parser.syntax.rules[kind]
		if len(rule) == 0 || is_postfix(kind, rule) do continue
		state := save(parser)
		if node_id, ok := parse_rule(parser, kind, 0); ok {
			result, found = node_id, true
			break
		}
		restore(parser, state)
	}
	if !found && parser.syntax.group_open != "" {
		state := save(parser)
		if match_literal(parser, parser.syntax.group_open) {
			inner, ok := parse_kinds(parser, allow, allow)
			if ok && match_literal(parser, parser.syntax.group_close) {
				result, found, grouped = inner, true, true
			}
		}
		if !found do restore(parser, state)
	}
	if !found do return 0, false

	for again := true; again; {
		again = false
		for kind in bare {
			rule := parser.syntax.rules[kind]
			if !is_postfix(kind, rule) do continue
			// `f x` is not a callee in Haskell, but `(f x)` is
			base_kind := parser.tree.nodes[result].kind
			if base_kind not_in (grouped ? rule[0].allow : rule[0].bare) do continue
			state := save(parser)
			skip_space(parser)
			before := parser.position
			saved_continue_at := parser.continue_at
			parser.continue_at = before
			// a postfix rule that consumed nothing would apply forever
			node_id, ok := parse_rule(parser, kind, result)
			parser.continue_at = saved_continue_at
			if ok && parser.position > before {
				result, again, grouped = node_id, true, false
				break
			}
			restore(parser, state)
		}
	}
	return result, true
}

// Parses into the tree, after whatever it already holds. The diagnostics live in the tree's arena
// and their strings borrow from `source`: keep the source alive as long as them (tree_allocator is a
// good place for it). Nothing to free: tree_reset or tree_destroy takes everything
parse :: proc(tree: ^Tree, syntax: ^Syntax, source: string) -> (Node_Id, [dynamic]Diagnostic) {
	scratch := scratch_begin()
	defer scratch_end(scratch)
	parser := Parser {
		tree          = tree,
		syntax        = syntax,
		source        = source,
		indent_column = -1,
		continue_at   = -1,
		scratch       = make([dynamic]Node_Id, 0, 64, scratch.allocator),
		temporary     = scratch.allocator,
		diagnostics   = make([dynamic]Diagnostic, tree_allocator(tree)),
	}
	// growing an array in an arena copies it, so make room for the whole parse up front:
	// roughly one node per 4 bytes of source, one list entry per 8
	reserve_soa(&tree.nodes, len(tree.nodes) + len(source) / 4 + 16)
	reserve(&tree.extra, len(tree.extra) + len(source) / 8 + 16)

	skip_blank(&parser)
	root, ok := parse_rule(&parser, .File, 0)
	// a line that failed inside already says why
	if !ok && len(parser.diagnostics) == 0 do append(&parser.diagnostics, expected_diagnostic(&parser))

	skip_blank(&parser)
	if ok && parser.position < len(source) {
		token, _ := found_at(source, parser.position)
		append(&parser.diagnostics, Diagnostic{code = .Trailing_Text, start = u32(parser.position), end = u32(parser.position + len(token)), name = token})
	}
	return root, parser.diagnostics
}
