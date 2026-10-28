// A .func file is the program's tree. A view shows it in another syntax as the virtual document
// funcview:<path>.func<view extension>, e.g. hello.func.fpy. Reading a view converts .func -> view,
// saving it converts view -> .func; the language server does both conversions.
// Which views exist is up to the server: one per syntax it has loaded, built-in or from a .syntax file.
const path = require("node:path");
const vscode = require("vscode");
const { LanguageClient } = require("vscode-languageclient/node");

const SCHEME = "funcview";
const BUILTIN_VIEWS = ["odin", "lua", "python", "c", "haskell", "lisp"]; // the ones with their own command

let client;
let views = []; // {name, title, extension}, every syntax except the tree itself
let viewsReady;

const viewOf = (uri) =>
	views.filter(({ extension }) => uri.path.endsWith(extension)).sort((a, b) => b.extension.length - a.extension.length)[0];
const sourceOf = (uri) => uri.with({ scheme: "file", path: uri.path.slice(0, -viewOf(uri).extension.length) });
const viewUri = (source, view) => source.with({ scheme: SCHEME, path: source.path + view.extension });
const isView = (uri) => uri.scheme === SCHEME && Boolean(viewOf(uri));

async function loadViews() {
	const syntaxes = await client.sendRequest("funC/syntaxes", null);
	views = syntaxes.filter(({ name }) => name !== "func");
}

async function convert(text, from, to) {
	await viewsReady;
	return client.sendRequest("funC/convert", { text, from, to });
}

class ViewFileSystem {
	constructor() {
		this.changes = new vscode.EventEmitter();
		this.onDidChangeFile = this.changes.event;
	}

	watch() {
		return new vscode.Disposable(() => {});
	}

	async stat(uri) {
		await viewsReady;
		const stat = await vscode.workspace.fs.stat(sourceOf(uri));
		return { ...stat, type: vscode.FileType.File };
	}

	async readFile(uri) {
		await viewsReady;
		const source = sourceOf(uri);
		const result = await convert(new TextDecoder().decode(await vscode.workspace.fs.readFile(source)), "func", viewOf(uri).name);
		if (!result.ok) throw vscode.FileSystemError.Unavailable(`${path.basename(source.fsPath)} is not a valid .func file, fix it before opening a view`);
		return new TextEncoder().encode(result.text);
	}

	async writeFile(uri, content) {
		await viewsReady;
		const view = viewOf(uri);
		const result = await convert(new TextDecoder().decode(content), view.name, "func");
		// with a broken file header there is no tree: saving would erase the .func
		if (!result.ok) throw vscode.FileSystemError.NoPermissions(`Not saved: the ${view.title} view needs a valid file header first`);
		await vscode.workspace.fs.writeFile(sourceOf(uri), new TextEncoder().encode(result.text + "\n"));
	}

	// a view is always a single file next to its .func
	readDirectory() {
		return [];
	}
	createDirectory(uri) {
		throw vscode.FileSystemError.NoPermissions(uri);
	}
	delete(uri) {
		throw vscode.FileSystemError.NoPermissions(uri);
	}
	rename(uri) {
		throw vscode.FileSystemError.NoPermissions(uri);
	}

	// open views re-read: of one .func that changed on disk, or all of them when a syntax changed
	refresh(source) {
		const events = vscode.workspace.textDocuments
			.filter(({ uri }) => isView(uri) && (!source || sourceOf(uri).toString() === source.toString()))
			.map(({ uri }) => ({ type: vscode.FileChangeType.Changed, uri }));
		if (events.length) this.changes.fire(events);
	}
}

// from a .func file: open the view beside it. From a view: replace it in the same tab
async function openView(name) {
	await viewsReady;
	const editor = vscode.window.activeTextEditor;
	if (!editor) return;
	const current = editor.document.uri;
	const fromView = isView(current);
	const source = fromView ? sourceOf(current) : current;
	if (!source.path.endsWith(".func")) {
		vscode.window.showInformationMessage("funC: open a .func file or one of its views first");
		return;
	}
	let view = views.find((candidate) => candidate.name === name);
	if (name && !view) {
		vscode.window.showErrorMessage(`funC: no syntax named ${name} is loaded`);
		return;
	}
	if (!view) {
		const items = views.map((candidate) => ({
			label: candidate.title,
			description: fromView && viewOf(current) === candidate ? "current" : candidate.extension,
			view: candidate,
		}));
		view = (await vscode.window.showQuickPick(items, { placeHolder: "View the tree as" }))?.view;
		if (!view) return;
	}
	if (fromView && viewOf(current) === view) return;

	// unsaved edits reach the new view through the .func, so save first; a refused save (broken header) stops here
	if (fromView && editor.document.isDirty && !(await editor.document.save())) return;

	await vscode.window.showTextDocument(viewUri(source, view), {
		viewColumn: fromView ? editor.viewColumn : vscode.ViewColumn.Beside,
		preview: false,
	});
	if (fromView) {
		const tab = vscode.window.tabGroups.all
			.flatMap((group) => group.tabs)
			.find((tab) => tab.input instanceof vscode.TabInputText && tab.input.uri.toString() === current.toString());
		if (tab) await vscode.window.tabGroups.close(tab);
	}
}

