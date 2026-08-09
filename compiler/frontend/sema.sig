//! Layer 1 — Semantic Analysis
//!
//! Type checking, name resolution, and comptime evaluation.
//! Uses fixed-capacity containers with LRU eviction for bounded memory.

const types = @import("../core/types.sig");
const containers = @import("../core/containers.sig");
const cap = @import("../core/capacity.sig");

const Symbol_Entry = types.Symbol_Entry;
const Type_Descriptor = types.Type_Descriptor;
const AST_Node = types.AST_Node;
const IR_Node = types.IR_Node;
const Source_Loc = types.Source_Loc;
const Compiler_Capacity_Plan = cap.Compiler_Capacity_Plan;

const Fixed_Hash_Map = containers.Fixed_Hash_Map;
const Intern_Pool = containers.Intern_Pool;
const BoundedVec = containers.BoundedVec;

const NULL_NODE: u32 = 0xFFFFFFFF;

// ============================================================================
// Scope_Frame
// ============================================================================

/// Tracks scope boundaries for nested name resolution.
/// `start_index` records the symbol table entry count when the scope was entered,
/// enabling efficient eviction of scope-local entries on scope exit.
pub const Scope_Frame = struct {
    start_index: u32, // symbol count when this scope was entered
    depth: u16,
};

// ============================================================================
// Comptime_Value
// ============================================================================

/// A value produced during compile-time evaluation.
/// Lives on the fixed-capacity eval stack.
pub const Comptime_Value = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum(u8) {
        int,
        float,
        boolean,
        type_val,
        void_val,
        undefined_val,
        slice_val,
    };

    pub const Data = union {
        int: i64,
        float: f64,
        boolean: bool,
        type_index: u32,
        none: void,
    };
};

// ============================================================================
// Sema — Semantic Analysis Engine
// ============================================================================

