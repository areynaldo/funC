// funC command line: check, convert and compile .func files (or views, by their extension).
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

import "../backends/c89"
import "../lang"

USAGE :: `usage: funC <command> [--syntaxes <dir>]... <arguments>

commands:
  check <file>                  parse and check, print diagnostics
  print <file> <syntax>         print the program in another syntax
  highlight <file> <syntax>     the same, as JSON with the highlighting tokens: {text, tokens: [{start, length, kind}]}
  c89 <file> [<output.c>]       compile to C89 (stdout without an output file)
  syntaxes                      list the available syntaxes

<file> is a .func file or a view (hello.func.fpy, hello.fc, ...): its extension picks the syntax.
--syntaxes loads every .syntax file in a directory; a name that's taken replaces the built-in.
`

print_diagnostics :: proc(path, source: string, diagnostics: []lang.Diagnostic) {
	for diagnostic in diagnostics {
		line, column := lang.line_column(source, diagnostic.start)
		fmt.eprintf("%s:%d:%d: error: %s\n", path, line, column, lang.diagnostic_message(diagnostic))
		line_start := int(diagnostic.start) - (column - 1)
		line_end := strings.index_byte(source[line_start:], '\n')
		line_end = line_end < 0 ? len(source) : line_start + line_end
		fmt.eprintf("    %s\n    ", strings.trim_right(source[line_start:line_end], "\r"))
		for _ in 1 ..< column do fmt.eprint(" ")
		width := max(1, int(diagnostic.end) - int(diagnostic.start))
		for _ in 0 ..< min(width, line_end - int(diagnostic.start) + 1) do fmt.eprint("^")
		fmt.eprintln()
	}
}

report_syntax_file :: proc(path, text: string, diagnostics: []lang.Diagnostic) {
	print_diagnostics(path, text, diagnostics)
}

Highlight_Token :: struct {
	start, length: u32,
	kind:          string,
}

highlight_tokens :: proc(tree: ^lang.Tree) -> []Highlight_Token {
	tokens := lang.semantic_tokens(tree, context.allocator)
	result := make([]Highlight_Token, len(tokens))
	for token, index in tokens do result[index] = {token.start, token.length, fmt.aprint(token.kind)}
	return result
}

// parse and check; false (and diagnostics printed) when there are errors
load_program :: proc(path: string, tree: ^lang.Tree) -> (root: lang.Node_Id, source: string, ok: bool) {
	// the source lives with the tree, as long as the diagnostics that point into it
	data, err := os.read_entire_file_from_path(path, lang.tree_allocator(tree))
	if err != nil {
		fmt.eprintf("funC: cannot read %s: %v\n", path, err)
		return 0, "", false
	}
	source = string(data)
	syntax := lang.find_syntax_for_path(path)
	if syntax == nil do syntax = lang.find_syntax("func")
	diagnostics: [dynamic]lang.Diagnostic
	root, diagnostics = lang.parse(tree, syntax, source)
	lang.check(tree, root, &diagnostics)
	print_diagnostics(path, source, diagnostics[:])
	return root, source, root != 0 && len(diagnostics) == 0
}

main :: proc() {
	arguments := make([dynamic]string)
	for index := 1; index < len(os.args); index += 1 {
		if os.args[index] == "--syntaxes" && index + 1 < len(os.args) {
			lang.load_syntax_directory(os.args[index + 1], report_syntax_file)
			index += 1
			continue
		}
		append(&arguments, os.args[index])
	}
	if len(arguments) == 0 {
		fmt.eprint(USAGE)
		os.exit(2)
	}

	tree: lang.Tree
	lang.tree_init(&tree)
	switch arguments[0] {
	case "check":
		if len(arguments) != 2 do break
		_, _, ok := load_program(arguments[1], &tree)
		os.exit(ok ? 0 : 1)

	case "print":
		if len(arguments) != 3 do break
		syntax := lang.find_syntax(arguments[2])
		if syntax == nil {
			fmt.eprintf("funC: no syntax named %s, see `funC syntaxes`\n", arguments[2])
			os.exit(2)
		}
		root, _, ok := load_program(arguments[1], &tree)
		if root == 0 do os.exit(1)
		fmt.println(lang.print_tree(&tree, syntax, root))
		os.exit(ok ? 0 : 1)

	case "c89":
		if len(arguments) != 2 && len(arguments) != 3 do break
		root, source, ok := load_program(arguments[1], &tree)
		if !ok do os.exit(1)
		diagnostics: [dynamic]lang.Diagnostic
		output := c89.generate(&tree, root, &diagnostics)
		if len(diagnostics) > 0 {
			print_diagnostics(arguments[1], source, diagnostics[:])
			os.exit(1)
		}
		if len(arguments) == 2 {
			fmt.print(output)
		} else if err := os.write_entire_file_from_string(arguments[2], output); err != nil {
			fmt.eprintf("funC: cannot write %s: %v\n", arguments[2], err)
			os.exit(1)
		}
		os.exit(0)

	case "highlight":
		if len(arguments) != 3 do break
		syntax := lang.find_syntax(arguments[2])
		if syntax == nil {
			fmt.eprintf("funC: no syntax named %s, see `funC syntaxes`\n", arguments[2])
			os.exit(2)
		}
		root, _, _ := load_program(arguments[1], &tree)
		if root == 0 do os.exit(1)
		// tokens come from parsing the printed text, as an editor showing the view would
		text := lang.print_tree(&tree, syntax, root)
		view: lang.Tree
		lang.tree_init(&view)
		lang.parse(&view, syntax, text)
		output := struct {
			text:   string,
			tokens: []Highlight_Token,
		}{text, highlight_tokens(&view)}
		data, err := json.marshal(output)
		if err != nil {
			fmt.eprintln("funC: cannot encode:", err)
			os.exit(1)
		}
		fmt.println(string(data))
		os.exit(0)

	case "syntaxes":
		for syntax in lang.syntaxes do fmt.printf("%-10s %-8s %s\n", syntax.name, syntax.extension, syntax.title)
		os.exit(0)
	}
	fmt.eprint(USAGE)
	os.exit(2)
}
