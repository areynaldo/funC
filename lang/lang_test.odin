package lang

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"

ODIN_SOURCE :: `package main
import "core:fmt"

main :: proc() {
    fmt.println("Hellope!")
}`

LUA_SOURCE :: `module main
require "core:fmt"

local function main()
    fmt.println("Hellope!")
end`

BROKEN_PYTHON :: `package("main")
import("core:fmt")

def main():
    fmt.println("Hellope!"
    fmt.println("still parsed")`

FUNC_SOURCE :: `(file "main"
    (import "core:fmt")

    (proc "main"
        (block
            (expr (call (select (id "fmt") "println") (str "Hellope!"))))))`

// exercises every field, escapes, empty lists and precedence: calls as callees and arguments
ALL_FEATURES :: `(file "main"
    (import "core:fmt")
    (var "greeting" (str "Hellope!"))

    (proc "hello"
        (block
            (var "name" (id "greeting"))
            (expr (call (select (id "fmt") "println") (id "name") (str "and \"quotes\"")))))

    (proc "main"
        (block
            (expr (call (id "hello")))
            (expr (call (id "f") (call (id "g") (str "x"))))
            (expr (select (call (id "f") (id "x")) "y"))
            (expr (call (call (id "f") (id "x")) (id "y"))))))`

syntax :: proc(name: string) -> ^Syntax {
	found := find_syntax(name)
	assert(found != nil, name)
	return found
}

// printed text goes to the temp allocator, everything else must be freed: the test runner reports leaks

@(test)
test_reprint_is_identity :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	file, diagnostics := parse(&tree, syntax("odin"), ODIN_SOURCE)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, print_tree(&tree, syntax("odin"), file, context.temp_allocator), ODIN_SOURCE)
}

@(test)
test_projection_round_trip :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	file, _ := parse(&tree, syntax("odin"), ODIN_SOURCE)
	lua := print_tree(&tree, syntax("lua"), file, context.temp_allocator)
	testing.expect_value(t, lua, LUA_SOURCE)

	lua_file, lua_diagnostics := parse(&tree, syntax("lua"), lua)
	testing.expect_value(t, len(lua_diagnostics), 0)
	python := print_tree(&tree, syntax("python"), lua_file, context.temp_allocator)

	python_file, python_diagnostics := parse(&tree, syntax("python"), python)
	testing.expect_value(t, len(python_diagnostics), 0)
	testing.expect_value(t, print_tree(&tree, syntax("odin"), python_file, context.temp_allocator), ODIN_SOURCE)
}

@(test)
test_every_syntax_round_trips :: proc(t: ^testing.T) {
	for candidate in syntaxes {
		tree: Tree
		tree_init(&tree)
		defer tree_destroy(&tree)
		file, _ := parse(&tree, syntax("func"), ALL_FEATURES)
		view := print_tree(&tree, candidate, file, context.temp_allocator)

		view_file, view_diagnostics := parse(&tree, candidate, view)
		testing.expectf(t, len(view_diagnostics) == 0, "%s: %v\n%s", candidate.name, len(view_diagnostics) > 0 ? diagnostic_message(view_diagnostics[0]) : "", view)
		testing.expectf(t, print_tree(&tree, syntax("func"), view_file, context.temp_allocator) == ALL_FEATURES, "%s view didn't round-trip:\n%s", candidate.name, view)
	}
}

@(test)
test_haskell_groups_calls :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	file, _ := parse(&tree, syntax("func"), ALL_FEATURES)
	testing.expect_value(t, print_tree(&tree, syntax("haskell"), file, context.temp_allocator), `module main where
import "core:fmt"
greeting = "Hellope!"

hello = do
    name = greeting
    fmt.println name "and \"quotes\""

main = do
    hello ()
    f (g "x")
    (f x).y
    (f x) y`)
}

