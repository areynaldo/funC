// Syntax files: `key = value` lines. Settings configure the syntax, and each rule says how one
// node kind is written. The format is documented at the top of syntaxes/c.syntax.
package lang

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"

Rule_Token_Kind :: enum u8 {
	Word,
	Literal,
	Colon,
	Star,
	Bang,
	Bar,
	Plus,
	Open_Bracket,
	Close_Bracket,
}

Rule_Token :: struct {
	kind:       Rule_Token_Kind,
	text:       string, // Literal: unescaped
	start, end: int, // in the file
}

Syntax_Loader :: struct {
	syntax:      ^Syntax,
	source:      string,
	arena:       runtime.Allocator, // the syntax's own: what the syntax keeps
	temporary:   runtime.Allocator, // scratch: what loading needs only while it runs
	output:      runtime.Allocator, // the caller's: diagnostics and their messages
	diagnostics: [dynamic]Diagnostic,
}

loader_error :: proc(loader: ^Syntax_Loader, start, end: int, format: string, args: ..any) {
	append(
		&loader.diagnostics,
		Diagnostic{code = .Invalid_Syntax, start = u32(start), end = u32(end), detail = fmt.aprintf(format, ..args, allocator = loader.output)},
	)
}

// On success the syntax is compiled and ready; on errors it's incomplete and should be destroyed.
// The diagnostics and their messages are allocated with `allocator`
load_syntax :: proc(syntax: ^Syntax, text: string, allocator := context.temp_allocator) -> [dynamic]Diagnostic {
	scratch := scratch_begin()
	defer scratch_end(scratch)
	loader := Syntax_Loader {
		syntax      = syntax,
		temporary   = scratch.allocator,
		output      = allocator,
		diagnostics = make([dynamic]Diagnostic, allocator),
	}
	if virtual.arena_init_growing(&syntax.arena) != nil {
		loader_error(&loader, 0, 0, "out of memory")
		return loader.diagnostics
	}
	loader.arena = virtual.arena_allocator(&syntax.arena)
	loader.source = strings.clone(text, loader.arena)
	syntax.reserved = make(map[string]bool, loader.arena)
	syntax.spacing = 1

	defined: bit_set[Node_Kind]
	for line_start := 0; line_start < len(loader.source); {
		line_end := strings.index_byte(loader.source[line_start:], '\n')
		line_end = line_end < 0 ? len(loader.source) : line_start + line_end
		load_line(&loader, line_start, line_end, &defined)
		line_start = line_end + 1
	}

	if syntax.name == "" do loader_error(&loader, 0, 0, "missing `name = ...`")
	if syntax.extension == "" do loader_error(&loader, 0, 0, "missing `extension = ...`, e.g. `extension = .fmy`")
	if syntax.title == "" do syntax.title = syntax.name
	// a kind the file doesn't spell is written the way the tree is: `(while (lt (id "i") (int 3)) ...)`.
	// Those rules are delimited at both ends, so they read back in any syntax
	tree_form := find_syntax("func")
	for fields, kind in FIELDS {
		if kind == .Unparsed || len(fields) == 0 || kind in defined do continue
		if tree_form != nil && tree_form != syntax && syntax.name != "func" {
			syntax.rules[kind] = clone_parts(tree_form.rules[kind], loader.arena)
		} else {
			loader_error(&loader, 0, 0, "missing a rule for `%s`: the tree form needs every kind", KIND_NAMES[kind])
		}
	}
	// what precedence or a `!` wraps children in, unless the file says otherwise
	if syntax.group_open == "" do syntax.group_open, syntax.group_close = "(", ")"
	if len(loader.diagnostics) == 0 do apply_precedence(&loader)
	if len(loader.diagnostics) == 0 do compile_syntax(syntax)
	return loader.diagnostics
}

clone_parts :: proc(parts: []Syntax_Part, allocator: runtime.Allocator) -> []Syntax_Part {
	copied := make([]Syntax_Part, len(parts), allocator)
	for part, index in parts {
		copied[index] = part
		copied[index].text = strings.clone(part.text, allocator)
		copied[index].empty = strings.clone(part.empty, allocator)
	}
	return copied
}

// the first or last part that writes something, skipping layout
edge_part :: proc(rule: []Syntax_Part, last: bool) -> (index: int, ok: bool) {
	for step in 0 ..< len(rule) {
		index = last ? len(rule) - 1 - step : step
		if rule[index].kind != .Indent && rule[index].kind != .Dedent do return index, true
	}
	return 0, false
}

