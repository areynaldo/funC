// Semantic checks, the same for every syntax: names refer to something, values have the right
// types, calls match what they call, procedures with a result return one on every path.
// The type of every expression ends up in tree.types, for backends.
// Unparsed lines are skipped: their parse error was already reported.
package lang

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

Package_Member :: struct {
	name:        string,
	least, most: i32, // argument count; most = -1 for any
	result:      Type,
}

Known_Package :: struct {
	path:    string,
	members: []Package_Member,
}

// what backends know how to compile
KNOWN_PACKAGES := []Known_Package {
	{"core:fmt", {{"println", 0, -1, .None}, {"print", 0, -1, .None}}},
}

find_package :: proc(path: string) -> ^Known_Package {
	for &known in KNOWN_PACKAGES do if known.path == path do return &known
	return nil
}

// `import "core:fmt"` is used as `fmt`
package_alias :: proc(path: string) -> string {
	cut := max(strings.last_index_byte(path, ':'), strings.last_index_byte(path, '/'))
	return path[cut + 1:]
}

// names that are always there and can't be declared again
CONSTANTS :: [?]string{"true", "false"}

Symbol_Kind :: enum u8 {
	Package,
	Procedure,
	Variable,
	Constant,
}

Symbol :: struct {
	name: string,
	kind: Symbol_Kind,
	node: Node_Id, // the declaration; 0 for constants
	type: Type,
}

Checker :: struct {
	tree:        ^Tree,
	// all scopes on one stack: a scope is the length to truncate back to when it ends
	symbols:     [dynamic]Symbol,
	diagnostics: ^[dynamic]Diagnostic,
	temporary:   runtime.Allocator, // scratch, gone when check returns
	procedure:   Node_Id, // the one whose body is being checked
	result:      Type, // what it returns, None if nothing
}

check :: proc(tree: ^Tree, root: Node_Id, diagnostics: ^[dynamic]Diagnostic) {
	if root == 0 do return
	scratch := scratch_begin()
	defer scratch_end(scratch)
	checker := Checker {
		tree        = tree,
		symbols     = make([dynamic]Symbol, 0, 64, scratch.allocator),
		diagnostics = diagnostics,
		temporary   = scratch.allocator,
	}
	resize(&tree.types, len(tree.nodes))
	for name in CONSTANTS do append(&checker.symbols, Symbol{name, .Constant, 0, .Bool})
	file_scope := len(checker.symbols)
	declarations := list_items(tree, tree.nodes[root].slots[0])

	// imports and procedures are visible everywhere; variables from where they're declared
	for declaration in declarations {
		node := tree.nodes[declaration]
		#partial switch node.kind {
		case .Import:
			path := atom_text(tree, node.atom)
			if find_package(path) == nil do report(&checker, .Unknown_Package, declaration, path)
			declare(&checker, file_scope, package_alias(path), .Package, declaration, .Invalid)
		case .FunctionDeclaration:
			check_signature(&checker, declaration)
			declare(&checker, file_scope, atom_text(tree, node.atom), .Procedure, declaration, .Invalid)
		}
	}
	for declaration in declarations {
		node := tree.nodes[declaration]
		if node.kind != .VariableDeclaration do continue
		type := check_value(&checker, Node_Id(node.slots[0]))
		tree.types[declaration] = type
		declare(&checker, file_scope, atom_text(tree, node.atom), .Variable, declaration, type)
	}
	for declaration in declarations {
		if tree.nodes[declaration].kind == .FunctionDeclaration do check_procedure(&checker, declaration)
	}
}

// ---- reporting ----

report :: proc(checker: ^Checker, code: Diagnostic_Code, node: Node_Id, name: string, detail := "") -> ^Diagnostic {
	nodes := checker.tree.nodes
	append(checker.diagnostics, Diagnostic{code = code, start = nodes[node].start, end = nodes[node].end, name = name, detail = detail})
	return &checker.diagnostics[len(checker.diagnostics) - 1]
}

// a message about types; it lives in the tree, like the diagnostic
type_error :: proc(checker: ^Checker, node: Node_Id, format: string, args: ..any) {
	report(checker, .Type_Error, node, "", fmt.aprintf(format, ..args, allocator = tree_allocator(checker.tree)))
}

// "an int", "a string"
a :: proc(type: Type) -> string {
	switch type {
	case .Int:     return "an int"
	case .Bool:    return "a bool"
	case .String:  return "a string"
	case .None:    return "nothing"
	case .Invalid: return "an invalid value"
	}
	return ""
}

// ---- scopes ----

declare :: proc(checker: ^Checker, scope_start: int, name: string, kind: Symbol_Kind, node: Node_Id, type: Type) {
	for constant in CONSTANTS {
		if name == constant {
			report(checker, .Reserved_Name, node, name)
			return
		}
	}
	for symbol in checker.symbols[scope_start:] {
		if symbol.name == name {
			report(checker, .Duplicate_Name, node, name)
			return
		}
	}
	append(&checker.symbols, Symbol{name, kind, node, type})
}