@(test)
test_broken_line_is_kept :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	file, diagnostics := parse(&tree, syntax("python"), BROKEN_PYTHON)
	if testing.expect_value(t, len(diagnostics), 1) {
		// what would have finished the call, and what was there instead
		testing.expect_value(t, diagnostic_message(diagnostics[0]), "expected `,` or `)`, found the end of the line")
		source := BROKEN_PYTHON
		testing.expect_value(t, source[diagnostics[0].start - 1], '"') // right after "Hellope!"
	}

	unparsed := 0
	for node in tree.nodes do unparsed += int(node.kind == .Unparsed)
	testing.expect_value(t, unparsed, 1)

	lua := print_tree(&tree, syntax("lua"), file, context.temp_allocator)
	testing.expect_value(t, lua, `module main
require "core:fmt"

local function main()
    fmt.println("Hellope!"
    fmt.println("still parsed")
end`)
}

@(test)
test_found_token :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	_, diagnostics := parse(&tree, syntax("odin"), "package main\nmain :: proc() {\n    fmt.println(\"x\" banana)\n}")
	if testing.expect_value(t, len(diagnostics), 1) {
		testing.expect_value(t, diagnostic_message(diagnostics[0]), "expected `,` or `)`, found `banana`")
		testing.expect_value(t, diagnostics[0].end - diagnostics[0].start, 6)
	}
}

@(test)
test_spans :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	_, _ = parse(&tree, syntax("odin"), ODIN_SOURCE)
	source := ODIN_SOURCE
	for node in tree.nodes {
		#partial switch node.kind {
		case .FunctionCall: testing.expect_value(t, source[node.start:node.end], `fmt.println("Hellope!")`)
		case .Selector:     testing.expect_value(t, source[node.start:node.end], "fmt.println")
		case .Import:       testing.expect_value(t, source[node.start:node.end], `import "core:fmt"`)
		}
	}
}

@(test)
test_func_is_canonical :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	file, _ := parse(&tree, syntax("odin"), ODIN_SOURCE)
	testing.expect_value(t, print_tree(&tree, syntax("func"), file, context.temp_allocator), FUNC_SOURCE)

	func_file, func_diagnostics := parse(&tree, syntax("func"), FUNC_SOURCE)
	testing.expect_value(t, len(func_diagnostics), 0)
	testing.expect_value(t, print_tree(&tree, syntax("odin"), func_file, context.temp_allocator), ODIN_SOURCE)
}

@(test)
test_func_layout_is_free :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	file, diagnostics := parse(&tree, syntax("func"), `; hand written
(file "main" (import "core:fmt")
  (proc "main" (block (expr
    (call (select (id "fmt") "println")
          (str "Hellope!"))))
  )
)`)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, print_tree(&tree, syntax("func"), file, context.temp_allocator), FUNC_SOURCE)
}

@(test)
test_func_keeps_unparsed_lines :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	file, _ := parse(&tree, syntax("python"), BROKEN_PYTHON)
	func := print_tree(&tree, syntax("func"), file, context.temp_allocator)
	testing.expect_value(t, func, `(file "main"
    (import "core:fmt")

    (proc "main"
        (block
            (unparsed "fmt.println(\"Hellope!\"")
            (expr (call (select (id "fmt") "println") (str "still parsed"))))))`)

	func_file, func_diagnostics := parse(&tree, syntax("func"), func)
	testing.expect_value(t, len(func_diagnostics), 0)
	python := print_tree(&tree, syntax("python"), func_file, context.temp_allocator)
	testing.expect_value(t, python, `package("main")
import("core:fmt")


def main():
    fmt.println("Hellope!"
    fmt.println("still parsed")`)
}

@(test)
test_python_block_ends_with_indentation :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	file, diagnostics := parse(&tree, syntax("python"), "package(\"main\")\ndef main():\n    hello()\ngreeting := \"hi\"")
	testing.expect_value(t, len(diagnostics), 0)
	// greeting is a file-scope variable, not the last statement of main
	testing.expect_value(t, len(list_items(&tree, tree.nodes[file].slots[0])), 2)
}

@(test)
test_reserved_word_is_not_a_name :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	_, diagnostics := parse(&tree, syntax("lua"), "module main\nlocal function end()\nend")
	testing.expect(t, len(diagnostics) > 0)
}

