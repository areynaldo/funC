package main

import "core:fmt"
import "core:strings"

Node_Id :: distinct u32

Node_List :: struct {
	start: u32,
	count: u32,
}

Node_Kind :: enum {
	None,
	Unparsed,
	File,
	Import,
	VariableDeclaration,
	FunctionDeclaration,
	Block,
	ExpressionStatement,
	FunctionCall,
	Identifier,
	StringLiteral,
	Selector,
}

Node :: struct {
	kind:     Node_Kind,
	text:     string,
	children: [4]Node_Id,
	list:     Node_List,
}

Tree :: struct {
	nodes: [dynamic]Node,
	lists: [dynamic]Node_Id,
}

tree_init :: proc(tree: ^Tree) {
	append(&tree.nodes, Node{}) // index 0 = none
}

add_node :: proc(tree: ^Tree, node: Node) -> Node_Id {
	append(&tree.nodes, node)
	return Node_Id(len(tree.nodes) - 1)
}

add_list :: proc(tree: ^Tree, items: []Node_Id) -> Node_List {
	start := len(tree.lists)
	append(&tree.lists, ..items)
	return {u32(start), u32(len(items))}
}

list_items :: proc(tree: ^Tree, list: Node_List) -> []Node_Id {
	return tree.lists[int(list.start):][:int(list.count)]
}

Syntax_Part_Kind :: enum {
	Literal,
	Name,
	Quoted,
	Slot,
	SlotList,
	Newline,
	Indent,
	Dedent,
}

Syntax_Part :: struct {
	kind:  Syntax_Part_Kind,
	text:  string,
	slot:  u8,
	allow: bit_set[Node_Kind],
}

EXPRESSION :: bit_set[Node_Kind]{.FunctionCall, .Selector, .Identifier, .StringLiteral}
STATEMENT :: bit_set[Node_Kind]{.VariableDeclaration, .ExpressionStatement}
DECLARATION :: bit_set[Node_Kind]{.Import, .VariableDeclaration, .FunctionDeclaration}

NAME :: Syntax_Part {
	kind = .Name,
}
QUOTED :: Syntax_Part {
	kind = .Quoted,
}
NEWLINE :: Syntax_Part {
	kind = .Newline,
}
INDENT :: Syntax_Part {
	kind = .Indent,
}
DEDENT :: Syntax_Part {
	kind = .Dedent,
}

// File                 text = package,  list = declarations
// Import               text = path
// VariableDeclaration  text = name,     children[0] = value
// FunctionDeclaration  text = name,     children[0] = body
// Block                list = statements
// ExpressionStatement  children[0] = expression
// FunctionCall         children[0] = function, list = arguments
// Selector             text = name,     children[0] = base

Syntax :: struct {
	rules:            [Node_Kind][]Syntax_Part,
	comment:          string,
	indent_sensitive: bool,
}

odin_syntax := Syntax {
	comment = "//",
	rules = #partial [Node_Kind][]Syntax_Part {
		.File = {
			{kind = .Literal, text = "package "},
			NAME,
			{kind = .SlotList, text = "\n", allow = DECLARATION},
		},
		.Import = {{kind = .Literal, text = "import "}, QUOTED},
		.VariableDeclaration = {
			NAME,
			{kind = .Literal, text = " := "},
			{kind = .Slot, slot = 0, allow = EXPRESSION},
		},
		.FunctionDeclaration = {
			NAME,
			{kind = .Literal, text = " :: proc() "},
			{kind = .Slot, slot = 0, allow = {.Block}},
		},
		.Block = {
			{kind = .Literal, text = "{"},
			INDENT,
			{kind = .SlotList, text = "\n", allow = STATEMENT},
			DEDENT,
			NEWLINE,
			{kind = .Literal, text = "}"},
		},
		.ExpressionStatement = {{kind = .Slot, slot = 0, allow = EXPRESSION}},
		.FunctionCall = {
			{kind = .Slot, slot = 0, allow = EXPRESSION},
			{kind = .Literal, text = "("},
			{kind = .SlotList, text = ", ", allow = EXPRESSION},
			{kind = .Literal, text = ")"},
		},
		.Selector = {
			{kind = .Slot, slot = 0, allow = EXPRESSION},
			{kind = .Literal, text = "."},
			NAME,
		},
		.Identifier = {NAME},
		.StringLiteral = {QUOTED},
	},
}