lookup :: proc(checker: ^Checker, name: string) -> (Symbol, bool) {
	#reverse for symbol in checker.symbols do if symbol.name == name do return symbol, true // innermost first
	return {}, false
}

// ---- procedures ----

resolve_type :: proc(checker: ^Checker, type_node: Node_Id) -> Type {
	name := atom_text(checker.tree, checker.tree.nodes[type_node].atom)
	type: Type
	switch name {
	case "int":    type = .Int
	case "bool":   type = .Bool
	case "string": type = .String
	case:          report(checker, .Unknown_Type, type_node, name)
	}
	checker.tree.types[type_node] = type
	return type
}

// the parameter and result types, before any body: calls can come before the declaration
check_signature :: proc(checker: ^Checker, procedure: Node_Id) {
	tree := checker.tree
	node := tree.nodes[procedure]
	parameters := list_items(tree, node.slots[0])
	for parameter in parameters {
		tree.types[parameter] = resolve_type(checker, Node_Id(tree.nodes[parameter].slots[0]))
	}
	result := Node_Id(node.slots[2])
	tree.types[procedure] = result != 0 ? resolve_type(checker, result) : .None
	if atom_text(tree, node.atom) == "main" && (len(parameters) > 0 || result != 0) {
		type_error(checker, result != 0 ? result : parameters[0], "`main` can't take parameters or return a value")
	}
}

check_procedure :: proc(checker: ^Checker, procedure: Node_Id) {
	tree := checker.tree
	node := tree.nodes[procedure]
	scope_start := len(checker.symbols)
	defer resize(&checker.symbols, scope_start)
	checker.procedure, checker.result = procedure, tree.types[procedure]
	for parameter in list_items(tree, node.slots[0]) {
		declare(checker, scope_start, atom_text(tree, tree.nodes[parameter].atom), .Variable, parameter, tree.types[parameter])
	}
	body := Node_Id(node.slots[1])
	check_block(checker, body)
	if checker.result != .None && checker.result != .Invalid && !block_returns(tree, body) {
		type_error(checker, Node_Id(node.slots[2]), "`%s` must return %s on every path", atom_text(tree, node.atom), a(checker.result))
	}
}

// whether a block always ends in a return: its last statement is one, or an if whose branches both do
block_returns :: proc(tree: ^Tree, block: Node_Id) -> bool {
	statements := list_items(tree, tree.nodes[block].slots[0])
	if len(statements) == 0 do return false
	last := tree.nodes[statements[len(statements) - 1]]
	#partial switch last.kind {
	case .Return:
		return true
	case .If:
		return last.slots[2] != 0 && block_returns(tree, Node_Id(last.slots[1])) && block_returns(tree, Node_Id(last.slots[2]))
	}
	return false
}

// ---- statements ----

check_block :: proc(checker: ^Checker, block: Node_Id) {
	tree := checker.tree
	scope_start := len(checker.symbols)
	defer resize(&checker.symbols, scope_start)
	for statement in list_items(tree, tree.nodes[block].slots[0]) {
		node := tree.nodes[statement]
		#partial switch node.kind {
		case .VariableDeclaration:
			// `x := x` refers to the outer x: the new one exists after its value
			type := check_value(checker, Node_Id(node.slots[0]))
			tree.types[statement] = type
			declare(checker, scope_start, atom_text(tree, node.atom), .Variable, statement, type)
		case .Assignment:
			check_assignment(checker, statement)
		case .If:
			expect_bool(checker, Node_Id(node.slots[0]), "an `if` condition")
			check_block(checker, Node_Id(node.slots[1]))
			if node.slots[2] != 0 do check_block(checker, Node_Id(node.slots[2]))
		case .While:
			expect_bool(checker, Node_Id(node.slots[0]), "a `while` condition")
			check_block(checker, Node_Id(node.slots[1]))
		case .Return:
			check_return(checker, statement)
		case .ExpressionStatement:
			check_expression(checker, Node_Id(node.slots[0]))
		}
	}
}

check_assignment :: proc(checker: ^Checker, statement: Node_Id) {
	tree := checker.tree
	node := tree.nodes[statement]
	target, value := Node_Id(node.slots[0]), Node_Id(node.slots[1])
	value_type := check_value(checker, value)
	target_node := tree.nodes[target]
	if target_node.kind != .Identifier {
		type_error(checker, target, "only a variable can be assigned to")
		return
	}
	name := atom_text(tree, target_node.atom)
	symbol, found := lookup(checker, name)
	switch {
	case !found:
		report(checker, .Undefined_Name, target, name)
	case symbol.kind == .Constant:
		type_error(checker, target, "`%s` is a constant, it can't be assigned to", name)
	case symbol.kind != .Variable:
		type_error(checker, target, "`%s` is a %s, only a variable can be assigned to", name, symbol.kind == .Procedure ? "procedure" : "package")
	case:
		tree.types[target] = symbol.type
		if !compatible(symbol.type, value_type) {
			type_error(checker, value, "`%s` is %s, it can't be given %s", name, a(symbol.type), a(value_type))
		}
	}
}