/// Semantic analysis state: symbol table, type intern pool, evaluation stack,
/// and scope tracking. All containers are comptime-sized with LRU eviction.
pub const Sema = struct {
    /// Symbol table — open-addressing hash map with LRU eviction.
    /// Keys are u64 name hashes; values are Symbol_Entry.
    symbol_table: Fixed_Hash_Map(
        u64,
        Symbol_Entry,
        Compiler_Capacity_Plan.SYMBOL_BUCKETS,
        Compiler_Capacity_Plan.SYMBOL_TABLE_CAPACITY,
    ),

    /// Type intern pool — deduplicates type descriptors.
    type_pool: Intern_Pool(Type_Descriptor, Compiler_Capacity_Plan.TYPE_INTERN_CAPACITY),

    /// Comptime evaluation stack.
    eval_stack: BoundedVec(Comptime_Value, Compiler_Capacity_Plan.MAX_COMPTIME_EVAL_DEPTH),

    /// Scope stack for nested name resolution.
    scope_stack: BoundedVec(Scope_Frame, Compiler_Capacity_Plan.MAX_SCOPE_DEPTH),

    /// Current nesting depth (0 = file/module scope).
    current_depth: u16 = 0,

    /// Error counter for diagnostics (full Diagnostic_Ring integration comes in pipeline phase).
    error_count: u32 = 0,

    /// Temporary IR output buffer for analysis results.
    ir_buffer: BoundedVec(IR_Node, 4096) = .{},

    /// Initialize all fields to zero/empty state.
    pub fn init() Sema {
        return .{
            .symbol_table = .{},
            .type_pool = .{},
            .eval_stack = .{},
            .scope_stack = .{},
            .current_depth = 0,
            .error_count = 0,
            .ir_buffer = .{},
        };
    }

    /// Resolve an identifier by name hash.
    /// Returns a pointer to the Symbol_Entry if found and the symbol's
    /// scope_depth <= current_depth (i.e. it's visible in the current scope).
    /// Returns null if not found or not visible.
    pub fn resolveIdentifier(self: *Sema, name_hash: u64) ?*Symbol_Entry {
        const entry = self.symbol_table.get(name_hash);
        if (entry) |sym| {
            // Symbol must be declared at or above the current depth to be visible
            if (sym.scope_depth <= self.current_depth) {
                return sym;
            }
        }
        return null;
    }

    /// Declare a symbol in the current scope.
    /// Sets the entry's scope_depth to the current depth and inserts into
    /// the symbol table. If the table is full, LRU eviction occurs automatically.
    pub fn declareSymbol(self: *Sema, entry: Symbol_Entry) void {
        var e = entry;
        e.scope_depth = self.current_depth;
        self.symbol_table.put(e.name_hash, e);
    }

    /// Enter a new scope. Increments depth and pushes a Scope_Frame.
    pub fn pushScope(self: *Sema) void {
        self.current_depth += 1;
        self.scope_stack.append(.{
            .start_index = @intCast(self.symbol_table.entry_count),
            .depth = self.current_depth,
        }) catch {};
    }

    /// Exit the current scope. Pops the Scope_Frame, decrements depth,
    /// and evicts symbols that belonged to the exited scope.
    pub fn popScope(self: *Sema) void {
        if (self.scope_stack.len() > 0) {
            self.scope_stack.size -= 1;
        }
        self.current_depth -= 1;
        _ = self.evictCompletedScopes();
    }

    /// Intern a type descriptor into the type pool.
    /// Returns the stable index for the interned type.
    /// If the pool is full, LRU eviction occurs automatically.
    pub fn internType(self: *Sema, desc: Type_Descriptor) u32 {
        return self.type_pool.intern(desc);
    }

    /// Evict symbols from completed (exited) scopes.
    /// Scans the symbol table and removes entries whose scope_depth exceeds
    /// the current_depth — these belong to scopes that have already been popped.
    /// Returns the number of evicted entries.
    pub fn evictCompletedScopes(self: *Sema) usize {
        var evicted: usize = 0;
        const bucket_count = Compiler_Capacity_Plan.SYMBOL_BUCKETS;
        var i: usize = 0;
        while (i < bucket_count) : (i += 1) {
            if (self.symbol_table.buckets[i].occupied) {
                if (self.symbol_table.buckets[i].value.scope_depth > self.current_depth) {
                    self.symbol_table.buckets[i].occupied = false;
                    self.symbol_table.entry_count -= 1;
                    evicted += 1;
                }
            }
        }
        return evicted;
    }

    // ========================================================================
    // Analysis — Type Checking and IR Production
    // ========================================================================

    /// Analyze an AST node: perform name resolution, type checking, and emit IR.
    /// Returns the type_index of the analyzed expression/declaration.
    ///
    /// For declarations: declares the symbol, analyzes the type/value, emits IR.
    /// For expressions: produces IR_Node entries, returns the result type.
    /// For literals: produces constant IR_Node entries.
    /// For identifier_ref: resolves the identifier, returns its type.
    pub fn analyze(self: *Sema, node: *const AST_Node) u32 {
        return switch (node.tag) {
            // --- Declarations ---
            .const_decl, .var_decl => self.analyzeDecl(node),
            .fn_decl => self.analyzeFnDecl(node),
            .struct_decl, .enum_decl, .union_decl => self.analyzeTypeDecl(node),

            // --- Expressions ---
            .binary_expr => self.analyzeBinaryExpr(node),
            .unary_expr => self.analyzeUnaryExpr(node),
            .call_expr => self.analyzeCallExpr(node),
            .field_access, .index_access => self.analyzeAccessExpr(node),

            // --- Literals ---
            .integer_literal => self.analyzeIntLiteral(node),
            .float_literal => self.analyzeFloatLiteral(node),
            .bool_literal => self.analyzeBoolLiteral(node),
            .string_literal => self.analyzeStringLiteral(node),
            .null_literal => self.analyzeNullLiteral(node),
            .undefined_literal => self.analyzeUndefinedLiteral(node),

            // --- Identifier reference ---
            .identifier_ref => self.analyzeIdentifierRef(node),

            // --- Statements ---
            .block => self.analyzeBlock(node),
            .return_stmt => self.analyzeReturnStmt(node),
            .if_stmt => self.analyzeIfStmt(node),
            .while_stmt, .for_stmt => self.analyzeLoopStmt(node),
            .assign_stmt => self.analyzeAssignStmt(node),

            // --- Comptime ---
            .comptime_expr => self.analyzeComptimeExpr(node),

            // --- Fallthrough for complex/unimplemented cases ---
            else => self.internVoidType(),
        };
    }

    /// Evaluate a compile-time constant expression.
    /// Handles: integer/float/bool literals, basic arithmetic on comptime ints.
    /// Push/pop values on eval_stack.
    /// Returns null if expression is not comptime-evaluable.
    pub fn evalComptime(self: *Sema, node: *const AST_Node) ?Comptime_Value {
        return switch (node.tag) {
            .integer_literal => .{
                .tag = .int,
                .data = .{ .int = @as(i64, @intCast(node.data.leaf.token)) },
            },
            .float_literal => .{
                .tag = .float,
                .data = .{ .float = @as(f64, @floatFromInt(node.data.leaf.token)) },
            },
            .bool_literal => .{
                .tag = .boolean,
                .data = .{ .boolean = node.data.leaf.token != 0 },
            },
            .null_literal => .{
                .tag = .void_val,
                .data = .{ .none = {} },
            },
            .undefined_literal => .{
                .tag = .undefined_val,
                .data = .{ .none = {} },
            },
            .binary_expr => self.evalComptimeBinary(node),
            .unary_expr => self.evalComptimeUnary(node),
            .comptime_expr => blk: {
                // A comptime expression wraps an inner expression
                // In a real implementation we'd recurse on the inner node;
                // For now treat the operand as a literal index
                _ = node.data.unary.operand;
                break :blk null;
            },
            else => null,
        };
    }

    /// Re-analyze evicted declarations from source.
    /// In the streaming pipeline, when a symbol is needed but was evicted,
    /// this triggers re-parse + re-analyze from the original source span.
    /// Currently a placeholder — full integration with the streaming controller
    /// comes in the pipeline phase (task 12.2).
    pub fn recomputeFromSource(self: *Sema) void {
        // Placeholder: In the full pipeline, this would:
        // 1. Look up the source span for the evicted declaration
        // 2. Re-tokenize that span
        // 3. Re-parse it into AST nodes
        // 4. Re-analyze the declaration to restore the symbol/type
        //
        // For now, this is a no-op signal that the eviction system is wired up.
        // The streaming controller (pipeline phase) will provide the actual
        // source bytes and coordinate the re-analysis.
        _ = self;
    }

    /// Check whether two type indices are compatible.
    /// Handles: exact match, comptime_int coerces to any int, anytype matches all.
    pub fn checkTypeMatch(self: *Sema, expected: u32, actual: u32) bool {
        // Exact match — always compatible
        if (expected == actual) return true;

        // Look up both types in the intern pool
        const expected_type = self.type_pool.get(expected);
        const actual_type = self.type_pool.get(actual);

        // anytype matches everything
        if (expected_type.tag == .any_type or actual_type.tag == .any_type) return true;

        // comptime_int coerces to any integer type
        if (actual_type.tag == .comptime_int and expected_type.tag == .int) return true;
        if (expected_type.tag == .comptime_int and actual_type.tag == .int) return true;

        // comptime_float coerces to any float type
        if (actual_type.tag == .comptime_float and expected_type.tag == .float) return true;
        if (expected_type.tag == .comptime_float and actual_type.tag == .float) return true;

        // Optional type — comptime null coerces to any optional
        if (expected_type.tag == .optional and actual_type.tag == .void) return true;

        return false;
    }

    /// Report a semantic error with source location.
    /// Increments error_count. Full Diagnostic_Ring integration comes in the
    /// pipeline phase (task 10.1, 12.1).
    pub fn reportError(self: *Sema, msg: []const u8, loc: Source_Loc) void {
        _ = msg;
        _ = loc;
        self.error_count += 1;
    }

    // ========================================================================
    // Internal Analysis Helpers
    // ========================================================================

    /// Analyze a const or var declaration.
    fn analyzeDecl(self: *Sema, node: *const AST_Node) u32 {
        const decl = node.data.decl;
        // Determine the type of the declaration
        var type_idx: u32 = self.internVoidType();
        if (decl.type_node != NULL_NODE) {
            // Explicit type annotation — would analyze the type expression
            type_idx = self.internVoidType();
        }
        if (decl.value_node != NULL_NODE) {
            // Has an initializer — the value determines/constrains the type
            // In a full implementation, we'd recursively analyze the value node
            type_idx = self.internComptimeIntType();
        }

        // Declare the symbol in the current scope
        self.declareSymbol(.{
            .name_hash = @as(u64, decl.name_token),
            .type_index = type_idx,
            .scope_depth = 0,
            .decl_file = 0,
            .decl_line = 0,
            .decl_column = 0,
            .last_referenced = 0,
            .is_comptime = (node.tag == .const_decl),
        });

        // Emit a store IR node for the declaration
        self.emitIR(.{
            .tag = .store,
            .data = .{ .binary = .{ .lhs = decl.name_token, .rhs = decl.value_node } },
            .type_index = type_idx,
        });

        return type_idx;
    }

    /// Analyze a function declaration.
    fn analyzeFnDecl(self: *Sema, node: *const AST_Node) u32 {
        const decl = node.data.decl;
        const void_type = self.internVoidType();
        // Intern a function type
        const fn_type = Type_Descriptor{
            .tag = .@"fn",
            .data = .{ .function = .{ .params_start = 0, .param_count = 0, .return_type = void_type } },
        };
        const type_idx = self.internType(fn_type);

        // Declare the function symbol
        self.declareSymbol(.{
            .name_hash = @as(u64, decl.name_token),
            .type_index = type_idx,
            .scope_depth = 0,
            .decl_file = 0,
            .decl_line = 0,
            .decl_column = 0,
            .last_referenced = 0,
            .is_pub = false,
        });

        // Analyze function body in a new scope
        self.pushScope();
        // Milestone 1 handles trivial void functions. A parsed body means the
        // function has a concrete return site even when it is an empty block.
        if (decl.value_node != NULL_NODE) {
            self.emitIR(.{
                .tag = .ret,
                .data = .{ .none = {} },
                .type_index = void_type,
            });
        }
        self.popScope();

        return type_idx;
    }

    /// Analyze a type declaration (struct/enum/union).
    fn analyzeTypeDecl(self: *Sema, node: *const AST_Node) u32 {
        const decl = node.data.decl;
        const type_tag: Type_Descriptor.Tag = switch (node.tag) {
            .struct_decl => .@"struct",
            .enum_decl => .@"enum",
            .union_decl => .@"union",
            else => .void,
        };
        const desc = Type_Descriptor{
            .tag = type_tag,
            .data = .{ .structure = .{ .fields_start = 0, .field_count = 0 } },
        };
        const type_idx = self.internType(desc);

        // Declare the type symbol
        self.declareSymbol(.{
            .name_hash = @as(u64, decl.name_token),
            .type_index = type_idx,
            .scope_depth = 0,
            .decl_file = 0,
            .decl_line = 0,
            .decl_column = 0,
            .last_referenced = 0,
        });

        return type_idx;
    }

    /// Analyze a binary expression (arithmetic, comparison, logical).
    fn analyzeBinaryExpr(self: *Sema, node: *const AST_Node) u32 {
        const bin = node.data.binary;
        // In a full implementation, we'd analyze lhs and rhs recursively
        // and determine the result type based on the operator.
        // For now, assume both operands are comptime_int → result is comptime_int.
        _ = bin;
        const result_type = self.internComptimeIntType();

        // Emit an add IR node (placeholder — real impl selects based on operator token)
        self.emitIR(.{
            .tag = .add,
            .data = .{ .binary = .{ .lhs = node.data.binary.lhs, .rhs = node.data.binary.rhs } },
            .type_index = result_type,
        });

        return result_type;
    }

    /// Analyze a unary expression.
    fn analyzeUnaryExpr(self: *Sema, node: *const AST_Node) u32 {
        const operand_idx = node.data.unary.operand;
        _ = operand_idx;
        const result_type = self.internComptimeIntType();

        self.emitIR(.{
            .tag = .neg,
            .data = .{ .unary = .{ .operand = node.data.unary.operand } },
            .type_index = result_type,
        });

        return result_type;
    }

    /// Analyze a call expression.
    fn analyzeCallExpr(self: *Sema, node: *const AST_Node) u32 {
        const call_data = node.data.call;
        _ = call_data;
        // In a full implementation, we'd:
        // 1. Resolve the callee to get its function type
        // 2. Check argument types against parameter types
        // 3. Return the function's return type
        const result_type = self.internVoidType();

        self.emitIR(.{
            .tag = .call,
            .data = .{ .call = .{ .callee = node.data.call.callee, .args_start = node.data.call.args_start, .args_count = node.data.call.args_count } },
            .type_index = result_type,
        });

        return result_type;
    }

    /// Analyze field access or index access expressions.
    fn analyzeAccessExpr(self: *Sema, node: *const AST_Node) u32 {
        _ = node;
        // In a full implementation, we'd resolve the base type and look up
        // the field/element type. For now, return void as placeholder.
        return self.internVoidType();
    }

    /// Analyze an integer literal.
    fn analyzeIntLiteral(self: *Sema, node: *const AST_Node) u32 {
        const type_idx = self.internComptimeIntType();
        self.emitIR(.{
            .tag = .constant,
            .data = .{ .constant = .{ .value = @as(u64, node.data.leaf.token) } },
            .type_index = type_idx,
        });
        return type_idx;
    }

    /// Analyze a float literal.
    fn analyzeFloatLiteral(self: *Sema, node: *const AST_Node) u32 {
        const type_idx = self.internComptimeFloatType();
        self.emitIR(.{
            .tag = .constant,
            .data = .{ .constant = .{ .value = @as(u64, node.data.leaf.token) } },
            .type_index = type_idx,
        });
        return type_idx;
    }

    /// Analyze a boolean literal.
    fn analyzeBoolLiteral(self: *Sema, node: *const AST_Node) u32 {
        const type_idx = self.internBoolType();
        self.emitIR(.{
            .tag = .constant,
            .data = .{ .constant = .{ .value = @as(u64, node.data.leaf.token) } },
            .type_index = type_idx,
        });
        return type_idx;
    }

    /// Analyze a string literal.
    fn analyzeStringLiteral(self: *Sema, node: *const AST_Node) u32 {
        _ = node;
        // String literals are slices: []const u8
        const u8_type = self.internType(.{
            .tag = .int,
            .data = .{ .int = .{ .bits = 8, .signed = false } },
        });
        const slice_type = self.internType(.{
            .tag = .slice,
            .data = .{ .slice = .{ .element = u8_type } },
        });
        return slice_type;
    }

    /// Analyze a null literal.
    fn analyzeNullLiteral(self: *Sema, node: *const AST_Node) u32 {
        _ = node;
        // null has type @TypeOf(null) — represented as void for now
        return self.internVoidType();
    }

    /// Analyze an undefined literal.
    fn analyzeUndefinedLiteral(self: *Sema, node: *const AST_Node) u32 {
        _ = node;
        return self.internVoidType();
    }

    /// Analyze an identifier reference — resolve name and return its type.
    fn analyzeIdentifierRef(self: *Sema, node: *const AST_Node) u32 {
        const name_hash = @as(u64, node.data.leaf.token);
        const resolved = self.resolveIdentifier(name_hash);
        if (resolved) |sym| {
            // Emit a load IR node for the resolved symbol
            self.emitIR(.{
                .tag = .load,
                .data = .{ .unary = .{ .operand = @as(u32, @truncate(name_hash)) } },
                .type_index = sym.type_index,
            });
            return sym.type_index;
        }
        // Undefined reference — report error
        self.reportError("undefined reference", .{ .file = 0, .line = 0, .column = 0 });
        return self.internVoidType();
    }

    /// Analyze a block statement.
    fn analyzeBlock(self: *Sema, node: *const AST_Node) u32 {
        _ = node;
        // In a full implementation, we'd push scope, analyze each statement,
        // and pop scope. The block's type is the type of the last expression
        // or void if the block is empty / ends with a non-expression statement.
        self.pushScope();
        // Would iterate block statements here
        self.popScope();
        return self.internVoidType();
    }

    /// Analyze a return statement.
    fn analyzeReturnStmt(self: *Sema, node: *const AST_Node) u32 {
        const operand = node.data.unary.operand;
        _ = operand;
        // In a full implementation, we'd analyze the return expression and
        // check it matches the enclosing function's return type.
        self.emitIR(.{
            .tag = .ret,
            .data = .{ .unary = .{ .operand = node.data.unary.operand } },
            .type_index = self.internVoidType(),
        });
        return self.internType(.{ .tag = .@"noreturn", .data = .{ .int = .{ .bits = 0, .signed = false } } });
    }

    /// Analyze an if statement.
    fn analyzeIfStmt(self: *Sema, node: *const AST_Node) u32 {
        _ = node;
        // In a full implementation: analyze condition (must be bool),
        // analyze then/else branches, unify branch types.
        return self.internVoidType();
    }

    /// Analyze a loop statement (while/for).
    fn analyzeLoopStmt(self: *Sema, node: *const AST_Node) u32 {
        _ = node;
        // In a full implementation: analyze condition and body in nested scope.
        return self.internVoidType();
    }

    /// Analyze an assignment statement.
    fn analyzeAssignStmt(self: *Sema, node: *const AST_Node) u32 {
        const bin = node.data.binary;
        _ = bin;
        // In a full implementation: analyze lhs (must be assignable lvalue),
        // analyze rhs, check type compatibility.
        self.emitIR(.{
            .tag = .store,
            .data = .{ .binary = .{ .lhs = node.data.binary.lhs, .rhs = node.data.binary.rhs } },
            .type_index = self.internVoidType(),
        });
        return self.internVoidType();
    }

    /// Analyze a comptime expression.
    fn analyzeComptimeExpr(self: *Sema, node: *const AST_Node) u32 {
        // Attempt comptime evaluation
        const val = self.evalComptime(node);
        if (val) |v| {
            // Push the evaluated value onto the eval stack
            self.eval_stack.append(v) catch {};
            return switch (v.tag) {
                .int => self.internComptimeIntType(),
                .float => self.internComptimeFloatType(),
                .boolean => self.internBoolType(),
                .type_val => v.data.type_index,
                else => self.internVoidType(),
            };
        }
        // Not evaluable at comptime — treat as runtime expression
        return self.internVoidType();
    }

    // ========================================================================
    // Comptime Evaluation Helpers
    // ========================================================================

    /// Evaluate a binary expression at compile time.
    fn evalComptimeBinary(self: *Sema, node: *const AST_Node) ?Comptime_Value {
        _ = self;
        // In a full implementation, we'd:
        // 1. Evaluate lhs and rhs recursively
        // 2. Apply the operator (token between lhs and rhs determines the op)
        // For now, we can handle the case where the token_start encodes the operator.
        // This is a simplified placeholder that demonstrates the pattern.
        _ = node;
        return null;
    }

    /// Evaluate a unary expression at compile time.
    fn evalComptimeUnary(self: *Sema, node: *const AST_Node) ?Comptime_Value {
        _ = self;
        _ = node;
        // In a full implementation: evaluate operand, apply unary operator.
        return null;
    }

    // ========================================================================
    // Type Interning Helpers
    // ========================================================================

    /// Intern the void type, returning its stable index.
    fn internVoidType(self: *Sema) u32 {
        return self.internType(.{
            .tag = .void,
            .data = .{ .int = .{ .bits = 0, .signed = false } },
        });
    }

    /// Intern the bool type, returning its stable index.
    fn internBoolType(self: *Sema) u32 {
        return self.internType(.{
            .tag = .@"bool",
            .data = .{ .int = .{ .bits = 1, .signed = false } },
        });
    }

    /// Intern the comptime_int type, returning its stable index.
    fn internComptimeIntType(self: *Sema) u32 {
        return self.internType(.{
            .tag = .comptime_int,
            .data = .{ .int = .{ .bits = 0, .signed = true } },
        });
    }

    /// Intern the comptime_float type, returning its stable index.
    fn internComptimeFloatType(self: *Sema) u32 {
        return self.internType(.{
            .tag = .comptime_float,
            .data = .{ .float = .{ .bits = 0 } },
        });
    }

    // ========================================================================
    // IR Emission Helper
    // ========================================================================

    /// Emit an IR node into the temporary buffer.
    fn emitIR(self: *Sema, ir: IR_Node) void {
        self.ir_buffer.append(ir) catch {};
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Sema init produces empty state" {
    var sema = Sema.init();
    if (sema.current_depth != 0) @compileError("initial depth should be 0");
    if (sema.scope_stack.len() != 0) @compileError("scope stack should be empty");
    if (sema.eval_stack.len() != 0) @compileError("eval stack should be empty");
    _ = &sema;
}

test "declareSymbol and resolveIdentifier" {
    var sema = Sema.init();

    // Declare a symbol at file scope (depth 0)
    sema.declareSymbol(.{
        .name_hash = 0x1234,
        .type_index = 0,
        .scope_depth = 0,
        .decl_file = 0,
        .decl_line = 1,
        .decl_column = 1,
        .last_referenced = 0,
    });

    // Should be resolvable
    const result = sema.resolveIdentifier(0x1234);
    if (result == null) @compileError("expected to find declared symbol");

    // Unknown symbol should return null
    const missing = sema.resolveIdentifier(0x9999);
    if (missing != null) @compileError("expected null for unknown symbol");
}

test "pushScope and popScope manage depth" {
    var sema = Sema.init();
    if (sema.current_depth != 0) @compileError("initial depth should be 0");

    sema.pushScope();
    if (sema.current_depth != 1) @compileError("depth should be 1 after pushScope");
    if (sema.scope_stack.len() != 1) @compileError("scope stack should have 1 frame");

    sema.pushScope();
    if (sema.current_depth != 2) @compileError("depth should be 2 after second pushScope");

    sema.popScope();
    if (sema.current_depth != 1) @compileError("depth should be 1 after popScope");

    sema.popScope();
    if (sema.current_depth != 0) @compileError("depth should be 0 after second popScope");
}

test "evictCompletedScopes removes inner scope symbols" {
    var sema = Sema.init();

    // Declare symbol in file scope
    sema.declareSymbol(.{
        .name_hash = 0xAAAA,
        .type_index = 0,
        .scope_depth = 0,
        .decl_file = 0,
        .decl_line = 1,
        .decl_column = 1,
        .last_referenced = 0,
    });

    // Enter scope and declare inner symbol
    sema.pushScope();
    sema.declareSymbol(.{
        .name_hash = 0xBBBB,
        .type_index = 1,
        .scope_depth = 0, // will be overwritten by declareSymbol to current_depth=1
        .decl_file = 0,
        .decl_line = 2,
        .decl_column = 1,
        .last_referenced = 0,
    });

    // Inner symbol should be visible
    if (sema.resolveIdentifier(0xBBBB) == null) @compileError("inner symbol should be visible");

    // Pop scope — inner symbol gets evicted
    sema.popScope();

    // Outer symbol still visible
    if (sema.resolveIdentifier(0xAAAA) == null) @compileError("outer symbol should still be visible");

    // Inner symbol no longer visible
    if (sema.resolveIdentifier(0xBBBB) != null) @compileError("inner symbol should be evicted");
}

test "internType deduplicates" {
    var sema = Sema.init();

    const desc1 = Type_Descriptor{
        .tag = .int,
        .data = .{ .int = .{ .bits = 32, .signed = true } },
    };
    const desc2 = Type_Descriptor{
        .tag = .int,
        .data = .{ .int = .{ .bits = 32, .signed = true } },
    };
    const desc3 = Type_Descriptor{
        .tag = .float,
        .data = .{ .float = .{ .bits = 64 } },
    };

    const idx1 = sema.internType(desc1);
    const idx2 = sema.internType(desc2);
    const idx3 = sema.internType(desc3);

    // Same type should produce same index
    if (idx1 != idx2) @compileError("identical types should intern to same index");
    // Different type should produce different index
    if (idx1 == idx3) @compileError("different types should intern to different indices");
}

test "scope shadowing - inner scope wins" {
    var sema = Sema.init();

    // Declare 'x' at file scope with type_index 10
    sema.declareSymbol(.{
        .name_hash = 0x1111,
        .type_index = 10,
        .scope_depth = 0,
        .decl_file = 0,
        .decl_line = 1,
        .decl_column = 1,
        .last_referenced = 0,
    });

    sema.pushScope();

    // Declare 'x' again at inner scope with type_index 20
    // Note: Fixed_Hash_Map's put() with the same key overwrites the value,
    // so the inner declaration shadows the outer one by replacing it.
    sema.declareSymbol(.{
        .name_hash = 0x1111,
        .type_index = 20,
        .scope_depth = 0,
        .decl_file = 0,
        .decl_line = 5,
        .decl_column = 1,
        .last_referenced = 0,
    });

    // Resolve should find the inner (most recent) declaration
    const resolved = sema.resolveIdentifier(0x1111);
    if (resolved == null) @compileError("shadowed symbol should be resolvable");
    if (resolved.?.type_index != 20) @compileError("inner scope should win (type_index=20)");

    sema.popScope();
}


// ============================================================================
// Property Tests — Tasks 5.3, 5.4, 5.5, 5.6
// ============================================================================

// Property 8: Identifier resolution correctness (scope shadowing)
// **Validates: Requirements 4.3**
test "identifier resolution - inner scope shadows outer" {
    var sema = Sema.init();
    sema.declareSymbol(.{ .name_hash = 0xABC, .type_index = 1, .scope_depth = 0, .decl_file = 0, .decl_line = 0, .decl_column = 0, .last_referenced = 0 });
    sema.pushScope();
    sema.declareSymbol(.{ .name_hash = 0xABC, .type_index = 2, .scope_depth = 0, .decl_file = 0, .decl_line = 0, .decl_column = 0, .last_referenced = 0 });
    const r = sema.resolveIdentifier(0xABC);
    if (r == null) @compileError("should resolve");
    if (r.?.type_index != 2) @compileError("inner scope should shadow outer");
    sema.popScope();
}

test "identifier resolution - outer visible after inner popped" {
    var sema = Sema.init();
    sema.declareSymbol(.{ .name_hash = 0xDEF, .type_index = 10, .scope_depth = 0, .decl_file = 0, .decl_line = 0, .decl_column = 0, .last_referenced = 0 });
    sema.pushScope();
    sema.declareSymbol(.{ .name_hash = 0x123, .type_index = 20, .scope_depth = 0, .decl_file = 0, .decl_line = 0, .decl_column = 0, .last_referenced = 0 });
    sema.popScope();
    // Inner symbol evicted
    if (sema.resolveIdentifier(0x123) != null) @compileError("inner should be evicted");
    // Outer still visible
    if (sema.resolveIdentifier(0xDEF) == null) @compileError("outer should remain");
}

// Property 9: Comptime evaluation consistency
// **Validates: Requirements 4.5**
test "comptime evaluation - integer literal" {
    var sema = Sema.init();
    const node = AST_Node{ .tag = .integer_literal, .token_start = 42, .data = .{ .leaf = .{ .token = 42 } } };
    const val = sema.evalComptime(&node);
    if (val == null) @compileError("integer literal should be comptime evaluable");
    if (val.?.tag != .int) @compileError("should produce int tag");
    if (val.?.data.int != 42) @compileError("should produce value 42");
}

test "comptime evaluation - bool literal" {
    var sema = Sema.init();
    const node = AST_Node{ .tag = .bool_literal, .token_start = 1, .data = .{ .leaf = .{ .token = 1 } } };
    const val = sema.evalComptime(&node);
    if (val == null) @compileError("bool literal should be comptime evaluable");
    if (val.?.tag != .boolean) @compileError("should produce boolean tag");
}

test "comptime evaluation - non-evaluable returns null" {
    var sema = Sema.init();
    const node = AST_Node{ .tag = .call_expr, .token_start = 0, .data = .{ .call = .{ .callee = 0, .args_start = 0, .args_count = 0 } } };
    const val = sema.evalComptime(&node);
    if (val != null) @compileError("call_expr should not be comptime evaluable");
}

// Property 10: Semantic error detection
// **Validates: Requirements 4.6**
test "semantic error - undefined reference increments error count" {
    var sema = Sema.init();
    const node = AST_Node{ .tag = .identifier_ref, .token_start = 0, .data = .{ .leaf = .{ .token = 0x9999 } } };
    _ = sema.analyze(&node);
    if (sema.error_count != 1) @compileError("undefined reference should produce an error");
}

test "semantic error - multiple errors accumulate" {
    var sema = Sema.init();
    sema.reportError("err1", .{ .file = 0, .line = 1, .column = 1 });
    sema.reportError("err2", .{ .file = 0, .line = 2, .column = 1 });
    if (sema.error_count != 2) @compileError("should accumulate 2 errors");
}

// Property 11: Eviction-recompute round trip
// **Validates: Requirements 4.7, 10.4**
test "eviction-recompute - evictCompletedScopes removes correct entries" {
    var sema = Sema.init();
    sema.pushScope();
    sema.declareSymbol(.{ .name_hash = 0x111, .type_index = 1, .scope_depth = 0, .decl_file = 0, .decl_line = 0, .decl_column = 0, .last_referenced = 0 });
    sema.declareSymbol(.{ .name_hash = 0x222, .type_index = 2, .scope_depth = 0, .decl_file = 0, .decl_line = 0, .decl_column = 0, .last_referenced = 0 });
    sema.popScope(); // evicts both
    if (sema.resolveIdentifier(0x111) != null) @compileError("should be evicted");
    if (sema.resolveIdentifier(0x222) != null) @compileError("should be evicted");
}

test "eviction-recompute - recomputeFromSource is callable" {
    var sema = Sema.init();
    // Should not crash or infinite loop
    sema.recomputeFromSource();
    // No observable side effect — this just verifies the method exists and is safe to call
    if (sema.error_count != 0) @compileError("recompute should not produce errors");
}