is_open :: proc(part: Syntax_Part) -> bool {
	return part.kind == .Slot || part.kind == .SlotList || part.kind == .Optional
}

// Where a child expression needs the group around it, worked out from PRECEDENCE.
// It only matters at the open ends of a rule: in `left ' + ' right`, a child that is itself open
// on the facing side would swallow or be swallowed by the operator. `(a or b) + c` keeps its group
// because `or` binds looser than `+`; `a - (b - c)` keeps it because operators group to the left.
// A child delimited on that side, like Lisp's `(+ a b)`, never needs one
apply_precedence :: proc(loader: ^Syntax_Loader) {
	syntax := loader.syntax
	open_start, open_end: bit_set[Node_Kind]
	for rule, kind in syntax.rules {
		if first, ok := edge_part(rule, false); ok && is_open(rule[first]) do open_start += {kind}
		if last, ok := edge_part(rule, true); ok && is_open(rule[last]) do open_end += {kind}
	}
	for &rule, kind in syntax.rules {
		precedence := PRECEDENCE[kind]
		if precedence == 0 do continue
		first, has_first := edge_part(rule, false)
		last, has_last := edge_part(rule, true)
		for child in EXPRESSION {
			child_precedence := PRECEDENCE[child]
			if has_first && (rule[first].kind == .Slot || rule[first].kind == .SlotList) && child in open_end && child_precedence < precedence {
				rule[first].bare -= {child}
			}
			if has_last && (rule[last].kind == .Slot || rule[last].kind == .SlotList) && child in open_start && child_precedence <= precedence {
				rule[last].bare -= {child}
			}
		}
	}
}

// precompute what the parser's hot loop needs from the rules
compile_syntax :: proc(syntax: ^Syntax) {
	// words the syntax writes itself ("def", "end", "local", a separator's "and", an absent
	// result's "void") can't be names
	// and its runs of punctuation are tokens: `<` doesn't match the start of `<-`
	reserve :: proc(syntax: ^Syntax, text: string) {
		for rest := text; len(rest) > 0; {
			length := 0
			if is_word(rest[0]) {
				for length < len(rest) && is_word(rest[length]) do length += 1
				syntax.reserved[rest[:length]] = true
			} else if rest[0] != ' ' {
				for length < len(rest) && rest[length] != ' ' && !is_word(rest[length]) do length += 1
				symbol := rest[:length]
				known := false
				for existing in syntax.symbols do known ||= existing == symbol
				if !known do append(&syntax.symbols, symbol)
			}
			rest = rest[max(length, 1):]
		}
	}
	syntax.symbols = make([dynamic]string, virtual.arena_allocator(&syntax.arena))
	reserve(syntax, syntax.group_open)
	reserve(syntax, syntax.group_close)
	for rule in syntax.rules {
		for part in rule {
			#partial switch part.kind {
			case .Literal, .Optional: reserve(syntax, part.text)
			case .SlotList:           reserve(syntax, part.text); reserve(syntax, part.empty)
			}
		}
	}
}

load_line :: proc(loader: ^Syntax_Loader, line_start, line_end: int, defined: ^bit_set[Node_Kind]) {
	line := strings.trim_right(loader.source[line_start:line_end], "\r")
	content := strings.trim_space(line)
	if content == "" || content[0] == '#' do return
	equals := strings.index_byte(line, '=')
	if equals < 0 {
		loader_error(loader, line_start, line_start + len(line), "expected `setting = value` or `kind = parts...`")
		return
	}
	key := strings.trim_space(line[:equals])
	key_start := line_start + strings.index(line, key)
	value_start := line_start + equals + 1
	value := strings.trim_space(line[equals + 1:])

	if kind, is_kind := kind_by_name(key); is_kind {
		if kind in defined^ {
			loader_error(loader, key_start, key_start + len(key), "second rule for `%s`", key)
			return
		}
		defined^ += {kind}
		tokens, ok := tokenize_rule(loader, value_start, line_start + len(line))
		if ok do loader.syntax.rules[kind] = load_rule(loader, kind, tokens, key_start, key_start + len(key))
		return
	}

	syntax := loader.syntax
	switch key {
	case "name":
		syntax.name = value
	case "title":
		syntax.title = value
	case "extension":
		if len(value) < 2 || value[0] != '.' do loader_error(loader, value_start, line_start + len(line), "an extension starts with a dot, like `.fmy`")
		syntax.extension = value
	case "comment":
		syntax.comment = value
	case "spacing":
		lines, ok := strconv.parse_int(value)
		if !ok || lines < 0 || lines > 3 {
			loader_error(loader, value_start, line_start + len(line), "spacing is how many blank lines go around a procedure: 0 to 3")
			return
		}
		syntax.spacing = lines
	case "layout":
		switch value {
		case "lines":  syntax.layout = .Lines
		case "indent": syntax.layout = .Indent
		case "free":   syntax.layout = .Free
		case:          loader_error(loader, value_start, line_start + len(line), "layout is `lines`, `indent` or `free`")
		}
	case "group":
		tokens, ok := tokenize_rule(loader, value_start, line_start + len(line))
		if !ok do return
		if len(tokens) != 2 || tokens[0].kind != .Literal || tokens[1].kind != .Literal {
			loader_error(loader, value_start, line_start + len(line), "group is two literals, like `group = '(' ')'`")
			return
		}
		syntax.group_open, syntax.group_close = tokens[0].text, tokens[1].text
	case:
		kinds := make([dynamic]string, 0, len(Node_Kind), loader.temporary)
		for name, kind in KIND_NAMES do if kind != .None do append(&kinds, name)
		loader_error(
			loader,
			key_start,
			key_start + len(key),
			"unknown setting `%s`: settings are name, title, extension, comment, layout, spacing and group, and rules are named after node kinds (%s)",
			key,
			strings.join(kinds[:], ", ", loader.temporary),
		)
	}
}