check_return :: proc(checker: ^Checker, statement: Node_Id) {
	tree := checker.tree
	value := Node_Id(tree.nodes[statement].slots[0])
	name := atom_text(tree, tree.nodes[checker.procedure].atom)
	switch {
	case value != 0 && checker.result == .None:
		check_value(checker, value)
		type_error(checker, value, "`%s` doesn't return a value", name)
	case value != 0:
		if type := check_value(checker, value); !compatible(checker.result, type) {
			type_error(checker, value, "`%s` returns %s, not %s", name, a(checker.result), a(type))
		}
	case checker.result != .None && checker.result != .Invalid:
		type_error(checker, statement, "`%s` must return %s", name, a(checker.result))
	}
}

expect_bool :: proc(checker: ^Checker, condition: Node_Id, what: string) {
	if type := check_value(checker, condition); !compatible(.Bool, type) {
		type_error(checker, condition, "%s must be a bool, not %s", what, a(type))
	}
}

// an invalid type was already reported: accepting it everywhere keeps one mistake to one error
compatible :: proc(want, have: Type) -> bool {
	return want == have || want == .Invalid || have == .Invalid
}

// ---- expressions ----

// an expression whose value is used: an initializer, an argument, an operand
check_value :: proc(checker: ^Checker, expression: Node_Id) -> Type {
	type := check_expression(checker, expression)
	if type == .None {
		report(checker, .No_Value, expression, callee_name(checker.tree, Node_Id(checker.tree.nodes[expression].slots[0])))
		return .Invalid
	}
	return type
}

// any expression; a call to a procedure without a result gives None
check_expression :: proc(checker: ^Checker, expression: Node_Id) -> Type {
	type := expression_type(checker, expression)
	checker.tree.types[expression] = type
	return type
}

@(private = "file")
expression_type :: proc(checker: ^Checker, expression: Node_Id) -> Type {
	tree := checker.tree
	node := tree.nodes[expression]
	#partial switch node.kind {
	case .IntegerLiteral:
		text := atom_text(tree, node.atom)
		if value, ok := strconv.parse_i64(text); !ok || value > 2147483647 {
			type_error(checker, expression, "`%s` is too big: an int goes up to 2147483647", text)
		}
		return .Int
	case .StringLiteral:
		return .String
	case .Identifier:
		name := atom_text(tree, node.atom)
		symbol, found := lookup(checker, name)
		switch {
		case !found:                       report(checker, .Undefined_Name, expression, name)
		case symbol.kind == .Procedure:    report(checker, .Not_A_Value, expression, name, "a procedure")
		case symbol.kind == .Package:      report(checker, .Not_A_Value, expression, name, "a package")
		case:                              return symbol.type
		}
		return .Invalid
	case .Selector:
		if member, ok := check_selector(checker, expression); ok && member != nil {
			report(checker, .Not_A_Value, expression, selector_name(tree, expression), "a procedure")
		}
		return .Invalid
	case .FunctionCall:
		return check_call(checker, expression)
	case .Negate:
		if operand := check_value(checker, Node_Id(node.slots[0])); !compatible(.Int, operand) {
			type_error(checker, expression, "negating needs an int, not %s", a(operand))
		}
		return .Int
	case .Not:
		if operand := check_value(checker, Node_Id(node.slots[0])); !compatible(.Bool, operand) {
			type_error(checker, expression, "`not` needs a bool, not %s", a(operand))
		}
		return .Bool
	}
	if node.kind in BINARY do return binary_type(checker, expression)
	return .Invalid
}

@(private = "file")
binary_type :: proc(checker: ^Checker, expression: Node_Id) -> Type {
	node := checker.tree.nodes[expression]
	left := check_value(checker, Node_Id(node.slots[0]))
	right := check_value(checker, Node_Id(node.slots[1]))
	// in words, not symbols: every syntax spells the operators its own way
	operation: string
	operands, result: Type
	#partial switch node.kind {
	case .Add:       operation, operands, result = "adding", .Int, .Int
	case .Subtract:  operation, operands, result = "subtracting", .Int, .Int
	case .Multiply:  operation, operands, result = "multiplying", .Int, .Int
	case .Divide:    operation, operands, result = "dividing", .Int, .Int
	case .Remainder: operation, operands, result = "taking a remainder", .Int, .Int
	case .Less, .LessEqual, .Greater, .GreaterEqual:
		operation, operands, result = "comparing order", .Int, .Bool
	case .And:       operation, operands, result = "`and`", .Bool, .Bool
	case .Or:        operation, operands, result = "`or`", .Bool, .Bool
	case .Equal, .NotEqual:
		// any type, as long as both sides have the same one
		if !compatible(left, right) do type_error(checker, expression, "comparing needs two values of the same type, got %s and %s", a(left), a(right))
		return .Bool
	}
	if !compatible(operands, left) || !compatible(operands, right) {
		type_error(checker, expression, "%s needs two %ss, got %s and %s", operation, TYPE_NAMES[operands], a(left), a(right))
	}
	return result
}

