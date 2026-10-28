// funC language server: JSON-RPC over stdio, full-document sync.
// Memory: each message is handled in context.temp_allocator, freed in one go after it.
// A document is one tree arena holding its text, nodes and diagnostics, reset on every edit.
// Loaded syntaxes each have their own arena too.
package main

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../backends/c89"
import "../lang"

// a .func file or a view of one, like hello.func.fpy: the extension picks the syntax on every parse,
// so a syntax that's reloaded or replaced applies at once
Document :: struct {
	text: string, // in the tree's arena
	tree: lang.Tree,
	root: lang.Node_Id,
}

documents: map[string]^Document

// convert and compile requests parse into this one tree, reset each time
request_tree: lang.Tree

syntax_for_uri :: proc(uri: string) -> ^lang.Syntax {
	syntax := lang.find_syntax_for_path(uri)
	return syntax != nil ? syntax : lang.find_syntax("func")
}

is_syntax_file :: proc(uri: string) -> bool {
	return strings.has_suffix(uri, ".syntax")
}

// ---- protocol types (only the fields we read or write) ----

Message :: struct {
	id:     json.Value,
	method: string,
}

Params :: struct($T: typeid) {
	params: T,
}

Text_Document :: struct {
	uri:  string,
	text: string,
}

Document_Params :: struct {
	text_document:   Text_Document `json:"textDocument"`,
	content_changes: []struct {
		text: string,
	} `json:"contentChanges"`,
}

Initialize_Params :: struct {
	initialization_options: struct {
		syntax_directories: []string `json:"syntaxDirectories"`,
	} `json:"initializationOptions"`,
}

Convert_Params :: struct {
	text: string,
	from: string,
	to:   string,
}

Convert_Result :: struct {
	ok:          bool, // false: the file itself didn't parse and `text` is empty, never save it
	text:        string,
	diagnostics: int, // parse errors in `text`; their lines are kept as Unparsed, not dropped
}

Compile_Params :: struct {
	text: string,
	from: string,
}

Compile_Result :: struct {
	ok:     bool,
	text:   string, // the C source
	errors: []string, // "line:column: message", when not ok
}

Syntax_Info :: struct {
	name:      string,
	title:     string,
	extension: string,
}

Semantic_Tokens_Params :: struct {
	text_document: struct {
		uri: string,
	} `json:"textDocument"`,
}

Semantic_Tokens :: struct {
	data: []u32,
}

// the names LSP clients know for lang.Token_Kind, in its order
TOKEN_TYPES := [lang.Token_Kind]string {
	.Keyword   = "keyword",
	.Operator  = "operator",
	.String    = "string",
	.Number    = "number",
	.Comment   = "comment",
	.Variable  = "variable",
	.Function  = "function",
	.Parameter = "parameter",
	.Type      = "type",
	.Namespace = "namespace",
	.Property  = "property",
}

Position :: struct {
	line:      int,
	character: int,
}

Range :: struct {
	start, end: Position,
}

Diagnostic :: struct {
	range:    Range,
	severity: int, // 1 = error
	source:   string,
	message:  string,
}

Publish_Diagnostics :: struct {
	uri:         string,
	diagnostics: []Diagnostic,
}

Initialize_Result :: struct {
	capabilities: struct {
		text_document_sync: int `json:"textDocumentSync"`, // 1 = full
		semantic_tokens:    struct {
			legend: struct {
				token_types:     []string `json:"tokenTypes"`,
				token_modifiers: []string `json:"tokenModifiers"`,
			},
			full:   bool,
		} `json:"semanticTokensProvider"`,
	},
	server_info:  struct {
		name: string,
	} `json:"serverInfo"`,
}

Response :: struct($T: typeid) {
	jsonrpc: string,
	id:      json.Value,
	result:  T,
}

Error_Response :: struct {
	jsonrpc: string,
	id:      json.Value,
	error:   struct {
		code:    int,
		message: string,
	},
}

Notification :: struct($T: typeid) {
	jsonrpc: string,
	method:  string,
	params:  T,
}

// ---- transport ----

read_message :: proc(reader: ^bufio.Reader) -> (body: []byte, ok: bool) {
	length := -1
	for {
		line, err := bufio.reader_read_string(reader, '\n', context.temp_allocator)
		if err != nil do return nil, false
		line = strings.trim_right(line, "\r\n")
		if line == "" do break
		if strings.has_prefix(line, "Content-Length:") {
			length = strconv.parse_int(strings.trim_space(line[len("Content-Length:"):])) or_else -1
		}
	}
	if length < 0 do return nil, false
	body = make([]byte, length, context.temp_allocator)
	_, err := io.read_full(bufio.reader_to_stream(reader), body)
	return body, err == nil
}

