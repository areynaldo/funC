// Drives the funC language server over stdio like an editor would.
// Build the server first:  odin build lsp -out:bin/funC-lsp.exe
// Then run:                node lsp/smoke_test.mjs [path/to/server]
import { spawn } from "node:child_process";
import assert from "node:assert/strict";

const serverPath = process.argv[2] ?? "bin/funC-lsp.exe";
const server = spawn(serverPath, [], { stdio: ["pipe", "pipe", "inherit"] });

let buffer = Buffer.alloc(0);
const waiting = [];
const inbox = [];

server.stdout.on("data", (chunk) => {
	buffer = Buffer.concat([buffer, chunk]);
	for (;;) {
		const headerEnd = buffer.indexOf("\r\n\r\n");
		if (headerEnd < 0) return;
		const length = Number(/Content-Length: (\d+)/.exec(buffer.subarray(0, headerEnd).toString())[1]);
		if (buffer.length < headerEnd + 4 + length) return;
		const message = JSON.parse(buffer.subarray(headerEnd + 4, headerEnd + 4 + length).toString());
		buffer = buffer.subarray(headerEnd + 4 + length);
		const index = waiting.findIndex((w) => w.match(message));
		if (index >= 0) waiting.splice(index, 1)[0].resolve(message);
		else inbox.push(message);
	}
});

function send(message) {
	const body = JSON.stringify({ jsonrpc: "2.0", ...message });
	server.stdin.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
}

function receive(match) {
	const index = inbox.findIndex(match);
	if (index >= 0) return Promise.resolve(inbox.splice(index, 1)[0]);
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error("timed out waiting for a server message")), 3000);
		waiting.push({ match, resolve: (m) => { clearTimeout(timer); resolve(m); } });
	});
}

let nextId = 1;
async function request(method, params) {
	const id = nextId++;
	send({ id, method, params });
	const response = await receive((m) => m.id === id);
	if (response.error) throw new Error(`${method}: ${response.error.message}`);
	return response.result;
}

const diagnostics = (uri) => receive((m) => m.method === "textDocument/publishDiagnostics" && m.params.uri === uri);

// a python view of broken.func, as the VS Code client names it
const uri = "funcview:/smoke/broken.func.fpy";
const broken = `package("main")
import("core:fmt")

def main():
    fmt.println("Hellope!"
    fmt.println("still parsed")`;

const initialized = await request("initialize", { processId: null, rootUri: null, capabilities: {} });
assert.equal(initialized.capabilities.textDocumentSync, 1);
send({ method: "initialized", params: {} });

send({ method: "textDocument/didOpen", params: { textDocument: { uri, languageId: "funC-python", version: 1, text: broken } } });
let published = await diagnostics(uri);
assert.equal(published.params.diagnostics.length, 1);
assert.equal(published.params.diagnostics[0].message, "expected `,` or `)`, found the end of the line");
assert.deepEqual(published.params.diagnostics[0].range.start, { line: 4, character: 26 });

send({ method: "textDocument/didChange", params: { textDocument: { uri, version: 2 }, contentChanges: [{ text: broken.replace(`"Hellope!"`, `"Hellope!")`) }] } });
published = await diagnostics(uri);
assert.equal(published.params.diagnostics.length, 0);

// saving a view: python -> func keeps the broken line as (unparsed ...)
const saved = await request("funC/convert", { text: broken, from: "python", to: "func" });
assert.equal(saved.ok, true);
assert.equal(saved.diagnostics, 1);
assert.equal(saved.text, `(file "main"
    (import "core:fmt")

    (proc "main"
        (block
            (unparsed "fmt.println(\\"Hellope!\\"")
            (expr (call (select (id "fmt") "println") (str "still parsed"))))))`);

// opening a view: func -> lua
const lua = await request("funC/convert", { text: saved.text, from: "func", to: "lua" });
assert.equal(lua.diagnostics, 0);
assert.equal(lua.text, `module main
require "core:fmt"

local function main()
    fmt.println("Hellope!"
    fmt.println("still parsed")
end`);

// a .func document gets diagnostics too
const funcUri = "file:///smoke/hello.func";
send({ method: "textDocument/didOpen", params: { textDocument: { uri: funcUri, languageId: "funC", version: 1, text: `(file "main" (import "core:fmt"` } } });
published = await diagnostics(funcUri);
assert.equal(published.params.diagnostics.length, 1);
assert.equal(published.params.diagnostics[0].message, "expected `)`, found the end of the file");

// a view whose file header is broken has no tree: the client must not save it
const headless = await request("funC/convert", { text: `pakage("main")`, from: "python", to: "func" });
assert.equal(headless.ok, false);
assert.equal(headless.text, "");