lua_syntax := Syntax {
	comment = "--",
	rules = #partial [Node_Kind][]Syntax_Part {
		.File = {
			{kind = .Literal, text = "module "},
			NAME,
			{kind = .SlotList, text = "\n", allow = DECLARATION},
		},
		.Import = {{kind = .Literal, text = "require "}, QUOTED},
		.VariableDeclaration = {
			{kind = .Literal, text = "local "},
			NAME,
			{kind = .Literal, text = " = "},
			{kind = .Slot, slot = 0, allow = EXPRESSION},
		},
		.FunctionDeclaration = {
			{kind = .Literal, text = "local function "},
			NAME,
			{kind = .Literal, text = "()"},
			{kind = .Slot, slot = 0, allow = {.Block}},
		},
		.Block = {
			INDENT,
			{kind = .SlotList, text = "\n", allow = STATEMENT},
			DEDENT,
			NEWLINE,
			{kind = .Literal, text = "end"},
		},
		.ExpressionStatement = {{kind = .Slot, slot = 0, allow = EXPRESSION}},
		.FunctionCall = {
			{kind = .Slot, slot = 0, allow = EXPRESSION},
			{kind = .Literal, text = "("},
			{kind = .SlotList, text = ", ", allow = EXPRESSION},
			{kind = .Literal, text = ")"},
		},
		.Selector = {
			{kind = .Slot, slot = 0, allow = EXPRESSION},
			{kind = .Literal, text = "."},
			NAME,
		},
		.Identifier = {NAME},
		.StringLiteral = {QUOTED},
	},
}

python_syntax := Syntax {
	comment = "#",
	rules = #partial [Node_Kind][]Syntax_Part {
		.File = {
			{kind = .Literal, text = "package("},
			QUOTED,
			{kind = .Literal, text = ")"},
			{kind = .SlotList, text = "\n", allow = DECLARATION},
		},
		.Import = {{kind = .Literal, text = "import("}, QUOTED, {kind = .Literal, text = ")"}},
		.VariableDeclaration = {
			NAME,
			{kind = .Literal, text = " = "},
			{kind = .Slot, slot = 0, allow = EXPRESSION},
		},
		.FunctionDeclaration = {
			{kind = .Literal, text = "def "},
			NAME,
			{kind = .Literal, text = "()"},
			{kind = .Slot, slot = 0, allow = {.Block}},
		},
		.Block = {
			{kind = .Literal, text = ":"},
			INDENT,
			{kind = .SlotList, text = "\n", allow = STATEMENT},
			DEDENT,
		},
		.ExpressionStatement = {{kind = .Slot, slot = 0, allow = EXPRESSION}},
		.FunctionCall = {
			{kind = .Slot, slot = 0, allow = EXPRESSION},
			{kind = .Literal, text = "("},
			{kind = .SlotList, text = ", ", allow = EXPRESSION},
			{kind = .Literal, text = ")"},
		},
		.Selector = {
			{kind = .Slot, slot = 0, allow = EXPRESSION},
			{kind = .Literal, text = "."},
			NAME,
		},
		.Identifier = {NAME},
		.StringLiteral = {QUOTED},
	},
}

Printer :: struct {
	tree:        ^Tree,
	syntax:      ^Syntax,
	output:      strings.Builder,
	indentation: int,
}

print_tree :: proc(tree: ^Tree, syntax: ^Syntax, root: Node_Id) -> string {
	printer := Printer {
		tree   = tree,
		syntax = syntax,
	}
	print_node(&printer, root)
	return strings.to_string(printer.output)
}

print_newline :: proc(printer: ^Printer) {
	strings.write_byte(&printer.output, '\n')
	for _ in 0 ..< printer.indentation do strings.write_string(&printer.output, "    ")
}