@(test)
test_clear_and_reparse :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	_, _ = parse(&tree, syntax("odin"), ODIN_SOURCE)
	node_count, atom_count := len(tree.nodes), len(tree.atoms.text)

	tree_reset(&tree)
	file, _ := parse(&tree, syntax("odin"), ODIN_SOURCE)
	testing.expect_value(t, len(tree.nodes), node_count)
	testing.expect_value(t, len(tree.atoms.text), atom_count) // same names, no new atoms
	testing.expect_value(t, print_tree(&tree, syntax("odin"), file, context.temp_allocator), ODIN_SOURCE)
}

// ---- syntax files ----

expect_syntax_errors :: proc(t: ^testing.T, text: string, expected: []string, loc := #caller_location) {
	syntax, diagnostics := new_syntax(text)
	if syntax != nil do syntax_destroy(syntax)
	messages := make([dynamic]string, context.temp_allocator)
	for diagnostic in diagnostics do append(&messages, diagnostic_message(diagnostic))
	for want in expected {
		found := false
		for message in messages do found ||= strings.contains(message, want)
		testing.expectf(t, found, "no error containing %q in %v", want, messages[:], loc = loc)
	}
}

@(test)
test_syntax_file_errors :: proc(t: ^testing.T) {
	expect_syntax_errors(t, `name = broken
extension = .fbr
colour = blue
file = 'package ' package
import = 'import ' path path
call = function!call '(' arguments*', ' ')'
select = base '.' nmae
id = name
str = value:string`, {
		"unknown setting `colour`",
		"the `file` rule doesn't use `declarations`",
		"the `import` rule uses `path` more than once",
		"`select` has no field `nmae`; its fields are base, name",
	})
	expect_syntax_errors(t, `name = x
extension = .fx
if = 'if ' condition ' ' then ' else ' otherwise
return = 'return' [' ' value] [' ' value]
while = ['while '] condition body`, {
		"`otherwise` can be absent: put it inside [ ]",
		"the `return` rule uses `value` more than once",
		"a [ ] group needs a field that can be absent",
	})
	expect_syntax_errors(t, "file = 'package", {"missing `name", "no closing `'`"})
	expect_syntax_errors(t, "name = x\nextension = .fx\nblock = '{' statements '}'", {"`statements` is a list: give it a separator"})
}

@(test)
test_user_syntax :: proc(t: ^testing.T) {
	// a syntax nobody built in: loaded from text, used, and destroyed again
	custom, diagnostics := new_syntax(`name = shouty
extension = .fsh
file   = 'PACKAGE ' package declarations*line
import = 'USE ' path:string
var    = 'LET ' name ' BE ' value
proc   = 'TO ' name [' TAKING ' parameters*' AND '] [' GIVING ' result] body
block  = indent statements*line dedent newline 'DONE'
expr   = 'DO ' expression
call   = function ' WITH ' arguments*' AND '|'NOTHING'
select = base '/' name
id     = name
str    = value:string`)
	for diagnostic in diagnostics do testing.expectf(t, false, "shouty: %s", diagnostic_message(diagnostic))
	if len(diagnostics) > 0 do return
	defer syntax_destroy(custom)

	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	file, _ := parse(&tree, syntax("odin"), ODIN_SOURCE)
	shouty := print_tree(&tree, custom, file, context.temp_allocator)
	testing.expect_value(t, shouty, `PACKAGE main
USE "core:fmt"

TO main
    DO fmt/println WITH "Hellope!"
DONE`)
	back, _ := parse(&tree, custom, shouty)
	testing.expect_value(t, print_tree(&tree, syntax("odin"), back, context.temp_allocator), ODIN_SOURCE)
}

// ---- semantic checks ----