tokenize_rule :: proc(loader: ^Syntax_Loader, start, end: int) -> (tokens: [dynamic]Rule_Token, ok: bool) {
	tokens = make([dynamic]Rule_Token, 0, 16, loader.temporary)
	source := loader.source
	for position := start; position < end; {
		character := source[position]
		switch {
		case character == ' ' || character == '\t':
			position += 1
		case character == '\'':
			// 'literal', with \' and \\
			builder := strings.builder_make(loader.arena)
			cursor := position + 1
			closed := false
			for cursor < end {
				if source[cursor] == '\'' {closed = true; break}
				if source[cursor] == '\\' && cursor + 1 < end && (source[cursor + 1] == '\'' || source[cursor + 1] == '\\') do cursor += 1
				strings.write_byte(&builder, source[cursor])
				cursor += 1
			}
			if !closed {
				loader_error(loader, position, end, "this literal has no closing `'`")
				return tokens, false
			}
			append(&tokens, Rule_Token{.Literal, strings.to_string(builder), position, cursor + 1})
			position = cursor + 1
		case is_word(character):
			word_end := position
			for word_end < end && is_word(source[word_end]) do word_end += 1
			append(&tokens, Rule_Token{.Word, source[position:word_end], position, word_end})
			position = word_end
		case strings.index_byte(":*!|+[]", character) >= 0:
			kind: Rule_Token_Kind
			switch character {
			case ':': kind = .Colon
			case '*': kind = .Star
			case '!': kind = .Bang
			case '|': kind = .Bar
			case '+': kind = .Plus
			case '[': kind = .Open_Bracket
			case ']': kind = .Close_Bracket
			}
			append(&tokens, Rule_Token{kind, source[position:position + 1], position, position + 1})
			position += 1
		case:
			loader_error(loader, position, position + 1, "unexpected `%c`: literal text goes in single quotes, like '%c'", character, character)
			return tokens, false
		}
	}
	return tokens, true
}