print_node :: proc(printer: ^Printer, node_id: Node_Id) {
	node := printer.tree.nodes[node_id]
	if node.kind == .Unparsed {
		strings.write_string(&printer.output, node.text) // broken text stays as typed
		return
	}
	for part in printer.syntax.rules[node.kind] {
		switch part.kind {
		case .Literal:
			strings.write_string(&printer.output, part.text)
		case .Name:
			strings.write_string(&printer.output, node.text)
		case .Quoted:
			strings.write_byte(&printer.output, '"')
			strings.write_string(&printer.output, node.text)
			strings.write_byte(&printer.output, '"')
		case .Slot:
			print_node(printer, node.children[part.slot])
		case .SlotList:
			for item, item_index in list_items(printer.tree, node.list) {
				if part.text == "\n" do print_newline(printer)
				else if item_index > 0 do strings.write_string(&printer.output, part.text)
				print_node(printer, item)
			}
		case .Newline:
			print_newline(printer)
		case .Indent:
			printer.indentation += 1
		case .Dedent:
			printer.indentation -= 1
		}
	}
}

Diagnostic :: struct {
	position: int,
	message:  string,
}

Parser :: struct {
	tree:          ^Tree,
	syntax:        ^Syntax,
	source:        string,
	position:      int,
	bracket_depth: int, // > 0 inside ", " lists: newlines count as spaces
	indent_column: int, // column of the enclosing statement list
	scratch:       [dynamic]Node_Id,
	fail_position: int,
	fail_what:     string,
	fail_literal:  bool,
	diagnostics:   [dynamic]Diagnostic,
}

Parser_State :: struct {
	position, nodes, lists, scratch, diagnostics: int,
}

save :: proc(parser: ^Parser) -> Parser_State {
	return {
		parser.position,
		len(parser.tree.nodes),
		len(parser.tree.lists),
		len(parser.scratch),
		len(parser.diagnostics),
	}
}

restore :: proc(parser: ^Parser, state: Parser_State) {
	parser.position = state.position
	resize(&parser.tree.nodes, state.nodes)
	resize(&parser.tree.lists, state.lists)
	resize(&parser.scratch, state.scratch)
	resize(&parser.diagnostics, state.diagnostics)
}

// remember the failure that got furthest: that's the error worth showing
fail :: proc(parser: ^Parser, what: string, literal := false) {
	if parser.position >= parser.fail_position {
		parser.fail_position, parser.fail_what, parser.fail_literal =
			parser.position, what, literal
	}
}

// a rule that starts with a slot accepting its own kind (like `$function(...)`) is postfix:
// it's applied after a base expression was parsed, which avoids infinite left recursion
is_postfix :: proc(kind: Node_Kind, rule: []Syntax_Part) -> bool {
	return len(rule) > 0 && rule[0].kind == .Slot && kind in rule[0].allow
}