// semantic errors, with the span of the name
const misspelled = broken.replace('"Hellope!"', '"Hellope!")').replace('fmt.println("still', 'fmt.printx("still');
send({ method: "textDocument/didChange", params: { textDocument: { uri, version: 3 }, contentChanges: [{ text: misspelled }] } });
published = await diagnostics(uri);
assert.equal(published.params.diagnostics.length, 1);
assert.equal(published.params.diagnostics[0].message, "package `fmt` has no `printx`");
assert.deepEqual(published.params.diagnostics[0].range, { start: { line: 5, character: 4 }, end: { line: 5, character: 14 } });

// the built-in syntaxes, all loaded from syntax files
const syntaxes = await request("funC/syntaxes", null);
assert.deepEqual(syntaxes.map(({ name }) => name).sort(), ["c", "func", "haskell", "lisp", "lua", "odin", "python"]);

// editing a .syntax file: errors while it is wrong, and once it is valid it is used straight away
const syntaxUri = "file:///smoke/shouty.syntax";
const shouty = [
	"name = shouty",
	"extension = .fsh",
	"file   = 'PACKAGE ' package declarations*line",
	"import = 'USE ' path:string",
	"var    = 'LET ' name ' BE ' value",
	"proc   = 'TO ' name [' TAKING ' parameters*' AND '] [' GIVING ' result] body",
	"block  = indent statements*line dedent newline 'DONE'",
	"expr   = 'DO ' expression",
	"call   = function ' WITH ' arguments*' AND '|'NOTHING'",
	"select = base '/' name",
	"id     = name",
	"str    = value:string",
].join("\n");
send({ method: "textDocument/didOpen", params: { textDocument: { uri: syntaxUri, languageId: "funC-syntax", version: 1, text: shouty.replace("value:string", "vale:string") } } });
published = await diagnostics(syntaxUri);
assert.equal(published.params.diagnostics.length, 2);
assert.equal(published.params.diagnostics[0].message, "`str` has no field `vale`; its fields are value");
send({ method: "textDocument/didChange", params: { textDocument: { uri: syntaxUri, version: 2 }, contentChanges: [{ text: shouty }] } });
published = await diagnostics(syntaxUri);
assert.equal(published.params.diagnostics.length, 0);
// a new syntax re-checks every open document
assert.equal((await diagnostics(uri)).params.diagnostics.length, 1);
assert.equal((await diagnostics(funcUri)).params.diagnostics.length, 1);
await receive((m) => m.method === "funC/syntaxesChanged");
const shouted = await request("funC/convert", { text: saved.text, from: "func", to: "shouty" });
assert.ok(shouted.text.startsWith('PACKAGE main\nUSE "core:fmt"\n\nTO main'), shouted.text);

// compiling to C89: refused while a line is unparsed, accepted once the program is clean
let compiled = await request("funC/compile", { text: saved.text, from: "func" });
assert.equal(compiled.ok, false);
assert.deepEqual(compiled.errors, ["6:13: this line didn't parse, fix it before compiling"]);
compiled = await request("funC/compile", { text: 'package main\nimport "core:fmt"\nmain :: proc() {\n    fmt.println("Hellope!")\n}', from: "odin" });
assert.equal(compiled.ok, true);
assert.ok(compiled.text.includes("int main(void)"), compiled.text);

// highlighting: the legend is announced at initialize, the tokens come encoded relative to each other
const legend = initialized.capabilities.semanticTokensProvider.legend.tokenTypes;
const highlightUri = "funcview:/smoke/hl.func.fodin";
const highlighted = 'package main\nimport "core:fmt"\nmain :: proc() {\n    fmt.println("ü", 1 + 2)\n}';
send({ method: "textDocument/didOpen", params: { textDocument: { uri: highlightUri, languageId: "funC-view", version: 1, text: highlighted } } });
await diagnostics(highlightUri);
const { data } = await request("textDocument/semanticTokens/full", { textDocument: { uri: highlightUri } });
const decoded = [];
for (let index = 0, line = 0, character = 0; index < data.length; index += 5) {
	line += data[index];
	character = data[index] === 0 ? character + data[index + 1] : data[index + 1];
	decoded.push(`${line}:${character}:${data[index + 2]} ${legend[data[index + 3]]}`);
}
assert.deepEqual(decoded, [
	"0:0:7 keyword", "0:8:4 namespace",
	"1:0:6 keyword", "1:7:10 string",
	"2:0:4 function", "2:8:4 keyword",
	"3:4:3 namespace", "3:8:7 function", "3:16:3 string", "3:21:1 number", "3:23:1 operator", "3:25:1 number",
]);

await assert.rejects(request("funC/convert", { text: "", from: "func", to: "cobol" }));
await assert.rejects(request("textDocument/hover", {}));

send({ method: "textDocument/didClose", params: { textDocument: { uri } } });
published = await diagnostics(uri);
assert.equal(published.params.diagnostics.length, 0);

await request("shutdown", null);
send({ method: "exit" });
const code = await new Promise((resolve) => server.on("exit", resolve));
assert.equal(code, 0);
console.log("lsp smoke test passed");
