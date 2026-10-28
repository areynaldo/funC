// Tokens for highlighting. The parser records what each piece of text is as it parses, so
// highlighting comes with every syntax, including ones written by users: no grammar per syntax.
package lang

import "base:runtime"
import "core:slice"

// in the order of the LSP legend the server announces
Token_Kind :: enum u8 {
	Keyword,
	Operator,
	String,
	Number,
	Comment,
	Variable,
	Function,
	Parameter,
	Type,
	Namespace,
	Property,
}

Token :: struct {
	start:       u32,
	length:      u32,
	kind:        Token_Kind,
	declaration: bool, // where the name is introduced: a procedure, parameter or variable declaration
	node:        Node_Id, // the node the text belongs to, 0 for comments and punctuation
}

// stands for the node being parsed, which has no id until it's added; parse_rule fills it in
TOKEN_OWNER :: max(Node_Id)

record_token :: proc(parser: ^Parser, start, end: int, kind: Token_Kind, node := Node_Id(0), declaration := false) {
	if end <= start do return
	append(&parser.tree.tokens, Token{u32(start), u32(end - start), kind, declaration, node})
}

// what a node's own text is, by the kind of node and how the syntax writes it
atom_token :: proc(kind: Node_Kind, part: Syntax_Part_Kind) -> (token: Token_Kind, declaration: bool) {
	#partial switch kind {
	case .StringLiteral, .Unparsed: return .String, false
	case .IntegerLiteral:           return .Number, false
	case .Import:                   return .String, false
	case .File:                     return part == .Quoted ? .String : .Namespace, false
	case .FunctionDeclaration:      return .Function, true
	case .Parameter:                return .Parameter, true
	case .VariableDeclaration:      return .Variable, true
	case .Type:                     return .Type, false
	case .Selector:                 return .Property, false
	}
	return .Variable, false
}

// The tokens of a parsed tree, sorted, without overlaps, and with names refined by how they're
// used: a callee is a function, a package is a namespace, `true` is a keyword.
// The result is allocated with `allocator`
semantic_tokens :: proc(tree: ^Tree, allocator: runtime.Allocator) -> []Token {
	scratch := scratch_begin()
	defer scratch_end(scratch)
	callee := make([]bool, len(tree.nodes), scratch.allocator)
	for node in tree.nodes do if node.kind == .FunctionCall do callee[node.slots[0]] = true
	packages := make(map[string]bool, scratch.allocator)
	for node in tree.nodes do if node.kind == .Import do packages[package_alias(atom_text(tree, node.atom))] = true

	tokens := make([dynamic]Token, 0, len(tree.tokens), allocator)
	sorted := slice.clone(tree.tokens[:], scratch.allocator)
	slice.stable_sort_by(sorted, proc(a, b: Token) -> bool {return a.start < b.start})
	for token in sorted {
		// skipping the same comment twice records it twice
		if len(tokens) > 0 && token.start < tokens[len(tokens) - 1].start + tokens[len(tokens) - 1].length do continue
		refined := token
		if int(token.node) < len(tree.nodes) && token.node != 0 {
			node := tree.nodes[token.node]
			switch {
			case token.kind == .Variable && node.kind == .Identifier:
				name := atom_text(tree, node.atom)
				if name == "true" || name == "false" do refined.kind = .Keyword
				else if callee[token.node] do refined.kind = .Function
				else if name in packages do refined.kind = .Namespace
			case token.kind == .Property && callee[token.node]:
				refined.kind = .Function
			}
		}
		append(&tokens, refined)
	}
	return tokens[:]
}