parse_list :: proc(parser: ^Parser, allow: bit_set[Node_Kind], separator: string) -> Node_List {
	scratch_start := len(parser.scratch)

	if separator == "\n" {
		saved_bracket_depth, saved_column := parser.bracket_depth, parser.indent_column
		parser.bracket_depth = 0
		list_column := -1
		for {
			state := save(parser)
			if !match_newline(parser) do break
			if parser.syntax.indent_sensitive {
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
			parser.fail_position, parser.fail_what = item_start, ""
			item, ok := parse_kinds(parser, allow)
			if ok && !at_line_end(parser) {
				fail(parser, "the end of the line")
				restore(parser, item_state)
				ok = false
			}
			if !ok {
				if parser.fail_position == item_start {restore(parser, state); break}
				item = recover_line(parser, item_start)
			}
			append(&parser.scratch, item)
		}
		parser.bracket_depth, parser.indent_column = saved_bracket_depth, saved_column
	} else {
		parser.bracket_depth += 1
		for {
			state := save(parser)
			if len(parser.scratch) > scratch_start && !match_literal(parser, separator) do break
			item, ok := parse_kinds(parser, allow)
			if !ok {restore(parser, state); break}
			append(&parser.scratch, item)
		}
		parser.bracket_depth -= 1
	}

	list := add_list(parser.tree, parser.scratch[scratch_start:])
	resize(&parser.scratch, scratch_start)
	return list
}

recover_line :: proc(parser: ^Parser, start: int) -> Node_Id {
	message: string
	if parser.fail_literal {
		message = fmt.aprintf("expected `%s`", strings.trim_space(parser.fail_what))
	} else {
		message = fmt.aprintf("expected %s", parser.fail_what)
	}
	append(&parser.diagnostics, Diagnostic{parser.fail_position, message})

	parser.position = start
	for parser.position < len(parser.source) && parser.source[parser.position] != '\n' do parser.position += 1
	return add_node(
		parser.tree,
		Node{kind = .Unparsed, text = parser.source[start:parser.position]},
	)
}

parse_rule :: proc(parser: ^Parser, kind: Node_Kind, first_child: Node_Id) -> (Node_Id, bool) {
	node := Node {
		kind = kind,
	}
	rule := parser.syntax.rules[kind]
	start_index := 0
	if first_child != 0 {
		node.children[rule[0].slot] = first_child
		start_index = 1
	}
	for part in rule[start_index:] {
		ok := true
		switch part.kind {
		case .Literal:
			ok = match_literal(parser, part.text)
		case .Name:
			node.text, ok = read_name(parser)
		case .Quoted:
			node.text, ok = read_quoted(parser)
		case .Slot:
			node.children[part.slot], ok = parse_kinds(parser, part.allow)
		case .SlotList:
			node.list = parse_list(parser, part.allow, part.text)
		case .Newline:
			ok = match_newline(parser)
		case .Indent, .Dedent:
		}
		if !ok do return 0, false
	}
	return add_node(parser.tree, node), true
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
		   (character == '\n' && parser.bracket_depth > 0) {
			parser.position += 1
		} else if len(parser.syntax.comment) > 0 &&
		   strings.has_prefix(parser.source[parser.position:], parser.syntax.comment) {
			for parser.position < len(parser.source) && parser.source[parser.position] != '\n' do parser.position += 1
		} else {
			break
		}
	}
}

match_literal :: proc(parser: ^Parser, text: string) -> bool {
	start := parser.position
	skip_space(parser)
	for index := 0; index < len(text); index += 1 {
		character := text[index]
		if character == ' ' {
			skip_space(parser)
			continue
		}
		if parser.position >= len(parser.source) || parser.source[parser.position] != character {
			parser.position = start
			fail(parser, text, true)
			return false
		}
		parser.position += 1
		word_ends := is_word(character) && (index + 1 == len(text) || !is_word(text[index + 1]))
		if word_ends &&
		   parser.position < len(parser.source) &&
		   is_word(parser.source[parser.position]) {
			parser.position = start // "def" must not match "default"
			fail(parser, text, true)
			return false
		}
	}
	return true
}

match_newline :: proc(parser: ^Parser) -> bool {
	skip_space(parser)
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
	return parser.position >= len(parser.source) || parser.source[parser.position] == '\n'
}

column :: proc(parser: ^Parser) -> int {
	line_start := parser.position
	for line_start > 0 && parser.source[line_start - 1] != '\n' do line_start -= 1
	return parser.position - line_start
}

// words used in literals ("def", "end", "local") can't be names
is_reserved :: proc(syntax: ^Syntax, word: string) -> bool {
	for rule in syntax.rules {
		for part in rule {
			if part.kind != .Literal do continue
			rest := part.text
			for len(rest) > 0 {
				length := 0
				for length < len(rest) && is_word(rest[length]) do length += 1
				if length > 0 && rest[:length] == word do return true
				rest = rest[max(length, 1):]
			}
		}
	}
	return false
}

read_name :: proc(parser: ^Parser) -> (string, bool) {
	skip_space(parser)
	start := parser.position
	for parser.position < len(parser.source) && is_word(parser.source[parser.position]) do parser.position += 1
	name := parser.source[start:parser.position]
	if name == "" || (name[0] >= '0' && name[0] <= '9') || is_reserved(parser.syntax, name) {
		parser.position = start
		fail(parser, "a name")
		return "", false
	}
	return name, true
}

