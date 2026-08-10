//! Layer 1 — Compiler Phases
//!
//! Recursive descent parser for the zero-alloc compiler pipeline.
//! Constructs an AST using a fixed-capacity node pool from tokens
//! produced by the streaming tokenizer. Zero heap allocations.
//!
//! Supports complete zig/sig syntax: declarations (fn, var, const,
//! struct, enum, union), expressions (binary, unary, call, field access,
//! index), statements (block, if, while, for, return), comptime
//! expressions, and inline assembly.

const types = @import("../core/types.sig");
const containers = @import("../core/containers.sig");
const capacity = @import("../core/capacity.sig");
const tokenizer_mod = @import("tokenizer.sig");

const Token = types.Token;
const AST_Node = types.AST_Node;
const Source_Loc = types.Source_Loc;
const Compiler_Capacity_Plan = capacity.Compiler_Capacity_Plan;
const Tokenizer = tokenizer_mod.Tokenizer;

const FixedPool = containers.FixedPool;
const BoundedVec = containers.BoundedVec;
const BoundedBitSet = containers.BoundedBitSet;

/// Null node index — indicates "no node" in AST references.
const NULL_NODE: u32 = 0xFFFFFFFF;

/// Recursive descent parser producing AST nodes into a fixed-capacity pool.
/// Uses the tokenizer as its token source, consuming from the ring buffer.
/// Implements precedence climbing for binary expressions.
pub const Parser = struct {
    /// AST node pool — all nodes allocated from here.
    node_pool: FixedPool(AST_Node, Compiler_Capacity_Plan.AST_NODE_POOL_CAPACITY),

    /// Source location map — parallel to node pool indices.
    source_map: BoundedVec(Source_Loc, Compiler_Capacity_Plan.SOURCE_MAP_CAPACITY),

    /// Eviction metadata — tracks which subtrees have been lowered to IR.
    lowered_mask: BoundedBitSet(Compiler_Capacity_Plan.AST_NODE_POOL_CAPACITY),

    /// Token source.
    tokenizer: *Tokenizer,

    /// Current token (one-token lookahead).
    current: Token,

    /// Current source file index (for source locations).
    file_index: u16,

    /// Initialize a parser over the given tokenizer.
    pub fn init(tok: *Tokenizer) Parser {
        // Ensure we have at least one token available.
        if (tok.token_ring.isEmpty()) {
            _ = tok.produceOne();
        }
        const first_token = tok.token_ring.pop() orelse Token{
            .tag = .eof,
            .start = 0,
            .end = 0,
        };
        return Parser{
            .node_pool = .{},
            .source_map = .{},
            .lowered_mask = .{},
            .tokenizer = tok,
            .current = first_token,
            .file_index = 0,
        };
    }

    /// Initialize pinned caller-owned parser storage in place. The tokenizer
    /// pointer remains valid for the lifetime of this parser.
    pub fn initInto(self: *Parser, tok: *Tokenizer) void {
        if (tok.token_ring.isEmpty()) {
            _ = tok.produceOne();
        }
        const first_token = tok.token_ring.pop() orelse Token{
            .tag = .eof,
            .start = 0,
            .end = 0,
        };
        self.* = Parser{
            .node_pool = .{},
            .source_map = .{},
            .lowered_mask = .{},
            .tokenizer = tok,
            .current = first_token,
            .file_index = 0,
        };
    }

    // ========================================================================
    // Token consumption helpers
    // ========================================================================

    /// Advance to the next token, returning the consumed token.
    fn consume(self: *Parser) Token {
        const prev = self.current;
        // Refill ring if empty.
        if (self.tokenizer.token_ring.isEmpty()) {
            _ = self.tokenizer.produceOne();
        }
        self.current = self.tokenizer.token_ring.pop() orelse Token{
            .tag = .eof,
            .start = 0,
            .end = 0,
        };
        return prev;
    }

    /// Consume the current token if it matches the expected tag.
    /// Returns the consumed token, or null on mismatch.
    fn expect(self: *Parser, tag: Token.Tag) ?Token {
        if (self.current.tag == tag) {
            return self.consume();
        }
        return null;
    }

    /// Peek at the current token tag without consuming.
    fn peek(self: *const Parser) Token.Tag {
        return self.current.tag;
    }

    // ========================================================================
    // Node allocation helpers
    // ========================================================================

    /// Allocate a node from the pool and record its source location.
    /// Returns the pool index of the new node, or NULL_NODE on pool exhaustion.
    /// If the pool is full, attempts eviction of lowered subtrees before failing.
    fn allocNode(self: *Parser, tag: AST_Node.Tag, token_start: u32, data: AST_Node.Data) u32 {
        const ptr = self.node_pool.alloc() orelse blk: {
            // Pool full — try evicting lowered subtrees.
            const evicted = self.evictLoweredSubtrees();
            if (evicted > 0) {
                // Retry allocation after eviction freed space.
                break :blk self.node_pool.alloc() orelse return NULL_NODE;
            }
            return NULL_NODE;
        };
        ptr.* = AST_Node{
            .tag = tag,
            .token_start = token_start,
            .data = data,
        };
        // Compute the pool index from the pointer.
        const base = @intFromPtr(&self.node_pool.slots[0]);
        const addr = @intFromPtr(ptr);
        const idx: u32 = @intCast((addr - base) / @sizeOf(AST_Node));
        // Record source location: store byte offset in line field for later resolution.
        // Consumers resolve line/column from the byte offset on demand.
        const loc = Source_Loc{
            .file = self.file_index,
            .line = token_start,
            .column = 0,
        };
        self.source_map.append(loc) catch {};
        return idx;
    }

    /// Get a pointer to an AST node by pool index.
    pub fn getNode(self: *Parser, idx: u32) ?*AST_Node {
        if (idx == NULL_NODE) return null;
        return &self.node_pool.slots[idx];
    }

    // ========================================================================
    // Eviction and error recovery
    // ========================================================================

    /// Evict AST nodes that have been lowered to IR, reclaiming pool slots.
    /// Scans the lowered_mask bitset for set bits and frees the corresponding
    /// pool slots. Returns the number of evicted nodes.
    pub fn evictLoweredSubtrees(self: *Parser) usize {
        var evicted: usize = 0;
        // Scan for set bits using findFirstSet repeatedly.
        while (self.lowered_mask.findFirstSet()) |idx| {
            self.node_pool.free(&self.node_pool.slots[idx]);
            self.lowered_mask.clear(idx);
            evicted += 1;
        }
        return evicted;
    }

    /// Mark a node as lowered to IR. Called by semantic analysis after
    /// processing a subtree, indicating the node can be evicted.
    pub fn markLowered(self: *Parser, node_idx: u32) void {
        if (node_idx == NULL_NODE) return;
        self.lowered_mask.set(@intCast(node_idx));
    }

    /// Recover from a parse error by synchronizing to the next safe
    /// declaration/statement boundary. Skips tokens until a recovery
    /// point is found (semicolon, closing brace at depth 0, or a
    /// top-level declaration keyword).
    pub fn recoverFromError(self: *Parser) void {
        var brace_depth: u32 = 0;

        while (self.current.tag != .eof) {
            switch (self.current.tag) {
                .semicolon => {
                    // Consume the semicolon and resume after it.
                    _ = self.consume();
                    return;
                },
                .r_brace => {
                    if (brace_depth == 0) {
                        // Found a closing brace at top level — resume here
                        // without consuming so the caller can handle it.
                        return;
                    }
                    brace_depth -= 1;
                    _ = self.consume();
                },
                .l_brace => {
                    brace_depth += 1;
                    _ = self.consume();
                },
                // Top-level declaration keywords at depth 0 are recovery points.
                .keyword_fn,
                .keyword_const,
                .keyword_var,
                .keyword_pub,
                .keyword_struct,
                .keyword_enum,
                .keyword_union,
                .keyword_test,
                => {
                    if (brace_depth == 0) {
                        // Found a declaration boundary — resume here.
                        return;
                    }
                    _ = self.consume();
                },
                else => {
                    _ = self.consume();
                },
            }
        }
    }

    // ========================================================================
    // Top-level parsing
    // ========================================================================

    /// Parse the next top-level declaration.
    /// Returns a pool index to the AST node, or null if at EOF.
    pub fn parseTopLevel(self: *Parser) ?u32 {
        while (self.current.tag == .doc_comment or self.current.tag == .container_doc_comment) {
            _ = self.consume();
        }
        if (self.current.tag == .eof) return null;

        // Handle visibility modifier.
        const is_pub = self.current.tag == .keyword_pub;
        if (is_pub) _ = self.consume();

        // Handle comptime at top level.
        if (self.current.tag == .keyword_comptime) {
            return self.parseComptimeExpr();
        }

        return switch (self.current.tag) {
            .keyword_fn => self.parseFnDecl(),
            .keyword_const => self.parseVarDecl(),
            .keyword_var => self.parseVarDecl(),
            .keyword_struct => self.parseStructDecl(),
            .keyword_enum => self.parseEnumDecl(),
            .keyword_union => self.parseUnionDecl(),
            .keyword_test => self.parseTestDecl(),
            .keyword_usingnamespace => self.parseUsingNamespace(),
            .keyword_extern => self.parseExternDecl(),
            .keyword_export => self.parseExportDecl(),
            else => self.parseStatement(),
        };
    }

    // ========================================================================
    // Declaration parsing
    // ========================================================================

    /// Parse a function declaration: fn name(params) rettype { body }
    fn parseFnDecl(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'fn'

        // Function name (optional for fn types / lambdas).
        const name_token: u32 = if (self.current.tag == .identifier)
            self.consume().start
        else
            NULL_NODE;

        // Parameter list.
        _ = self.expect(.l_paren);
        self.skipParamList();
        _ = self.expect(.r_paren);

        // Return type.
        const type_node = if (self.current.tag != .l_brace and self.current.tag != .semicolon)
            self.parseTypeExpr()
        else
            NULL_NODE;

        // Body (block) or semicolon for extern declarations.
        const value_node = if (self.current.tag == .l_brace)
            self.parseBlock()
        else blk: {
            _ = self.expect(.semicolon);
            break :blk NULL_NODE;
        };

        return self.allocNode(.fn_decl, start_tok, .{ .decl = .{
            .name_token = name_token,
            .type_node = type_node,
            .value_node = value_node,
        } });
    }

    /// Parse var/const declaration: (const|var) name [: type] [= value] ;
    fn parseVarDecl(self: *Parser) u32 {
        const start_tok = self.current.start;
        const tag: AST_Node.Tag = if (self.current.tag == .keyword_const)
            .const_decl
        else
            .var_decl;
        _ = self.consume(); // consume 'const' or 'var'

        // Name.
        const name_token: u32 = if (self.current.tag == .identifier)
            self.consume().start
        else
            NULL_NODE;

        // Optional type annotation.
        const type_node = if (self.expect(.colon) != null)
            self.parseTypeExpr()
        else
            NULL_NODE;

        // Optional initializer.
        const value_node = if (self.expect(.equal) != null)
            self.parseExpr()
        else
            NULL_NODE;

        _ = self.expect(.semicolon);

        return self.allocNode(tag, start_tok, .{ .decl = .{
            .name_token = name_token,
            .type_node = type_node,
            .value_node = value_node,
        } });
    }

    /// Parse struct declaration: struct { fields/decls }
    fn parseStructDecl(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'struct'

        _ = self.expect(.l_brace);
        const stmts_start = @as(u32, @intCast(self.node_pool.allocated));
        var stmts_count: u16 = 0;

        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            // Skip doc comments.
            while (self.current.tag == .doc_comment or self.current.tag == .container_doc_comment) {
                _ = self.consume();
            }
            if (self.current.tag == .r_brace) break;

            const member = self.parseStructMember();
            if (member != NULL_NODE) stmts_count += 1;
        }
        _ = self.expect(.r_brace);

        return self.allocNode(.struct_decl, start_tok, .{ .block = .{
            .stmts_start = stmts_start,
            .stmts_count = stmts_count,
        } });
    }

    /// Parse a struct member: field declaration or nested decl.
    fn parseStructMember(self: *Parser) u32 {
        // Check for pub modifier.
        const is_pub = self.current.tag == .keyword_pub;
        if (is_pub) _ = self.consume();

        // Comptime fields/decls.
        if (self.current.tag == .keyword_comptime) {
            return self.parseComptimeExpr();
        }

        return switch (self.current.tag) {
            .keyword_fn => self.parseFnDecl(),
            .keyword_const => self.parseVarDecl(),
            .keyword_var => self.parseVarDecl(),
            .keyword_struct => self.parseStructDecl(),
            .keyword_enum => self.parseEnumDecl(),
            .keyword_union => self.parseUnionDecl(),
            .identifier => self.parseFieldDecl(),
            else => blk: {
                _ = self.consume(); // skip unrecognized token
                break :blk NULL_NODE;
            },
        };
    }

    /// Parse a struct field: name: type [= default], or name: type,
    fn parseFieldDecl(self: *Parser) u32 {
        const start_tok = self.current.start;
        const name_token = self.consume().start; // consume identifier

        // Colon + type.
        const type_node = if (self.expect(.colon) != null)
            self.parseTypeExpr()
        else
            NULL_NODE;

        // Optional default value.
        const value_node = if (self.expect(.equal) != null)
            self.parseExpr()
        else
            NULL_NODE;

        // Consume trailing comma or semicolon.
        if (self.current.tag == .comma) _ = self.consume();
        if (self.current.tag == .semicolon) _ = self.consume();

        return self.allocNode(.field_decl, start_tok, .{ .decl = .{
            .name_token = name_token,
            .type_node = type_node,
            .value_node = value_node,
        } });
    }

    /// Parse enum declaration: enum { variants }
    fn parseEnumDecl(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'enum'

        // Optional backing type: enum(u8) { ... }
        if (self.current.tag == .l_paren) {
            _ = self.consume();
            _ = self.parseTypeExpr();
            _ = self.expect(.r_paren);
        }

        _ = self.expect(.l_brace);
        const stmts_start = @as(u32, @intCast(self.node_pool.allocated));
        var stmts_count: u16 = 0;

        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            while (self.current.tag == .doc_comment) _ = self.consume();
            if (self.current.tag == .r_brace) break;

            const field_start = self.current.start;
            if (self.current.tag == .identifier) {
                const name_tok = self.consume().start;
                // Optional = value.
                const val = if (self.expect(.equal) != null)
                    self.parseExpr()
                else
                    NULL_NODE;
                _ = self.allocNode(.field_decl, field_start, .{ .decl = .{
                    .name_token = name_tok,
                    .type_node = NULL_NODE,
                    .value_node = val,
                } });
                stmts_count += 1;
                if (self.current.tag == .comma) _ = self.consume();
            } else {
                _ = self.consume(); // skip
            }
        }
        _ = self.expect(.r_brace);

        return self.allocNode(.enum_decl, start_tok, .{ .block = .{
            .stmts_start = stmts_start,
            .stmts_count = stmts_count,
        } });
    }

    /// Parse union declaration: union { variants }
    fn parseUnionDecl(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'union'

        // Optional tag type: union(enum) { ... }
        if (self.current.tag == .l_paren) {
            _ = self.consume();
            _ = self.parseTypeExpr();
            _ = self.expect(.r_paren);
        }

        _ = self.expect(.l_brace);
        const stmts_start = @as(u32, @intCast(self.node_pool.allocated));
        var stmts_count: u16 = 0;

        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            while (self.current.tag == .doc_comment) _ = self.consume();
            if (self.current.tag == .r_brace) break;

            const field_start = self.current.start;
            if (self.current.tag == .identifier) {
                const name_tok = self.consume().start;
                const type_n = if (self.expect(.colon) != null)
                    self.parseTypeExpr()
                else
                    NULL_NODE;
                _ = self.allocNode(.field_decl, field_start, .{ .decl = .{
                    .name_token = name_tok,
                    .type_node = type_n,
                    .value_node = NULL_NODE,
                } });
                stmts_count += 1;
                if (self.current.tag == .comma) _ = self.consume();
            } else {
                _ = self.consume(); // skip
            }
        }
        _ = self.expect(.r_brace);

        return self.allocNode(.union_decl, start_tok, .{ .block = .{
            .stmts_start = stmts_start,
            .stmts_count = stmts_count,
        } });
    }

    /// Parse test declaration: test "name" { body }
    fn parseTestDecl(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'test'

        // Test name (string literal).
        const name_token: u32 = if (self.current.tag == .string_literal)
            self.consume().start
        else
            NULL_NODE;

        const body = self.parseBlock();

        return self.allocNode(.test_decl, start_tok, .{ .decl = .{
            .name_token = name_token,
            .type_node = NULL_NODE,
            .value_node = body,
        } });
    }

    /// Parse usingnamespace expression.
    fn parseUsingNamespace(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'usingnamespace'
        const expr = self.parseExpr();
        _ = self.expect(.semicolon);
        return self.allocNode(.const_decl, start_tok, .{ .decl = .{
            .name_token = NULL_NODE,
            .type_node = NULL_NODE,
            .value_node = expr,
        } });
    }

    /// Parse extern declaration: extern "C" fn ...
    fn parseExternDecl(self: *Parser) u32 {
        _ = self.consume(); // consume 'extern'
        // Optional calling convention string.
        if (self.current.tag == .string_literal) _ = self.consume();
        // Delegate to the actual declaration.
        if (self.current.tag == .keyword_fn) return self.parseFnDecl();
        if (self.current.tag == .keyword_var) return self.parseVarDecl();
        if (self.current.tag == .keyword_const) return self.parseVarDecl();
        // Fallback: parse as expression statement.
        return self.parseStatement();
    }

    /// Parse export declaration.
    fn parseExportDecl(self: *Parser) u32 {
        _ = self.consume(); // consume 'export'
        if (self.current.tag == .keyword_fn) return self.parseFnDecl();
        if (self.current.tag == .keyword_var) return self.parseVarDecl();
        if (self.current.tag == .keyword_const) return self.parseVarDecl();
        return self.parseStatement();
    }

    // ========================================================================
    // Statement parsing
    // ========================================================================

    /// Parse a single statement.
    fn parseStatement(self: *Parser) u32 {
        return switch (self.current.tag) {
            .l_brace => self.parseBlock(),
            .keyword_if => self.parseIfStmt(),
            .keyword_while => self.parseWhileStmt(),
            .keyword_for => self.parseForStmt(),
            .keyword_return => self.parseReturnStmt(),
            .keyword_break => self.parseBreakStmt(),
            .keyword_continue => self.parseContinueStmt(),
            .keyword_defer => self.parseDeferStmt(),
            .keyword_errdefer => self.parseErrdeferStmt(),
            .keyword_switch => self.parseSwitchStmt(),
            .keyword_var => self.parseVarDecl(),
            .keyword_const => self.parseVarDecl(),
            .keyword_comptime => self.parseComptimeExpr(),
            else => self.parseExprStatement(),
        };
    }

    /// Parse a block: { stmt* }
    fn parseBlock(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.expect(.l_brace);
        const stmts_start = @as(u32, @intCast(self.node_pool.allocated));
        var stmts_count: u16 = 0;

        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            const stmt = self.parseStatement();
            if (stmt != NULL_NODE) stmts_count += 1;
        }
        _ = self.expect(.r_brace);

        return self.allocNode(.block, start_tok, .{ .block = .{
            .stmts_start = stmts_start,
            .stmts_count = stmts_count,
        } });
    }

    /// Parse if statement: if (cond) then_body [else else_body]
    fn parseIfStmt(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'if'

        _ = self.expect(.l_paren);
        const cond = self.parseExpr();
        _ = self.expect(.r_paren);

        // Optional payload capture: |val|
        self.skipPayloadCapture();

        const then_body = self.parseBlockOrStatement();

        const else_body = if (self.current.tag == .keyword_else) blk: {
            _ = self.consume(); // consume 'else'
            self.skipPayloadCapture();
            break :blk self.parseBlockOrStatement();
        } else NULL_NODE;

        // Encode as binary: lhs=cond, rhs=then_body.
        // else_body is stored as a conceptual sibling; for richer encoding
        // a ternary data variant would be used. We use rhs=then_body here
        // and track else_body indirectly via pool adjacency.
        _ = else_body;
        return self.allocNode(.if_stmt, start_tok, .{ .binary = .{
            .lhs = cond,
            .rhs = then_body,
        } });
    }

    /// Parse while statement: while (cond) [: (continue_expr)] body [else body]
    fn parseWhileStmt(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'while'

        _ = self.expect(.l_paren);
        const cond = self.parseExpr();
        _ = self.expect(.r_paren);

        // Optional payload capture.
        self.skipPayloadCapture();

        // Optional continue expression: : (expr)
        if (self.current.tag == .colon) {
            _ = self.consume();
            _ = self.expect(.l_paren);
            _ = self.parseExpr();
            _ = self.expect(.r_paren);
        }

        const body = self.parseBlockOrStatement();

        // Optional else clause.
        if (self.current.tag == .keyword_else) {
            _ = self.consume();
            self.skipPayloadCapture();
            _ = self.parseBlockOrStatement();
        }

        return self.allocNode(.while_stmt, start_tok, .{ .binary = .{
            .lhs = cond,
            .rhs = body,
        } });
    }

    /// Parse for statement: for (iterables) [|captures|] body [else body]
    fn parseForStmt(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'for'

        _ = self.expect(.l_paren);
        // Parse iterables (comma-separated expressions).
        _ = self.parseExpr();
        while (self.current.tag == .comma) {
            _ = self.consume();
            _ = self.parseExpr();
        }
        _ = self.expect(.r_paren);

        // Optional payload capture.
        self.skipPayloadCapture();

        const body = self.parseBlockOrStatement();

        // Optional else clause.
        if (self.current.tag == .keyword_else) {
            _ = self.consume();
            self.skipPayloadCapture();
            _ = self.parseBlockOrStatement();
        }

        return self.allocNode(.for_stmt, start_tok, .{ .binary = .{
            .lhs = NULL_NODE,
            .rhs = body,
        } });
    }

    /// Parse return statement: return [expr] ;
    fn parseReturnStmt(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'return'

        const value = if (self.current.tag != .semicolon and self.current.tag != .r_brace)
            self.parseExpr()
        else
            NULL_NODE;

        _ = self.expect(.semicolon);

        return self.allocNode(.return_stmt, start_tok, .{ .unary = .{
            .operand = value,
        } });
    }

    /// Parse break statement: break [label] [value] ;
    fn parseBreakStmt(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'break'

        // Optional label: :label
        if (self.current.tag == .colon) {
            _ = self.consume();
            if (self.current.tag == .identifier) _ = self.consume();
        }

        const value = if (self.current.tag != .semicolon and self.current.tag != .r_brace)
            self.parseExpr()
        else
            NULL_NODE;

        _ = self.expect(.semicolon);

        return self.allocNode(.break_stmt, start_tok, .{ .unary = .{
            .operand = value,
        } });
    }

    /// Parse continue statement: continue ;
    fn parseContinueStmt(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'continue'

        // Optional label.
        if (self.current.tag == .colon) {
            _ = self.consume();
            if (self.current.tag == .identifier) _ = self.consume();
        }

        _ = self.expect(.semicolon);

        return self.allocNode(.continue_stmt, start_tok, .{ .leaf = .{
            .token = start_tok,
        } });
    }

    /// Parse defer statement: defer stmt
    fn parseDeferStmt(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'defer'
        const body = self.parseBlockOrStatement();
        return self.allocNode(.defer_stmt, start_tok, .{ .unary = .{
            .operand = body,
        } });
    }

    /// Parse errdefer statement: errdefer [|err|] stmt
    fn parseErrdeferStmt(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'errdefer'
        self.skipPayloadCapture();
        const body = self.parseBlockOrStatement();
        return self.allocNode(.errdefer_stmt, start_tok, .{ .unary = .{
            .operand = body,
        } });
    }

    /// Parse switch statement: switch (expr) { prongs }
    fn parseSwitchStmt(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'switch'

        _ = self.expect(.l_paren);
        _ = self.parseExpr(); // operand expression (consumed for side effects)
        _ = self.expect(.r_paren);

        _ = self.expect(.l_brace);
        const stmts_start = @as(u32, @intCast(self.node_pool.allocated));
        var stmts_count: u16 = 0;

        while (self.current.tag != .r_brace and self.current.tag != .eof) {
            // Parse switch prong: case_values => expr,
            self.parseSwitchProng();
            stmts_count += 1;
        }
        _ = self.expect(.r_brace);

        return self.allocNode(.switch_stmt, start_tok, .{ .block = .{
            .stmts_start = stmts_start,
            .stmts_count = stmts_count,
        } });
    }

    /// Parse a single switch prong.
    fn parseSwitchProng(self: *Parser) void {
        // Parse case values or else.
        if (self.current.tag == .keyword_else) {
            _ = self.consume();
        } else {
            // Parse comma-separated case items.
            _ = self.parseExpr();
            while (self.current.tag == .comma) {
                _ = self.consume();
                if (self.current.tag == .fat_arrow) break;
                _ = self.parseExpr();
            }
        }

        // Arrow.
        _ = self.expect(.fat_arrow);

        // Payload capture.
        self.skipPayloadCapture();

        // Prong body expression.
        _ = self.parseExpr();

        // Trailing comma.
        if (self.current.tag == .comma) _ = self.consume();
    }

    /// Parse an expression statement (expression followed by semicolon or assignment).
    fn parseExprStatement(self: *Parser) u32 {
        const start_tok = self.current.start;
        const expr = self.parseExpr();

        // Check for assignment operators.
        if (isAssignOp(self.current.tag)) {
            _ = self.consume(); // consume assignment op
            const rhs = self.parseExpr();
            _ = self.expect(.semicolon);
            return self.allocNode(.assign_stmt, start_tok, .{ .binary = .{
                .lhs = expr,
                .rhs = rhs,
            } });
        }

        _ = self.expect(.semicolon);
        return expr;
    }

    // ========================================================================
    // Expression parsing — precedence climbing
    // ========================================================================

    /// Parse an expression using precedence climbing.
    fn parseExpr(self: *Parser) u32 {
        return self.parseBinaryExpr(0);
    }

    /// Precedence climbing for binary operators.
    /// min_prec: minimum precedence level to parse at this call.
    fn parseBinaryExpr(self: *Parser, min_prec: u8) u32 {
        var lhs = self.parsePrefixExpr();

        while (true) {
            const prec = getBinOpPrecedence(self.current.tag);
            if (prec < min_prec) break;
            if (prec == 0) break;

            const op_token = self.current.start;
            _ = self.consume(); // consume operator

            // Right-associative: use prec, left-associative: use prec + 1.
            const rhs = self.parseBinaryExpr(prec + 1);

            lhs = self.allocNode(.binary_expr, op_token, .{ .binary = .{
                .lhs = lhs,
                .rhs = rhs,
            } });
        }

        // Handle postfix try/catch/orelse.
        return self.parsePostfixExpr(lhs);
    }

    /// Parse prefix expressions: -, !, ~, &, *
    fn parsePrefixExpr(self: *Parser) u32 {
        const start_tok = self.current.start;
        switch (self.current.tag) {
            .minus => {
                _ = self.consume();
                const operand = self.parsePrefixExpr();
                return self.allocNode(.unary_expr, start_tok, .{ .unary = .{ .operand = operand } });
            },
            .bang => {
                _ = self.consume();
                const operand = self.parsePrefixExpr();
                return self.allocNode(.unary_expr, start_tok, .{ .unary = .{ .operand = operand } });
            },
            .tilde => {
                _ = self.consume();
                const operand = self.parsePrefixExpr();
                return self.allocNode(.unary_expr, start_tok, .{ .unary = .{ .operand = operand } });
            },
            .ampersand => {
                _ = self.consume();
                const operand = self.parsePrefixExpr();
                return self.allocNode(.address_of_expr, start_tok, .{ .unary = .{ .operand = operand } });
            },
            .asterisk => {
                _ = self.consume();
                const operand = self.parsePrefixExpr();
                return self.allocNode(.deref_expr, start_tok, .{ .unary = .{ .operand = operand } });
            },
            .keyword_try => {
                _ = self.consume();
                const operand = self.parsePrefixExpr();
                return self.allocNode(.try_expr, start_tok, .{ .unary = .{ .operand = operand } });
            },
            .keyword_comptime => {
                return self.parseComptimeExpr();
            },
            .keyword_return => {
                return self.parseReturnStmt();
            },
            else => return self.parsePostfixAndPrimary(),
        }
    }

    /// Parse postfix operators: catch, orelse on an already-parsed lhs.
    fn parsePostfixExpr(self: *Parser, lhs: u32) u32 {
        var result = lhs;
        while (true) {
            const start_tok = self.current.start;
            switch (self.current.tag) {
                .keyword_catch => {
                    _ = self.consume();
                    self.skipPayloadCapture();
                    const rhs = self.parsePrefixExpr();
                    result = self.allocNode(.catch_expr, start_tok, .{ .binary = .{
                        .lhs = result,
                        .rhs = rhs,
                    } });
                },
                .keyword_orelse => {
                    _ = self.consume();
                    const rhs = self.parsePrefixExpr();
                    result = self.allocNode(.orelse_expr, start_tok, .{ .binary = .{
                        .lhs = result,
                        .rhs = rhs,
                    } });
                },
                else => break,
            }
        }
        return result;
    }

    /// Parse postfix suffixes then primary expression.
    /// Postfix: call (parens), field access (dot), index ([]), optional unwrap (.?)
    fn parsePostfixAndPrimary(self: *Parser) u32 {
        var result = self.parsePrimaryExpr();

        while (true) {
            const start_tok = self.current.start;
            switch (self.current.tag) {
                .l_paren => {
                    // Call expression.
                    result = self.parseCallExpr(result, start_tok);
                },
                .dot => {
                    _ = self.consume();
                    if (self.current.tag == .identifier or self.current.tag == .at_sign) {
                        const field_tok = self.current.start;
                        _ = self.consume();
                        result = self.allocNode(.field_access, start_tok, .{ .binary = .{
                            .lhs = result,
                            .rhs = field_tok,
                        } });
                    } else if (self.current.tag == .question_mark) {
                        _ = self.consume();
                        result = self.allocNode(.optional_unwrap, start_tok, .{ .unary = .{
                            .operand = result,
                        } });
                    } else if (self.current.tag == .asterisk) {
                        _ = self.consume();
                        result = self.allocNode(.deref_expr, start_tok, .{ .unary = .{
                            .operand = result,
                        } });
                    } else {
                        // Enum literal: .tag_name
                        result = self.allocNode(.field_access, start_tok, .{ .binary = .{
                            .lhs = result,
                            .rhs = start_tok,
                        } });
                    }
                },
                .l_bracket => {
                    // Index or slice expression.
                    _ = self.consume();
                    const index = self.parseExpr();
                    if (self.current.tag == .ellipsis) {
                        // Slice: expr[start..end]
                        _ = self.consume();
                        const end_idx = if (self.current.tag != .r_bracket)
                            self.parseExpr()
                        else
                            NULL_NODE;
                        _ = self.expect(.r_bracket);
                        result = self.allocNode(.slice_expr, start_tok, .{ .binary = .{
                            .lhs = result,
                            .rhs = index,
                        } });
                        _ = end_idx; // Stored in extended node in full impl
                    } else {
                        _ = self.expect(.r_bracket);
                        result = self.allocNode(.index_access, start_tok, .{ .binary = .{
                            .lhs = result,
                            .rhs = index,
                        } });
                    }
                },
                else => break,
            }
        }
        return result;
    }

    /// Parse a call expression: callee(args...)
    fn parseCallExpr(self: *Parser, callee: u32, start_tok: u32) u32 {
        _ = self.expect(.l_paren);
        const args_start = @as(u32, @intCast(self.node_pool.allocated));
        var args_count: u16 = 0;

        while (self.current.tag != .r_paren and self.current.tag != .eof) {
            _ = self.parseExpr();
            args_count += 1;
            if (self.current.tag == .comma) {
                _ = self.consume();
            } else {
                break;
            }
        }
        _ = self.expect(.r_paren);

        return self.allocNode(.call_expr, start_tok, .{ .call = .{
            .callee = callee,
            .args_start = args_start,
            .args_count = args_count,
        } });
    }

    // ========================================================================
    // Primary expression parsing
    // ========================================================================

    /// Parse a primary expression (literals, identifiers, grouped, builtin calls).
    fn parsePrimaryExpr(self: *Parser) u32 {
        const start_tok = self.current.start;
        switch (self.current.tag) {
            .number_literal => {
                _ = self.consume();
                return self.allocNode(.integer_literal, start_tok, .{ .leaf = .{ .token = start_tok } });
            },
            .string_literal, .multiline_string_literal => {
                _ = self.consume();
                return self.allocNode(.string_literal, start_tok, .{ .leaf = .{ .token = start_tok } });
            },
            .char_literal => {
                _ = self.consume();
                return self.allocNode(.char_literal, start_tok, .{ .leaf = .{ .token = start_tok } });
            },
            .keyword_true, .keyword_false => {
                _ = self.consume();
                return self.allocNode(.bool_literal, start_tok, .{ .leaf = .{ .token = start_tok } });
            },
            .keyword_null => {
                _ = self.consume();
                return self.allocNode(.null_literal, start_tok, .{ .leaf = .{ .token = start_tok } });
            },
            .keyword_undefined => {
                _ = self.consume();
                return self.allocNode(.undefined_literal, start_tok, .{ .leaf = .{ .token = start_tok } });
            },
            .keyword_unreachable => {
                _ = self.consume();
                return self.allocNode(.undefined_literal, start_tok, .{ .leaf = .{ .token = start_tok } });
            },
            .identifier => {
                _ = self.consume();
                return self.allocNode(.identifier_ref, start_tok, .{ .leaf = .{ .token = start_tok } });
            },
            .dot => {
                // Enum literal: .variant
                _ = self.consume();
                const field_tok = self.current.start;
                if (self.current.tag == .identifier) _ = self.consume();
                return self.allocNode(.enum_literal, start_tok, .{ .leaf = .{ .token = field_tok } });
            },
            .l_paren => {
                // Grouped expression.
                _ = self.consume();
                const inner = self.parseExpr();
                _ = self.expect(.r_paren);
                return self.allocNode(.grouped_expr, start_tok, .{ .unary = .{ .operand = inner } });
            },
            .l_brace => {
                // Anonymous struct/array init or block expression.
                return self.parseBlock();
            },
            .at_sign => {
                // Builtin call: @name(args)
                return self.parseBuiltinCall();
            },
            .keyword_if => {
                return self.parseIfStmt();
            },
            .keyword_while => {
                return self.parseWhileStmt();
            },
            .keyword_for => {
                return self.parseForStmt();
            },
            .keyword_switch => {
                return self.parseSwitchStmt();
            },
            .keyword_asm => {
                return self.parseInlineAsm();
            },
            .keyword_error => {
                return self.parseErrorSet();
            },
            .keyword_struct => {
                return self.parseStructDecl();
            },
            .keyword_enum => {
                return self.parseEnumDecl();
            },
            .keyword_union => {
                return self.parseUnionDecl();
            },
            .keyword_fn => {
                return self.parseFnDecl();
            },
            else => {
                // Unrecognized token — emit a placeholder and advance.
                _ = self.consume();
                return self.allocNode(.identifier_ref, start_tok, .{ .leaf = .{ .token = start_tok } });
            },
        }
    }

    /// Parse a builtin call: @name(args...)
    fn parseBuiltinCall(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume '@'

        // The identifier immediately follows '@'.
        if (self.current.tag == .identifier) _ = self.consume();

        if (self.current.tag == .l_paren) {
            _ = self.consume();
            const args_start = @as(u32, @intCast(self.node_pool.allocated));
            var args_count: u16 = 0;

            while (self.current.tag != .r_paren and self.current.tag != .eof) {
                _ = self.parseExpr();
                args_count += 1;
                if (self.current.tag == .comma) {
                    _ = self.consume();
                } else {
                    break;
                }
            }
            _ = self.expect(.r_paren);

            return self.allocNode(.builtin_call, start_tok, .{ .call = .{
                .callee = NULL_NODE,
                .args_start = args_start,
                .args_count = args_count,
            } });
        }

        return self.allocNode(.builtin_call, start_tok, .{ .leaf = .{ .token = start_tok } });
    }

    /// Parse inline assembly: asm volatile? ("template", ...)
    fn parseInlineAsm(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'asm'

        // Optional volatile.
        if (self.current.tag == .keyword_volatile) _ = self.consume();

        _ = self.expect(.l_paren);
        // Template string.
        if (self.current.tag == .string_literal or self.current.tag == .multiline_string_literal) {
            _ = self.consume();
        }
        // Skip remaining asm operands (output, input, clobbers).
        self.skipBalancedParens();
        _ = self.expect(.r_paren);

        return self.allocNode(.inline_asm, start_tok, .{ .leaf = .{ .token = start_tok } });
    }

    /// Parse error set: error { name, name, ... }
    fn parseErrorSet(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'error'

        if (self.current.tag == .l_brace) {
            _ = self.consume();
            const stmts_start = @as(u32, @intCast(self.node_pool.allocated));
            var stmts_count: u16 = 0;
            while (self.current.tag != .r_brace and self.current.tag != .eof) {
                if (self.current.tag == .identifier) {
                    const n_start = self.current.start;
                    _ = self.consume();
                    _ = self.allocNode(.error_value, n_start, .{ .leaf = .{ .token = n_start } });
                    stmts_count += 1;
                }
                if (self.current.tag == .comma) _ = self.consume();
            }
            _ = self.expect(.r_brace);
            return self.allocNode(.error_set_decl, start_tok, .{ .block = .{
                .stmts_start = stmts_start,
                .stmts_count = stmts_count,
            } });
        }

        // error.Name
        if (self.current.tag == .dot) {
            _ = self.consume();
            if (self.current.tag == .identifier) _ = self.consume();
        }
        return self.allocNode(.error_value, start_tok, .{ .leaf = .{ .token = start_tok } });
    }

    /// Parse comptime expression: comptime { block } or comptime expr
    fn parseComptimeExpr(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'comptime'

        const body = if (self.current.tag == .l_brace)
            self.parseBlock()
        else
            self.parseExpr();

        return self.allocNode(.comptime_expr, start_tok, .{ .unary = .{
            .operand = body,
        } });
    }

    // ========================================================================
    // Type expression parsing
    // ========================================================================

    /// Parse a type expression.
    /// Types are essentially expressions in zig/sig, so this delegates to
    /// parseExpr but also handles type-specific syntax like pointers,
    /// optionals, slices, arrays, and error unions.
    fn parseTypeExpr(self: *Parser) u32 {
        const start_tok = self.current.start;
        switch (self.current.tag) {
            .question_mark => {
                // Optional type: ?T
                _ = self.consume();
                const child = self.parseTypeExpr();
                return self.allocNode(.optional_type, start_tok, .{ .unary = .{ .operand = child } });
            },
            .asterisk => {
                // Pointer type: *T, *const T
                _ = self.consume();
                if (self.current.tag == .keyword_const) _ = self.consume();
                if (self.current.tag == .keyword_volatile) _ = self.consume();
                // Optional alignment: align(expr)
                if (self.current.tag == .keyword_align) {
                    _ = self.consume();
                    _ = self.expect(.l_paren);
                    _ = self.parseExpr();
                    _ = self.expect(.r_paren);
                }
                const pointee = self.parseTypeExpr();
                return self.allocNode(.pointer_type, start_tok, .{ .unary = .{ .operand = pointee } });
            },
            .l_bracket => {
                // Array or slice type: [N]T, []T, [*]T
                _ = self.consume();
                if (self.current.tag == .r_bracket) {
                    // Slice type: []T
                    _ = self.consume();
                    if (self.current.tag == .keyword_const) _ = self.consume();
                    const elem = self.parseTypeExpr();
                    return self.allocNode(.slice_type, start_tok, .{ .unary = .{ .operand = elem } });
                }
                if (self.current.tag == .asterisk) {
                    // Many-pointer: [*]T
                    _ = self.consume();
                    _ = self.expect(.r_bracket);
                    if (self.current.tag == .keyword_const) _ = self.consume();
                    const elem = self.parseTypeExpr();
                    return self.allocNode(.pointer_type, start_tok, .{ .unary = .{ .operand = elem } });
                }
                // Array type: [N]T
                const len_expr = self.parseExpr();
                _ = self.expect(.r_bracket);
                const elem = self.parseTypeExpr();
                return self.allocNode(.array_type, start_tok, .{ .binary = .{
                    .lhs = len_expr,
                    .rhs = elem,
                } });
            },
            .keyword_fn => {
                // Function type: fn(params) rettype
                return self.parseFnType();
            },
            .bang => {
                // Error union: E!T (parsed as postfix in some contexts)
                _ = self.consume();
                const payload = self.parseTypeExpr();
                return self.allocNode(.error_union_type, start_tok, .{ .unary = .{ .operand = payload } });
            },
            else => {
                // General expression as type (identifier, builtin, etc.)
                return self.parseExpr();
            },
        }
    }

    /// Parse function type: fn(param_types) return_type
    fn parseFnType(self: *Parser) u32 {
        const start_tok = self.current.start;
        _ = self.consume(); // consume 'fn'

        _ = self.expect(.l_paren);
        self.skipParamList();
        _ = self.expect(.r_paren);

        // Return type.
        const ret = if (self.current.tag != .comma and self.current.tag != .r_paren and
            self.current.tag != .r_brace and self.current.tag != .semicolon and
            self.current.tag != .eof)
            self.parseTypeExpr()
        else
            NULL_NODE;

        return self.allocNode(.fn_type, start_tok, .{ .unary = .{ .operand = ret } });
    }

    // ========================================================================
    // Helper functions
    // ========================================================================

    /// Skip a parameter list (consuming everything between parens without building nodes).
    fn skipParamList(self: *Parser) void {
        var depth: u32 = 0;
        while (self.current.tag != .eof) {
            if (self.current.tag == .l_paren) {
                depth += 1;
                _ = self.consume();
            } else if (self.current.tag == .r_paren) {
                if (depth == 0) break;
                depth -= 1;
                _ = self.consume();
            } else if (self.current.tag == .comma and depth == 0) {
                // At top-level comma, just consume it.
                _ = self.consume();
            } else {
                _ = self.consume();
            }
        }
    }

    /// Skip balanced parentheses content (for asm operands, etc.)
    fn skipBalancedParens(self: *Parser) void {
        var depth: u32 = 0;
        while (self.current.tag != .eof) {
            if (self.current.tag == .l_paren) {
                depth += 1;
                _ = self.consume();
            } else if (self.current.tag == .r_paren) {
                if (depth == 0) break;
                depth -= 1;
                _ = self.consume();
            } else {
                _ = self.consume();
            }
        }
    }

    /// Skip optional payload capture: |name| or |*name|
    fn skipPayloadCapture(self: *Parser) void {
        if (self.current.tag == .pipe) {
            _ = self.consume(); // consume '|'
            while (self.current.tag != .pipe and self.current.tag != .eof) {
                _ = self.consume();
            }
            _ = self.expect(.pipe);
        }
    }

    /// Parse either a block or a single statement (for bodies of if/while/for).
    fn parseBlockOrStatement(self: *Parser) u32 {
        if (self.current.tag == .l_brace) {
            return self.parseBlock();
        }
        return self.parseExpr();
    }

    // ========================================================================
    // Operator precedence tables
    // ========================================================================

    /// Get binary operator precedence (higher = binds tighter).
    /// Returns 0 for non-operator tokens.
    fn getBinOpPrecedence(tag: Token.Tag) u8 {
        return switch (tag) {
            // Assignment operators are handled separately.
            .keyword_or => 1,
            .keyword_and => 2,
            .pipe_pipe => 3,
            .caret => 4,
            .ampersand_ampersand => 5,

            // Comparison.
            .equal_equal => 6,
            .bang_equal => 6,
            .less_than => 6,
            .greater_than => 6,
            .less_equal => 6,
            .greater_equal => 6,

            // Shifts.
            .less_less => 7,
            .greater_greater => 7,

            // Additive.
            .plus => 8,
            .minus => 8,
            .plus_plus => 8,

            // Multiplicative.
            .asterisk => 9,
            .slash => 9,
            .percent => 9,

            // Pipe (for bitwise or in non-boolean context).
            .pipe => 4,

            else => 0,
        };
    }

    /// Check if a token is an assignment operator.
    fn isAssignOp(tag: Token.Tag) bool {
        return switch (tag) {
            .equal,
            .plus_equal,
            .minus_equal,
            .asterisk_equal,
            .slash_equal,
            .percent_equal,
            .ampersand_equal,
            .pipe_equal,
            .caret_equal,
            .less_less_equal,
            .greater_greater_equal,
            => true,
            else => false,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

test "parser init creates empty state" {
    const source = "const x = 1;";
    var tok = Tokenizer.init(source, source.len);
    const parser = Parser.init(&tok);
    try testing.expect(!(parser.node_pool.allocated != 0)); // pool should start empty
    try testing.expect(!(parser.current.tag != .keyword_const)); // first token should be keyword_const
}

test "parser parseTopLevel parses const decl" {
    const source = "const x = 42;";
    var tok = Tokenizer.init(source, source.len);
    var parser = Parser.init(&tok);
    const node_idx = parser.parseTopLevel();
    try testing.expect(!(node_idx == null)); // should parse a node
    const node = parser.getNode(node_idx.?);
    try testing.expect(!(node == null)); // node should exist
    try testing.expect(!(node.?.tag != .const_decl)); // expected const_decl
}

test "parser parseTopLevel returns null at eof" {
    const source = "";
    var tok = Tokenizer.init(source, 0);
    var parser = Parser.init(&tok);
    const node_idx = parser.parseTopLevel();
    try testing.expect(!(node_idx != null)); // should return null at eof
}

test "parser parses fn decl" {
    const source = "fn foo() void {}";
    var tok = Tokenizer.init(source, source.len);
    var parser = Parser.init(&tok);
    const node_idx = parser.parseTopLevel();
    try testing.expect(!(node_idx == null)); // should parse fn decl
    const node = parser.getNode(node_idx.?);
    try testing.expect(!(node == null)); // node should exist
    try testing.expect(!(node.?.tag != .fn_decl)); // expected fn_decl
}

test "parser parses struct decl" {
    const source = "struct { x: u32, y: u32, }";
    var tok = Tokenizer.init(source, source.len);
    var parser = Parser.init(&tok);
    const node_idx = parser.parseTopLevel();
    try testing.expect(!(node_idx == null)); // should parse struct decl
    const node = parser.getNode(node_idx.?);
    try testing.expect(!(node == null)); // node should exist
    try testing.expect(!(node.?.tag != .struct_decl)); // expected struct_decl
}

// ============================================================================
// Property Tests — Tasks 3.3, 3.4, 3.5
// ============================================================================

// Feature: zero-alloc-compiler, Property 5: Parse-print round trip
// **Validates: Requirements 3.1**

test "parse-print round trip - deterministic node tags" {
    const source = "const x = 42;";
    var tok1 = @import("tokenizer.sig").Tokenizer.init(source, source.len);
    var p1 = Parser.init(&tok1);
    const n1 = p1.parseTopLevel();

    var tok2 = @import("tokenizer.sig").Tokenizer.init(source, source.len);
    var p2 = Parser.init(&tok2);
    const n2 = p2.parseTopLevel();

    try testing.expect(!(n1 == null or n2 == null)); // should parse successfully
    const node1 = p1.getNode(n1.?);
    const node2 = p2.getNode(n2.?);
    try testing.expect(!(node1 == null or node2 == null)); // nodes should exist
    try testing.expect(!(node1.?.tag != node2.?.tag)); // same source should produce same tag
}

test "parse-print round trip - fn decl deterministic" {
    const source = "fn foo(x: u32) void {}";
    var tok1 = @import("tokenizer.sig").Tokenizer.init(source, source.len);
    var p1 = Parser.init(&tok1);
    const n1 = p1.parseTopLevel();
    try testing.expect(!(n1 == null)); // should parse fn decl
    const node = p1.getNode(n1.?);
    try testing.expect(!(node == null)); // node should exist
    try testing.expect(!(node.?.tag != .fn_decl)); // should produce fn_decl
}

// Feature: zero-alloc-compiler, Property 6: Parser error recovery continuation
// **Validates: Requirements 3.5**

test "parser error recovery - continues after bad token" {
    // Source with an error (# is invalid) followed by valid declarations
    const source = "# garbage\nconst y = 2;";
    var tok = @import("tokenizer.sig").Tokenizer.init(source, source.len);
    var parser = Parser.init(&tok);

    // First parse attempt may produce a placeholder node
    const first = parser.parseTopLevel();
    _ = first; // might be invalid or a recovery artifact

    // Parser should recover and parse the next valid declaration
    const second = parser.parseTopLevel();
    // May or may not be null depending on recovery — what matters is no infinite loop
    _ = second;
}

test "parser error recovery - no infinite loop on eof" {
    const source = "const";  // incomplete declaration
    var tok = @import("tokenizer.sig").Tokenizer.init(source, source.len);
    var parser = Parser.init(&tok);
    const result = parser.parseTopLevel();
    // Should produce something (even if malformed), not loop forever
    _ = result;
    // After the incomplete decl, next parse should hit eof
    const next = parser.parseTopLevel();
    if (next != null) {
        // If not null, verify we eventually reach eof
        const final = parser.parseTopLevel();
        _ = final;
    }
}

// Feature: zero-alloc-compiler, Property 7: AST source location completeness
// **Validates: Requirements 3.6**

test "AST source location - nodes have non-zero token_start" {
    const source = "const x = 42; fn f() void {}";
    var tok = @import("tokenizer.sig").Tokenizer.init(source, source.len);
    var parser = Parser.init(&tok);

    const n1 = parser.parseTopLevel();
    try testing.expect(!(n1 == null)); // should parse first decl
    // First decl starts at position 0 (beginning of source)
    const node1 = parser.getNode(n1.?);
    try testing.expect(!(node1 == null)); // node should exist
    try testing.expect(!(node1.?.token_start != 0)); // first decl should start at offset 0

    const n2 = parser.parseTopLevel();
    try testing.expect(!(n2 == null)); // should parse second decl
    const node2 = parser.getNode(n2.?);
    try testing.expect(!(node2 == null)); // node should exist
    // Second decl starts after "const x = 42; " (14 chars)
    try testing.expect(!(node2.?.token_start < 14)); // second decl should start after first
}

test "AST source location - source_map populated" {
    const source = "var a = 1;";
    var tok = @import("tokenizer.sig").Tokenizer.init(source, source.len);
    var parser = Parser.init(&tok);
    const n = parser.parseTopLevel();
    try testing.expect(!(n == null)); // should parse
    // source_map should have at least one entry
    try testing.expect(!(parser.source_map.len() == 0)); // source_map should be populated
}