@(test)
test_semantic_errors :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	file, diagnostics := parse(&tree, syntax("odin"), `package main
import "core:fmt"
import "core:os"
main :: proc() {
    fmt.printx("a")
    hello()
    x := "a"
    x()
    main("a")
    fmt.println(main)
    y := main()
    fmt := "shadow"
    fmt.println("b")
}`)
	testing.expect_value(t, len(diagnostics), 0)
	check(&tree, file, &diagnostics)
	expected := []string {
		`unknown package "core:os"`,
		"package `fmt` has no `printx`",
		"`hello` is not defined",
		"`x` is a variable, not a procedure",
		"`main` takes no arguments, got 1",
		"`main` is a procedure, it can't be used as a value",
		"`main` does not return a value",
		"`fmt` is not a package: only packages have members",
	}
	if testing.expect_value(t, len(diagnostics), len(expected)) {
		for want, index in expected do testing.expect_value(t, diagnostic_message(diagnostics[index]), want)
	}
}

@(test)
test_semantic_clean :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	file, diagnostics := parse(&tree, syntax("odin"), CLEAN_PROGRAM)
	check(&tree, file, &diagnostics)
	for diagnostic in diagnostics do testing.expectf(t, false, "unexpected: %s", diagnostic_message(diagnostic))
}

CLEAN_PROGRAM :: `package main
import "core:fmt"
greeting := "Hellope!"
hello :: proc() {
    name := greeting
    fmt.println(name, "and more")
}
main :: proc() {
    hello()
    fmt.print("no newline")
}`

// ---- memory ----

@(test)
test_reset_reuses_memory :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	_, _ = parse(&tree, syntax("func"), ALL_FEATURES)
	used, reserved := tree.arena.total_used, tree.arena.total_reserved
	for _ in 0 ..< 100 {
		tree_reset(&tree)
		_, _ = parse(&tree, syntax("func"), ALL_FEATURES)
	}
	// an editor re-parses on every keystroke: each parse lands in the same memory, nothing accumulates
	testing.expect_value(t, tree.arena.total_used, used)
	testing.expect_value(t, tree.arena.total_reserved, reserved)
}

@(test)
test_scratch_is_released :: proc(t: ^testing.T) {
	scratch := scratch_begin() // make sure the arena exists, so the baseline is real
	scratch_end(scratch)
	before := scratch_arena.total_used

	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	file, diagnostics := parse(&tree, syntax("python"), BROKEN_PYTHON)
	check(&tree, file, &diagnostics)
	_, syntax_diagnostics := new_syntax("name = broken\nfile = 'x' nope")
	testing.expect(t, len(syntax_diagnostics) > 0)
	testing.expect_value(t, scratch_arena.total_used, before)
}

// ---- the language ----

// every construct; generated from an Odin-style source and checked to have no errors
LANGUAGE :: `(file "main"
    (import "core:fmt")
    (var "limit" (int 15))

    (proc "fib" (params (param "n" (type "int"))) (type "int")
        (block
            (if (lt (id "n") (int 2))
                (block
                    (return (id "n"))))
            (return (add (call (id "fib") (sub (id "n") (int 1))) (call (id "fib") (sub (id "n") (int 2)))))))

    (proc "fizzbuzz" (params (param "i" (type "int"))) (type "string")
        (block
            (if (eq (mod (id "i") (int 15)) (int 0))
                (block
                    (return (str "FizzBuzz")))
                (block
                    (if (eq (mod (id "i") (int 3)) (int 0))
                        (block
                            (return (str "Fizz"))))
                    (if (eq (mod (id "i") (int 5)) (int 0))
                        (block
                            (return (str "Buzz"))))
                    (return (str ""))))))

    (proc "main"
        (block
            (var "i" (int 1))
            (while (le (id "i") (id "limit"))
                (block
                    (var "word" (call (id "fizzbuzz") (id "i")))
                    (if (eq (id "word") (str ""))
                        (block
                            (expr (call (select (id "fmt") "println") (id "i"))))
                        (block
                            (expr (call (select (id "fmt") "println") (id "word")))))
                    (assign (id "i") (add (id "i") (int 1)))))
            (expr (call (select (id "fmt") "println") (str "fib(20) =") (call (id "fib") (int 20)) (sub (mul (add (int 2) (int 3)) (int 4)) (neg (int 1))) (or (not (gt (id "i") (int 3))) (id "true")))))))`