send :: proc(message: any) {
	body, err := json.marshal(message, allocator = context.temp_allocator)
	if err != nil {
		fmt.eprintln("funC: cannot encode message:", err)
		return
	}
	header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(body))
	os.write(os.stdout, transmute([]byte)header)
	os.write(os.stdout, body)
}

respond :: proc(id: json.Value, result: $T) {
	response := Response(T) {
		jsonrpc = "2.0",
		id      = id,
		result  = result,
	}
	send(response)
}

respond_error :: proc(id: json.Value, code: int, message: string) {
	response := Error_Response {
		jsonrpc = "2.0",
		id      = id,
	}
	response.error = {code, message}
	send(response)
}

notify :: proc(method: string, params: $T) {
	notification := Notification(T) {
		jsonrpc = "2.0",
		method  = method,
		params  = params,
	}
	send(notification)
}

decode :: proc(body: []byte, $T: typeid) -> (T, bool) {
	value: Params(T)
	err := json.unmarshal(body, &value, allocator = context.temp_allocator)
	return value.params, err == nil
}

// ---- diagnostics ----

// LSP positions are (line, UTF-16 code unit); the core works in byte offsets
lsp_position :: proc(text: string, offset: int) -> Position {
	position: Position
	for character in text[:min(offset, len(text))] {
		if character == '\n' {
			position.line += 1
			position.character = 0
		} else {
			position.character += character >= 0x10000 ? 2 : 1
		}
	}
	return position
}

publish :: proc(uri, text: string, diagnostics: []lang.Diagnostic) {
	published := make([]Diagnostic, len(diagnostics), context.temp_allocator)
	for diagnostic, index in diagnostics {
		start, end := int(diagnostic.start), int(diagnostic.end)
		if end <= start do end = start < len(text) && text[start] != '\n' ? start + 1 : start // underline one character
		published[index] = {
			range    = {lsp_position(text, start), lsp_position(text, end)},
			severity = 1,
			source   = "funC",
			message  = lang.diagnostic_message(diagnostic),
		}
	}
	notify("textDocument/publishDiagnostics", Publish_Diagnostics{uri, published})
}

file_uri :: proc(path: string) -> string {
	slashed, _ := strings.replace_all(path, "\\", "/", context.temp_allocator)
	return strings.concatenate({"file:///", strings.trim_left(slashed, "/")}, context.temp_allocator)
}

// LSP's encoding: five numbers per token, each position relative to the token before,
// in lines and UTF-16 code units. One pass over the text, since the tokens are in order
encode_tokens :: proc(document: ^Document) -> []u32 {
	tokens := lang.semantic_tokens(&document.tree, context.temp_allocator)
	data := make([]u32, 5 * len(tokens), context.temp_allocator)
	text := document.text
	offset, line, character := 0, 0, 0
	previous_line, previous_character := 0, 0
	utf16_length :: proc(text: string) -> int {
		length := 0
		for rune_value in text do length += rune_value >= 0x10000 ? 2 : 1
		return length
	}
	for token, index in tokens {
		for rune_value in text[offset:token.start] {
			if rune_value == '\n' {
				line, character = line + 1, 0
			} else {
				character += rune_value >= 0x10000 ? 2 : 1
			}
		}
		offset = int(token.start)
		data[5 * index + 0] = u32(line - previous_line)
		data[5 * index + 1] = u32(line == previous_line ? character - previous_character : character)
		data[5 * index + 2] = u32(utf16_length(text[token.start:][:token.length]))
		data[5 * index + 3] = u32(token.kind)
		data[5 * index + 4] = token.declaration ? 1 : 0
		previous_line, previous_character = line, character
	}
	return data
}

// ---- documents ----

update_document :: proc(uri: string, document: ^Document, text: string) {
	// `text` may be the document's own, which the reset frees: hold on to it for this message
	incoming := strings.clone(text, context.temp_allocator)
	lang.tree_reset(&document.tree)
	document.text = strings.clone(incoming, lang.tree_allocator(&document.tree))
	root, diagnostics := lang.parse(&document.tree, syntax_for_uri(uri), document.text)
	document.root = root
	lang.check(&document.tree, root, &diagnostics)
	publish(uri, document.text, diagnostics[:])
}

open_document :: proc(uri, text: string) {
	document := new(Document)
	lang.tree_init(&document.tree)
	documents[strings.clone(uri)] = document
	update_document(uri, document, text)
}

close_document :: proc(uri: string) {
	notify("textDocument/publishDiagnostics", Publish_Diagnostics{uri, {}})
	key, document := delete_key(&documents, uri)
	if document == nil do return
	lang.tree_destroy(&document.tree) // the text goes with it
	free(document)
	delete(key)
}

// a .syntax file being edited: report its errors as you type, and once it's valid,
// use it straight away: open documents re-parse and the client re-renders its views
syntax_file_changed :: proc(uri, text: string) {
	syntax, diagnostics := lang.new_syntax(text)
	publish(uri, text, diagnostics[:])
	if syntax == nil do return
	lang.register_syntax(syntax)
	for document_uri, document in documents do update_document(document_uri, document, document.text)
	notify("funC/syntaxesChanged", struct {}{})
}