// reports what's wrong with the call; returns what it gives
check_call :: proc(checker: ^Checker, call: Node_Id) -> Type {
	tree := checker.tree
	node := tree.nodes[call]
	callee := Node_Id(node.slots[0])
	arguments := list_items(tree, node.slots[1])
	argument_types := make([]Type, len(arguments), checker.temporary)
	for argument, index in arguments do argument_types[index] = check_value(checker, argument)

	callee_node := tree.nodes[callee]
	#partial switch callee_node.kind {
	case .Identifier:
		name := atom_text(tree, callee_node.atom)
		symbol, found := lookup(checker, name)
		switch {
		case !found:
			report(checker, .Undefined_Name, callee, name)
		case symbol.kind == .Variable || symbol.kind == .Constant:
			report(checker, .Not_Callable, callee, name, "a variable")
		case symbol.kind == .Package:
			report(checker, .Not_Callable, callee, name, "a package")
		case:
			parameters := list_items(tree, tree.nodes[symbol.node].slots[0])
			if len(arguments) != len(parameters) {
				diagnostic := report(checker, .Argument_Count, call, name)
				diagnostic.numbers = {i32(len(parameters)), i32(len(parameters)), i32(len(arguments))}
			} else {
				for parameter, index in parameters {
					want := tree.types[parameter]
					if !compatible(want, argument_types[index]) {
						type_error(checker, arguments[index], "argument %d of `%s` must be %s, not %s", index + 1, name, a(want), a(argument_types[index]))
					}
				}
			}
			return tree.types[symbol.node]
		}
		return .Invalid
	case .Selector:
		member, ok := check_selector(checker, callee)
		if !ok || member == nil do return .Invalid
		if given := i32(len(arguments)); given < member.least || (member.most >= 0 && given > member.most) {
			diagnostic := report(checker, .Argument_Count, call, selector_name(tree, callee))
			diagnostic.numbers = {member.least, member.most, given}
		}
		return member.result
	}
	check_expression(checker, callee)
	report(checker, .Not_Callable, callee, callee_name(tree, callee), "not a name")
	return .Invalid
}

// `fmt.println`: the base must be a package and the member must exist.
// ok = false when something was reported; member = nil when the package's contents are unknown
check_selector :: proc(checker: ^Checker, selector: Node_Id) -> (member: ^Package_Member, ok: bool) {
	tree := checker.tree
	node := tree.nodes[selector]
	base := Node_Id(node.slots[0])
	base_node := tree.nodes[base]
	if base_node.kind != .Identifier {
		check_expression(checker, base)
		report(checker, .Not_A_Package, base, callee_name(tree, base))
		return nil, false
	}
	name := atom_text(tree, base_node.atom)
	symbol, found := lookup(checker, name)
	if !found {
		report(checker, .Undefined_Name, base, name)
		return nil, false
	}
	if symbol.kind != .Package {
		report(checker, .Not_A_Package, base, name)
		return nil, false
	}
	known := find_package(atom_text(tree, tree.nodes[symbol.node].atom))
	if known == nil do return nil, true // already reported at the import
	member_name := atom_text(tree, node.atom)
	for &candidate in known.members do if candidate.name == member_name do return &candidate, true
	report(checker, .Unknown_Member, selector, name, member_name)
	return nil, false
}

// a short name for an expression, for messages
callee_name :: proc(tree: ^Tree, expression: Node_Id) -> string {
	node := tree.nodes[expression]
	#partial switch node.kind {
	case .Identifier, .StringLiteral, .IntegerLiteral: return atom_text(tree, node.atom)
	case .Selector:                                    return selector_name(tree, expression)
	case .FunctionCall:                                return callee_name(tree, Node_Id(node.slots[0]))
	}
	return "this"
}

selector_name :: proc(tree: ^Tree, selector: Node_Id) -> string {
	node := tree.nodes[selector]
	// it ends up in a diagnostic, which lives in the tree
	return strings.concatenate({callee_name(tree, Node_Id(node.slots[0])), ".", atom_text(tree, node.atom)}, tree_allocator(tree))
}