// the active .func or view, compiled; the C opens in a new editor
async function compileC89() {
	await viewsReady;
	const document = vscode.window.activeTextEditor?.document;
	const from = document && (isView(document.uri) ? viewOf(document.uri).name : document.uri.path.endsWith(".func") ? "func" : undefined);
	if (!from) {
		vscode.window.showInformationMessage("funC: open a .func file or one of its views first");
		return;
	}
	const result = await client.sendRequest("funC/compile", { text: document.getText(), from });
	if (!result.ok) {
		const shown = result.errors.slice(0, 3).join("; ");
		vscode.window.showErrorMessage(`funC: can't compile yet, ${result.errors.length} error${result.errors.length === 1 ? "" : "s"}: ${shown}`);
		return;
	}
	const c = await vscode.workspace.openTextDocument({ language: "c", content: result.text });
	await vscode.window.showTextDocument(c, { viewColumn: vscode.ViewColumn.Beside, preview: false });
}

function updateStatus(status, editor) {
	const uri = editor?.document.uri;
	if (uri && isView(uri)) {
		status.text = `$(preview) ${viewOf(uri).title}`;
		status.tooltip = "funC view: click to switch syntax";
	} else if (uri && editor.document.languageId === "funC") {
		status.text = "$(preview) funC tree";
		status.tooltip = "funC tree: click to open a view";
	} else {
		status.hide();
		return;
	}
	status.show();
}

async function autoOpenView(editor) {
	const settings = vscode.workspace.getConfiguration("funC");
	if (!editor || editor.document.languageId !== "funC" || editor.document.uri.scheme !== "file" || !settings.get("autoOpenView")) return;
	await viewsReady;
	const source = editor.document.uri.toString();
	const shown = vscode.window.visibleTextEditors.some(({ document }) => isView(document.uri) && sourceOf(document.uri).toString() === source);
	if (shown) return;
	const view = views.find(({ name }) => name === settings.get("defaultView")) ?? views[0];
	if (view) openView(view.name);
}

// syntaxes come from the built-ins, a `syntaxes` folder in each workspace folder, and funC.syntaxDirectories
function syntaxDirectories() {
	const folders = (vscode.workspace.workspaceFolders ?? []).map((folder) => path.join(folder.uri.fsPath, "syntaxes"));
	return [...folders, ...vscode.workspace.getConfiguration("funC").get("syntaxDirectories")];
}

function activate(context) {
	const configured = vscode.workspace.getConfiguration("funC").get("serverPath");
	const command = configured || path.join(context.extensionPath, "server", "funC-lsp.exe");
	client = new LanguageClient(
		"funC",
		"funC",
		{ command },
		{
			documentSelector: [{ language: "funC" }, { language: "funC-syntax" }, { language: "funC-view" }, { scheme: SCHEME }],
			initializationOptions: { syntaxDirectories: syntaxDirectories() },
		},
	);

	const fileSystem = new ViewFileSystem();
	viewsReady = client.start().then(loadViews);
	// a .syntax file became valid: new syntaxes appear as views, changed ones re-render
	viewsReady.then(() =>
		client.onNotification("funC/syntaxesChanged", async () => {
			await loadViews();
			fileSystem.refresh();
		}),
	);

	const watcher = vscode.workspace.createFileSystemWatcher("**/*.func");
	const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
	status.command = "funC.openView";
	context.subscriptions.push(
		vscode.workspace.registerFileSystemProvider(SCHEME, fileSystem, { isCaseSensitive: process.platform !== "win32" }),
		watcher,
		watcher.onDidChange((uri) => fileSystem.refresh(uri)),
		status,
		vscode.commands.registerCommand("funC.openView", () => openView()),
		vscode.commands.registerCommand("funC.compileC89", compileC89),
		...BUILTIN_VIEWS.map((name) => vscode.commands.registerCommand(`funC.viewAs.${name}`, () => openView(name))),
		vscode.window.onDidChangeActiveTextEditor((editor) => {
			updateStatus(status, editor);
			autoOpenView(editor);
		}),
		vscode.workspace.onDidOpenTextDocument(markView),
	);
	vscode.workspace.textDocuments.forEach(markView);
	viewsReady.then(() => updateStatus(status, vscode.window.activeTextEditor));
	autoOpenView(vscode.window.activeTextEditor);
}

// A view's extension (.fpy, or one from a user's syntax) means nothing to VS Code, so it would open as
// plain text. As funC-view it gets semantic highlighting from the server, which works for any syntax
function markView(document) {
	if (document.uri.scheme === SCHEME && document.languageId !== "funC-view") {
		vscode.languages.setTextDocumentLanguage(document, "funC-view");
	}
}

function deactivate() {
	return client?.stop();
}

module.exports = { activate, deactivate };