@(test)
test_language_round_trips :: proc(t: ^testing.T) {
	for candidate in syntaxes {
		tree: Tree
		tree_init(&tree)
		defer tree_destroy(&tree)
		file, _ := parse(&tree, syntax("func"), LANGUAGE)
		view := print_tree(&tree, candidate, file, context.temp_allocator)
		view_file, view_diagnostics := parse(&tree, candidate, view)
		testing.expectf(t, len(view_diagnostics) == 0, "%s: %v\n%s", candidate.name, len(view_diagnostics) > 0 ? diagnostic_message(view_diagnostics[0]) : "", view)
		testing.expectf(t, print_tree(&tree, syntax("func"), view_file, context.temp_allocator) == LANGUAGE, "%s view didn't round-trip:\n%s", candidate.name, view)
	}
}

@(test)
test_language_checks :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	file, diagnostics := parse(&tree, syntax("func"), LANGUAGE)
	check(&tree, file, &diagnostics)
	for diagnostic in diagnostics do testing.expectf(t, false, "unexpected: %s", diagnostic_message(diagnostic))
}

// precedence is the core's, the parentheses each syntax's: the tree is the same in every view
@(test)
test_precedence :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"a - b - c", "(sub (sub (id \"a\") (id \"b\")) (id \"c\"))"},
		{"a - (b - c)", "(sub (id \"a\") (sub (id \"b\") (id \"c\")))"},
		{"a + b * c", "(add (id \"a\") (mul (id \"b\") (id \"c\")))"},
		{"(a + b) * c", "(mul (add (id \"a\") (id \"b\")) (id \"c\"))"},
		{"-a * b", "(mul (neg (id \"a\")) (id \"b\"))"},
		{"-(a * b)", "(neg (mul (id \"a\") (id \"b\")))"},
		{"a || b && c", "(or (id \"a\") (and (id \"b\") (id \"c\")))"},
		{"a < b == c < d", "(eq (lt (id \"a\") (id \"b\")) (lt (id \"c\") (id \"d\")))"},
		{"f(a + 1).b", "(select (call (id \"f\") (add (id \"a\") (int 1))) \"b\")"},
	}
	for test_case in cases {
		tree: Tree
		tree_init(&tree)
		defer tree_destroy(&tree)
		source := strings.concatenate({"package main\nmain :: proc() {\n    ", test_case[0], "\n}"}, context.temp_allocator)
		file, diagnostics := parse(&tree, syntax("odin"), source)
		testing.expectf(t, len(diagnostics) == 0, "%s: %s", test_case[0], len(diagnostics) > 0 ? diagnostic_message(diagnostics[0]) : "")
		func := print_tree(&tree, syntax("func"), file, context.temp_allocator)
		testing.expectf(t, strings.contains(func, test_case[1]), "%s became\n%s", test_case[0], func)
		// and printing it gives the same text back, parentheses and all
		testing.expectf(t, print_tree(&tree, syntax("odin"), file, context.temp_allocator) == source, "%s printed differently", test_case[0])
	}
}

@(test)
test_type_errors :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	file, diagnostics := parse(&tree, syntax("odin"), `package main
import "core:fmt"
add :: proc(a: int, b: int) -> int {
    if a > b {
        return a
    }
}
main :: proc() {
    x := 1
    x = "one"
    s := "a" + 1
    if x {
        fmt.println(add(1, "2"))
    }
    for 1 < 2 {
        return 3
    }
    true = false
    y := add(1)
    n := 99999999999
}
weird :: proc(q: float) -> bool {
    return 1
}`)
	testing.expect_value(t, len(diagnostics), 0)
	check(&tree, file, &diagnostics)
	expected := []string {
		"unknown type `float`: the types are int, bool and string",
		"`add` must return an int on every path",
		"`x` is an int, it can't be given a string",
		"adding needs two ints, got a string and an int",
		"an `if` condition must be a bool, not an int",
		"argument 2 of `add` must be an int, not a string",
		"`main` doesn't return a value",
		"`true` is a constant, it can't be assigned to",
		"`add` takes 2 arguments, got 1",
		"`99999999999` is too big: an int goes up to 2147483647",
		"`weird` returns a bool, not an int",
	}
	messages := make([dynamic]string, context.temp_allocator)
	for diagnostic in diagnostics do append(&messages, diagnostic_message(diagnostic))
	testing.expectf(t, len(messages) == len(expected), "got %v", messages[:])
	for want, index in expected do if index < len(messages) do testing.expect_value(t, messages[index], want)
}