load_rule :: proc(loader: ^Syntax_Loader, kind: Node_Kind, tokens: [dynamic]Rule_Token, key_start, key_end: int) -> []Syntax_Part {
	parts := make([dynamic]Syntax_Part, loader.arena)
	fields := FIELDS[kind]
	uses: [4]int
	// the Optional parts of the [ ] groups we're inside, innermost last
	groups := make([dynamic]int, 0, 4, loader.temporary)
	for index := 0; index < len(tokens); index += 1 {
		token := tokens[index]
		#partial switch token.kind {
		case .Literal:
			if token.text == "" {
				loader_error(loader, token.start, token.end, "empty literal")
				continue
			}
			append(&parts, Syntax_Part{kind = .Literal, text = token.text})
			continue
		case .Open_Bracket:
			append(&groups, len(parts))
			append(&parts, Syntax_Part{kind = .Optional})
			continue
		case .Close_Bracket:
			if len(groups) == 0 {
				loader_error(loader, token.start, token.end, "`]` without a `[`")
				continue
			}
			start := pop(&groups)
			parts[start].length = u8(len(parts) - start - 1)
			// it's printed when one of its fields is set: without any, it would never be
			if parts[start].present == 0 do loader_error(loader, token.start, token.end, "a [ ] group needs a field that can be absent, like `otherwise` or `result`")
			continue
		case .Word:
		case:
			loader_error(loader, token.start, token.end, "`%s` must follow a field name", token.text)
			continue
		}

		// `[result ' ' else 'void ']`: what to write when the group's fields are absent
		if token.text == "else" && len(groups) > 0 {
			group := &parts[groups[len(groups) - 1]]
			if index + 2 >= len(tokens) || tokens[index + 1].kind != .Literal || tokens[index + 2].kind != .Close_Bracket {
				loader_error(loader, token.start, token.end, "`else` ends a group: `[' -> ' result else ' ']`")
				continue
			}
			group.text = tokens[index + 1].text
			index += 1
			continue
		}

		switch token.text {
		case "indent":  append(&parts, Syntax_Part{kind = .Indent}); continue
		case "dedent":  append(&parts, Syntax_Part{kind = .Dedent}); continue
		case "newline": append(&parts, Syntax_Part{kind = .Newline}); continue
		}

		field_index := -1
		for field, candidate in fields do if field.name == token.text do field_index = candidate
		if field_index < 0 {
			names := make([dynamic]string, 0, len(fields), loader.temporary)
			for field in fields do append(&names, field.name)
			loader_error(loader, token.start, token.end, "`%s` has no field `%s`; its fields are %s", KIND_NAMES[kind], token.text, strings.join(names[:], ", ", loader.temporary))
			// its suffixes belong to it: one mistake, one error
			for index + 2 < len(tokens) && tokens[index + 1].kind != .Word && tokens[index + 1].kind != .Literal do index += 2
			continue
		}
		field := fields[field_index]
		uses[field_index] += 1
		if field.optional && len(groups) == 0 {
			loader_error(loader, token.start, token.end, "`%s` can be absent: put it inside [ ], like `[' ' %s]`", field.name, field.name)
		} else if !field.optional && field.kind != .List && len(groups) > 0 {
			loader_error(loader, token.start, token.end, "`%s` is always there, so it can't go inside [ ]", field.name)
		}
		for group in groups do parts[group].present |= field.kind == .Atom ? PRESENT_ATOM : 1 << field.slot
		part: Syntax_Part
		switch field.kind {
		case .Atom:  part = {kind = .Name}
		case .Child: part = {kind = .Slot, slot = field.slot, allow = field.allow, bare = field.allow}
		case .List:  part = {kind = .SlotList, slot = field.slot, allow = field.allow, bare = field.allow}
		}

		// suffixes: :string :escaped :number, *separator +separator, !kind, |empty
		has_separator := false
		suffixes: for index + 1 < len(tokens) {
			suffix := tokens[index + 1]
			if suffix.kind == .Word || suffix.kind == .Literal || suffix.kind == .Open_Bracket || suffix.kind == .Close_Bracket do break
			index += 1
			if index + 1 >= len(tokens) {
				loader_error(loader, suffix.start, suffix.end, "`%s` needs something after it", suffix.text)
				break
			}
			argument := tokens[index + 1]
			index += 1
			#partial switch suffix.kind {
			case .Colon:
				format, known := Syntax_Part_Kind.Name, true
				switch argument.text {
				case "word":    format = .Name
				case "string":  format = .Quoted
				case "escaped": format = .Escaped
				case "number":  format = .Number
				case:           known = false
				}
				if field.kind != .Atom || argument.kind != .Word || !known {
					loader_error(loader, suffix.start, argument.end, "`:word`, `:string`, `:escaped` and `:number` go after a name or text field")
					continue suffixes
				}
				part.kind = format
			case .Star, .Plus:
				if field.kind != .List {
					loader_error(loader, suffix.start, argument.end, "`%s` goes after a list field", suffix.text)
					continue suffixes
				}
				part.before = suffix.kind == .Plus
				if argument.kind == .Word && argument.text == "line" {
					part.text = "\n"
				} else if argument.kind == .Literal {
					part.text = argument.text
				} else {
					loader_error(loader, argument.start, argument.end, "a separator is a literal like ', ' or `line`")
					continue suffixes
				}
				has_separator = true
			case .Bang:
				excluded, known := kind_by_name(argument.text)
				if field.kind == .Atom || argument.kind != .Word || !known || excluded not_in field.allow {
					loader_error(loader, suffix.start, argument.end, "`!kind` goes after a field that can hold that kind")
					continue suffixes
				}
				part.bare -= {excluded}
			case .Bar:
				if field.kind != .List || argument.kind != .Literal {
					loader_error(loader, suffix.start, argument.end, "`|'text'` goes after a list field: the text that stands for an empty list")
					continue suffixes
				}
				part.empty = argument.text
			}
		}
		if field.kind == .List && !has_separator {
			loader_error(loader, token.start, token.end, "`%s` is a list: give it a separator, like `%s*', '` or `%s*line`", field.name, field.name, field.name)
		}
		append(&parts, part)
	}
	if len(groups) > 0 do loader_error(loader, key_start, key_end, "a `[` in the `%s` rule has no `]`", KIND_NAMES[kind])
	if len(parts) > 0 && parts[0].kind == .Optional && parts[0].text == "" && kind in EXPRESSION {
		loader_error(loader, key_start, key_end, "an expression rule can't start with [ ]")
	}

	for field, field_index in fields {
		switch {
		case uses[field_index] == 0:
			loader_error(loader, key_start, key_end, "the `%s` rule doesn't use `%s`: every field must appear once, or it would be lost", KIND_NAMES[kind], field.name)
		case uses[field_index] > 1:
			loader_error(loader, key_start, key_end, "the `%s` rule uses `%s` more than once", KIND_NAMES[kind], field.name)
		}
	}
	return parts[:]
}