read_quoted :: proc(parser: ^Parser) -> (string, bool) {
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
		parser.position = start
		fail(parser, "\"", true)
		return "", false
	}
	parser.position += 1
	return parser.source[start + 1:parser.position - 1], true
}

parse_kinds :: proc(parser: ^Parser, allow: bit_set[Node_Kind]) -> (Node_Id, bool) {
	result: Node_Id
	found := false
	for kind in allow {
		rule := parser.syntax.rules[kind]
		if len(rule) == 0 || is_postfix(kind, rule) do continue
		state := save(parser)
		if node_id, ok := parse_rule(parser, kind, 0); ok {
			result, found = node_id, true
			break
		}
		restore(parser, state)
	}
	if !found do return 0, false

	for again := true; again; {
		again = false
		for kind in allow {
			if !is_postfix(kind, parser.syntax.rules[kind]) do continue
			state := save(parser)
			if node_id, ok := parse_rule(parser, kind, result); ok {
				result, again = node_id, true
				break
			}
			restore(parser, state)
		}
	}
	return result, true
}

parse :: proc(tree: ^Tree, syntax: ^Syntax, source: string) -> (Node_Id, []Diagnostic) {
	parser := Parser {
		tree          = tree,
		syntax        = syntax,
		source        = source,
		indent_column = -1,
	}
	defer delete(parser.scratch)

	for parser.position < len(source) && strings.is_space(rune(source[parser.position])) do parser.position += 1
	root, ok := parse_rule(&parser, .File, 0)
	if !ok do append(&parser.diagnostics, Diagnostic{parser.fail_position, "expected a file header"})

	for parser.position < len(source) && strings.is_space(rune(source[parser.position])) do parser.position += 1
	if ok && parser.position < len(source) do append(&parser.diagnostics, Diagnostic{parser.position, "expected a declaration"})

	return root, parser.diagnostics[:]
}

print_diagnostic :: proc(source, file_name: string, diagnostic: Diagnostic) {
	line, line_start := 1, 0
	for character, index in source[:diagnostic.position] {
		if character == '\n' {
			line += 1
			line_start = index + 1
		}
	}
	line_end := strings.index_byte(source[line_start:], '\n')
	line_end = line_end < 0 ? len(source) : line_start + line_end
	error_column := diagnostic.position - line_start

	fmt.eprintf("%s:%d:%d: error: %s\n", file_name, line, error_column + 1, diagnostic.message)
	fmt.eprintf("    %s\n    ", source[line_start:line_end])
	for _ in 0 ..< error_column do fmt.eprint(" ")
	fmt.eprintln("^")
}

main :: proc() {
	tree: Tree
	tree_init(&tree)

	odin_source := `package main
import "core:fmt"
main :: proc() {
    fmt.println("Hellope!")
}`
	file, diagnostics := parse(&tree, &odin_syntax, odin_source)
	for diagnostic in diagnostics do print_diagnostic(odin_source, "main.odin", diagnostic)

	lua_source := print_tree(&tree, &lua_syntax, file)
	fmt.println(lua_source)
	fmt.println()

	lua_file, lua_diagnostics := parse(&tree, &lua_syntax, lua_source)
	for diagnostic in lua_diagnostics do print_diagnostic(lua_source, "main.lua", diagnostic)
	python_source := print_tree(&tree, &python_syntax, lua_file)
	fmt.println(python_source)
	fmt.println()

	python_file, python_diagnostics := parse(&tree, &python_syntax, python_source)
	for diagnostic in python_diagnostics do print_diagnostic(python_source, "main.py", diagnostic)
	fmt.println(print_tree(&tree, &odin_syntax, python_file))
	fmt.println()

	broken_source := `package("main")
import("core:fmt")

def main():
    fmt.println("Hellope!"
    fmt.println("still parsed")`
	broken_file, broken_diagnostics := parse(&tree, &python_syntax, broken_source)
	for diagnostic in broken_diagnostics do print_diagnostic(broken_source, "broken.py", diagnostic)
	fmt.println(print_tree(&tree, &lua_syntax, broken_file))
}