// ---- blank lines ----

SPACED :: `package main
import "core:fmt"
first := 1

second := 2

main :: proc() {
    a := 1

    b := 2
    fmt.println(a, b)
}`

@(test)
test_blank_lines_are_kept :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	// the blank line before main is spacing, not typed
	file, diagnostics := parse(&tree, syntax("odin"), SPACED)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, print_tree(&tree, syntax("odin"), file, context.temp_allocator), SPACED)

	flagged := 0
	for node in tree.nodes do flagged += int(.Blank_Before in node.flags)
	testing.expect_value(t, flagged, 2) // before `second` and before `b`

	// and every syntax keeps them, so the tree comes back the same
	func := print_tree(&tree, syntax("func"), file, context.temp_allocator)
	for candidate in syntaxes {
		view := print_tree(&tree, candidate, file, context.temp_allocator)
		back, _ := parse(&tree, candidate, view)
		testing.expectf(t, print_tree(&tree, syntax("func"), back, context.temp_allocator) == func, "%s lost a blank line:\n%s", candidate.name, view)
	}
}

@(test)
test_many_blank_lines_become_one :: proc(t: ^testing.T) {
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	many, _ := strings.replace_all(SPACED, "\n\n    b := 2", "\n\n\n\n    b := 2", context.temp_allocator)
	file, _ := parse(&tree, syntax("odin"), many)
	testing.expect_value(t, print_tree(&tree, syntax("odin"), file, context.temp_allocator), SPACED)
}

// ---- highlighting ----

@(test)
test_semantic_tokens :: proc(t: ^testing.T) {
	source := `package main
import "core:fmt"
// says hi
add :: proc(a: int) -> int {
    return a + 1
}

main :: proc() {
    fmt.println(add(2), true)
}`
	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	_, diagnostics := parse(&tree, syntax("odin"), source)
	testing.expect_value(t, len(diagnostics), 0)
	tokens := semantic_tokens(&tree, context.temp_allocator)
	got := make([dynamic]string, context.temp_allocator)
	for token in tokens {
		text := source[token.start:][:token.length]
		append(&got, fmt.tprintf("%s:%v%s", text, token.kind, token.declaration ? "*" : ""))
	}
	want := []string {
		"package:Keyword", "main:Namespace",
		"import:Keyword", `"core:fmt":String`,
		"// says hi:Comment",
		"add:Function*", "proc:Keyword", "a:Parameter*", "int:Type", "int:Type",
		"return:Keyword", "a:Variable", "+:Operator", "1:Number",
		"main:Function*", "proc:Keyword",
		"fmt:Namespace", "println:Function", "add:Function", "2:Number", "true:Keyword",
	}
	testing.expectf(t, slice.equal(got[:], want), "got %v", got[:])
}

@(test)
test_tokens_in_every_syntax :: proc(t: ^testing.T) {
	// every syntax highlights the same program, and its tokens stay inside the text and in order
	for candidate in syntaxes {
		tree: Tree
		tree_init(&tree)
		defer tree_destroy(&tree)
		file, _ := parse(&tree, syntax("func"), LANGUAGE)
		view := print_tree(&tree, candidate, file, context.temp_allocator)
		view_tree: Tree
		tree_init(&view_tree)
		defer tree_destroy(&view_tree)
		_, _ = parse(&view_tree, candidate, view)
		tokens := semantic_tokens(&view_tree, context.temp_allocator)
		functions := 0
		for token, index in tokens {
			testing.expect(t, int(token.start + token.length) <= len(view))
			if index > 0 do testing.expect(t, token.start >= tokens[index - 1].start + tokens[index - 1].length)
			if token.kind == .Function do functions += 1
		}
		// fib, fizzbuzz and main declared; fib twice, fizzbuzz and println three times called
		testing.expectf(t, functions == 10, "%s: %d function tokens", candidate.name, functions)
	}
}