report_syntax_file :: proc(path, text: string, diagnostics: []lang.Diagnostic) {
	publish(file_uri(path), text, diagnostics)
}

// ---- dispatch ----

handle :: proc(body: []byte) {
	message: Message
	if json.unmarshal(body, &message, allocator = context.temp_allocator) != nil {
		fmt.eprintln("funC: cannot decode message")
		return
	}

	switch message.method {
	case "initialize":
		if params, ok := decode(body, Initialize_Params); ok {
			for directory in params.initialization_options.syntax_directories {
				lang.load_syntax_directory(directory, report_syntax_file)
			}
		}
		result: Initialize_Result
		result.capabilities.text_document_sync = 1
		result.capabilities.semantic_tokens.legend.token_types = slice.enumerated_array(&TOKEN_TYPES)
		result.capabilities.semantic_tokens.legend.token_modifiers = {"declaration"}
		result.capabilities.semantic_tokens.full = true
		result.server_info.name = "funC"
		respond(message.id, result)

	case "initialized":

	case "shutdown":
		respond(message.id, json.Value(nil))

	case "exit":
		os.exit(0)

	case "textDocument/didOpen":
		if params, ok := decode(body, Document_Params); ok {
			uri, text := params.text_document.uri, params.text_document.text
			if is_syntax_file(uri) do syntax_file_changed(uri, text)
			else do open_document(uri, text)
		}

	case "textDocument/didChange":
		if params, ok := decode(body, Document_Params); ok && len(params.content_changes) > 0 {
			uri := params.text_document.uri
			text := params.content_changes[len(params.content_changes) - 1].text
			if is_syntax_file(uri) {
				syntax_file_changed(uri, text)
			} else if document := documents[uri]; document != nil {
				update_document(uri, document, text)
			}
		}

	case "textDocument/didClose":
		if params, ok := decode(body, Document_Params); ok {
			close_document(params.text_document.uri)
		}

	// highlighting: what the parser recorded for the document's last parse
	case "textDocument/semanticTokens/full":
		params, ok := decode(body, Semantic_Tokens_Params)
		document := documents[params.text_document.uri]
		if !ok || document == nil {
			respond(message.id, Semantic_Tokens{})
			return
		}
		respond(message.id, Semantic_Tokens{encode_tokens(document)})

	case "funC/syntaxes":
		infos := make([]Syntax_Info, len(lang.syntaxes), context.temp_allocator)
		for syntax, index in lang.syntaxes do infos[index] = {syntax.name, syntax.title, syntax.extension}
		respond(message.id, infos)

	// funC/convert: parse text in one syntax, print it in another. The client uses it
	// to render .func files as views and to turn a saved view back into .func
	case "funC/convert":
		params, ok := decode(body, Convert_Params)
		from, to := lang.find_syntax(params.from), lang.find_syntax(params.to)
		if !ok || from == nil || to == nil {
			respond_error(message.id, -32602, fmt.tprintf("funC/convert: no syntax named %q or %q", params.from, params.to))
			return
		}
		lang.tree_reset(&request_tree)
		root, diagnostics := lang.parse(&request_tree, from, params.text)
		respond(message.id, Convert_Result{root != 0, lang.print_tree(&request_tree, to, root, context.temp_allocator), len(diagnostics)})

	// funC/compile: parse, check and compile to C89
	case "funC/compile":
		params, ok := decode(body, Compile_Params)
		from := lang.find_syntax(params.from)
		if !ok || from == nil {
			respond_error(message.id, -32602, fmt.tprintf("funC/compile: no syntax named %q", params.from))
			return
		}
		lang.tree_reset(&request_tree)
		root, diagnostics := lang.parse(&request_tree, from, params.text)
		lang.check(&request_tree, root, &diagnostics)
		output: string
		if root != 0 && len(diagnostics) == 0 do output = c89.generate(&request_tree, root, &diagnostics, context.temp_allocator)
		errors := make([]string, len(diagnostics), context.temp_allocator)
		for diagnostic, index in diagnostics {
			line, column := lang.line_column(params.text, diagnostic.start)
			errors[index] = fmt.tprintf("%d:%d: %s", line, column, lang.diagnostic_message(diagnostic))
		}
		respond(message.id, Compile_Result{root != 0 && len(diagnostics) == 0, output, errors})

	case:
		if message.id != nil do respond_error(message.id, -32601, fmt.tprintf("method not found: %s", message.method))
	}
}

main :: proc() {
	lang.tree_init(&request_tree)
	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_stream(os.stdin))
	for {
		free_all(context.temp_allocator)
		body, ok := read_message(&reader)
		if !ok do break
		handle(body)
	}
}