// ---- registry ----

// every loaded syntax. Registering one with a name that's taken replaces the old one,
// so a user's file overrides a built-in
syntaxes: [dynamic]^Syntax

@(init)
load_builtin_syntaxes :: proc "contextless" () {
	context = runtime.default_context()
	syntaxes = make([dynamic]^Syntax, runtime.heap_allocator())
	scratch := scratch_begin()
	defer scratch_end(scratch)
	// the tree form first: the others fall back to it for kinds they don't spell
	for tree_form_pass in ([]bool{true, false}) {
		for file in #load_directory("../syntaxes") {
			if !strings.has_suffix(file.name, ".syntax") || (file.name == "func.syntax") != tree_form_pass do continue
			syntax, diagnostics := new_syntax(string(file.data), scratch.allocator)
			if len(diagnostics) > 0 do fmt.panicf("built-in syntax %s: %s", file.name, diagnostic_message(diagnostics[0], scratch.allocator))
			register_syntax(syntax)
		}
	}
}

// nil and the diagnostics (in `allocator`) if the text has errors
new_syntax :: proc(text: string, allocator := context.temp_allocator) -> (^Syntax, [dynamic]Diagnostic) {
	syntax := new(Syntax, runtime.heap_allocator())
	diagnostics := load_syntax(syntax, text, allocator)
	if len(diagnostics) > 0 {
		syntax_destroy(syntax)
		return nil, diagnostics
	}
	return syntax, diagnostics
}

syntax_destroy :: proc(syntax: ^Syntax) {
	virtual.arena_destroy(&syntax.arena)
	free(syntax, runtime.heap_allocator())
}

register_syntax :: proc(syntax: ^Syntax) {
	for &existing in syntaxes {
		if existing.name == syntax.name {
			syntax_destroy(existing)
			existing = syntax
			return
		}
	}
	append(&syntaxes, syntax)
}

find_syntax :: proc(name: string) -> ^Syntax {
	for syntax in syntaxes do if syntax.name == name do return syntax
	return nil
}

// the syntax whose extension ends the path, longest first: hello.func.fpy is a python view
find_syntax_for_path :: proc(path: string) -> ^Syntax {
	best: ^Syntax
	for syntax in syntaxes {
		if strings.has_suffix(path, syntax.extension) && (best == nil || len(syntax.extension) > len(best.extension)) do best = syntax
	}
	return best
}

// load every .syntax file in a directory; files with errors are skipped and reported.
// What `report` gets is only valid during the call
load_syntax_directory :: proc(directory: string, report: proc(path: string, text: string, diagnostics: []Diagnostic)) {
	scratch := scratch_begin()
	defer scratch_end(scratch)
	files, err := os.read_all_directory_by_path(directory, scratch.allocator)
	if err != nil do return
	for file in files {
		if !strings.has_suffix(file.name, ".syntax") do continue
		data, read_err := os.read_entire_file_from_path(file.fullpath, scratch.allocator)
		if read_err != nil do continue
		syntax, diagnostics := new_syntax(string(data), scratch.allocator)
		if syntax != nil do register_syntax(syntax)
		else if report != nil do report(file.fullpath, string(data), diagnostics[:])
	}
}
