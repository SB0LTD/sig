//! Layer 0 — Core Data Types
//!
//! Pure data type definitions for the zero-alloc compiler pipeline.
//! No I/O, no imports from other project modules.
//! All types are comptime-sized and designed for stack or static allocation.

// ============================================================================
// Source Location
// ============================================================================

/// Compact source location reference for error reporting and debug info.
pub const Source_Loc = struct {
    file: u16,
    line: u32,
    column: u16,
};

// ============================================================================
// Token
// ============================================================================

/// A lexical token produced by the streaming tokenizer.
/// Carries a tag identifying the token kind and byte offsets into source.
pub const Token = struct {
    tag: Tag,
    start: u32, // byte offset in source
    end: u32, // byte offset in source

    pub const Tag = enum(u16) {
        // --- Keywords ---
        keyword_const,
        keyword_var,
        keyword_fn,
        keyword_pub,
        keyword_comptime,
        keyword_if,
        keyword_else,
        keyword_while,
        keyword_for,
        keyword_return,
        keyword_struct,
        keyword_enum,
        keyword_union,
        keyword_switch,
        keyword_break,
        keyword_continue,
        keyword_defer,
        keyword_errdefer,
        keyword_try,
        keyword_catch,
        keyword_orelse,
        keyword_unreachable,
        keyword_test,
        keyword_usingnamespace,
        keyword_asm,
        keyword_volatile,
        keyword_inline,
        keyword_noalias,
        keyword_threadlocal,
        keyword_allowzero,
        keyword_anytype,
        keyword_extern,
        keyword_export,
        keyword_align,
        keyword_linksection,
        keyword_callconv,
        keyword_nosuspend,
        keyword_async,
        keyword_await,
        keyword_suspend,
        keyword_resume,
        keyword_opaque,
        keyword_error,
        keyword_and,
        keyword_or,
        keyword_undefined,
        keyword_null,
        keyword_true,
        keyword_false,
        keyword_packed,
        keyword_anyframe,
        keyword_type,
        keyword_noreturn,
        keyword_void,
        keyword_bool,

        // --- Identifiers and literals ---
        identifier,
        string_literal,
        multiline_string_literal,
        number_literal,
        char_literal,

        // --- Operators ---
        plus,
        minus,
        asterisk,
        slash,
        percent,
        ampersand,
        pipe,
        caret,
        tilde,
        equal,
        bang,
        less_than,
        greater_than,
        plus_equal,
        minus_equal,
        asterisk_equal,
        slash_equal,
        percent_equal,
        ampersand_equal,
        pipe_equal,
        caret_equal,
        equal_equal,
        bang_equal,
        less_equal,
        greater_equal,
        less_less,
        greater_greater,
        less_less_equal,
        greater_greater_equal,
        ampersand_ampersand,
        pipe_pipe,
        plus_plus,
        asterisk_asterisk,

        // --- Punctuation ---
        l_paren,
        r_paren,
        l_bracket,
        r_bracket,
        l_brace,
        r_brace,
        comma,
        colon,
        semicolon,
        dot,
        ellipsis,
        at_sign,
        question_mark,
        arrow,
        fat_arrow,

        // --- Sig extensions ---
        sig_keyword_extended,

        // --- Special ---
        doc_comment,
        container_doc_comment,
        invalid,
        eof,
    };
};

// ============================================================================
// AST_Node
// ============================================================================

/// A node in the abstract syntax tree, stored in a fixed-capacity pool.
/// The tag determines which variant of the data union is active.
pub const AST_Node = struct {
    tag: Tag,
    /// Index of first token (for source location reconstruction).
    token_start: u32,
    /// Payload depends on tag.
    data: Data,

    pub const Tag = enum(u16) {
        // --- Declarations ---
        fn_decl,
        var_decl,
        const_decl,
        struct_decl,
        enum_decl,
        union_decl,
        error_set_decl,
        test_decl,
        field_decl,
        param_decl,

        // --- Expressions ---
        binary_expr,
        unary_expr,
        call_expr,
        field_access,
        index_access,
        slice_expr,
        deref_expr,
        address_of_expr,
        optional_unwrap,
        try_expr,
        catch_expr,
        orelse_expr,
        comptime_expr,
        inline_asm,
        builtin_call,
        array_init,
        struct_init,
        grouped_expr,
        error_value,

        // --- Statements ---
        block,
        if_stmt,
        while_stmt,
        for_stmt,
        return_stmt,
        break_stmt,
        continue_stmt,
        defer_stmt,
        errdefer_stmt,
        assign_stmt,
        switch_stmt,

        // --- Literals ---
        integer_literal,
        float_literal,
        string_literal,
        char_literal,
        enum_literal,
        null_literal,
        undefined_literal,
        bool_literal,
        identifier_ref,

        // --- Types ---
        pointer_type,
        array_type,
        slice_type,
        optional_type,
        error_union_type,
        fn_type,
    };

    pub const Data = union {
        binary: struct { lhs: u32, rhs: u32 },
        unary: struct { operand: u32 },
        call: struct { callee: u32, args_start: u32, args_count: u16 },
        decl: struct { name_token: u32, type_node: u32, value_node: u32 },
        block: struct { stmts_start: u32, stmts_count: u16 },
        leaf: struct { token: u32 },
    };
};

// ============================================================================
// Symbol_Entry
// ============================================================================

/// An entry in the fixed-capacity symbol table.
/// Tracks declaration info, type, scope, and LRU timestamp for eviction.
pub const Symbol_Entry = struct {
    name_hash: u64,
    name: [256]u8 = undefined,
    name_len: u8 = 0,
    /// Type index into the type intern pool.
    type_index: u32,
    /// Scope depth where declared.
    scope_depth: u16,
    /// Source location for error reporting.
    decl_file: u16,
    decl_line: u32,
    decl_column: u16,
    /// LRU timestamp for eviction.
    last_referenced: u32,
    /// Flags.
    is_pub: bool = false,
    is_comptime: bool = false,
    is_exported: bool = false,
};

// ============================================================================
// Type_Descriptor
// ============================================================================

/// Describes a type in the compiler's type intern pool.
/// The tag identifies the kind; the data union carries kind-specific info.
pub const Type_Descriptor = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum(u8) {
        void,
        @"bool",
        int,
        float,
        pointer,
        array,
        slice,
        @"struct",
        @"enum",
        @"union",
        @"fn",
        optional,
        error_union,
        error_set,
        comptime_int,
        comptime_float,
        @"type",
        any_type,
        @"noreturn",
    };

    pub const Data = union {
        int: struct { bits: u16, signed: bool },
        float: struct { bits: u16 },
        pointer: struct { pointee: u32, is_const: bool, is_volatile: bool },
        array: struct { element: u32, len: u64 },
        slice: struct { element: u32 },
        structure: struct { fields_start: u32, field_count: u16 },
        enumeration: struct { tag_type: u32, field_count: u16 },
        function: struct { params_start: u32, param_count: u8, return_type: u32 },
        optional: struct { child: u32 },
        error_union: struct { error_set: u32, payload: u32 },
    };
};

// ============================================================================
// Relocation
// ============================================================================

/// A relocation entry for the linker, tracking where symbols are referenced
/// and what fixup is needed when final addresses are known.
pub const Relocation = struct {
    /// Offset within the section where the relocation applies.
    offset: u64,
    /// Symbol index being referenced.
    symbol_index: u32,
    /// Relocation type (architecture-specific).
    rel_type: Rel_Type,
    /// Addend for RELA-style relocations.
    addend: i64,

    pub const Rel_Type = enum(u16) {
        // x86_64
        r_x86_64_pc32,
        r_x86_64_plt32,
        r_x86_64_64,
        r_x86_64_32,
        r_x86_64_32s,
        r_x86_64_gotpcrel,
        // aarch64
        r_aarch64_call26,
        r_aarch64_adr_prel_pg_hi21,
        r_aarch64_add_abs_lo12_nc,
        r_aarch64_ldst64_abs_lo12_nc,
        // ARM (armv7a)
        r_arm_call,
        r_arm_movw_abs_nc,
        r_arm_movt_abs,
        r_arm_prel31,
        // RISC-V
        r_riscv_call,
        r_riscv_hi20,
        r_riscv_lo12_i,
        r_riscv_lo12_s,
        r_riscv_pcrel_hi20,
        // WebAssembly
        r_wasm_function_index,
        r_wasm_table_index,
        r_wasm_memory_addr,
        r_wasm_global_index,
    };
};

// ============================================================================
// IR_Node
// ============================================================================

/// An intermediate representation node bridging semantic analysis to codegen.
/// Produced by sema, consumed by the code generator.
pub const IR_Node = struct {
    tag: Tag,
    data: Data,
    /// Result type index into the type intern pool.
    type_index: u32,

    pub const Tag = enum(u16) {
        // --- Constants and memory ---
        constant,
        load,
        store,
        alloca,

        // --- Arithmetic ---
        add,
        sub,
        mul,
        div_signed,
        div_unsigned,
        mod_signed,
        mod_unsigned,
        neg,

        // --- Bitwise ---
        bit_and,
        bit_or,
        bit_xor,
        bit_not,
        shl,
        shr,

        // --- Comparison ---
        cmp_eq,
        cmp_ne,
        cmp_lt,
        cmp_gt,
        cmp_le,
        cmp_ge,

        // --- Control flow ---
        branch,
        jump,
        call,
        ret,
        phi,
        @"unreachable",

        // --- Type conversion ---
        cast_int_to_float,
        cast_float_to_int,
        cast_trunc,
        cast_extend_signed,
        cast_extend_unsigned,
        cast_ptr_to_int,
        cast_int_to_ptr,
        cast_bitcast,

        // --- Aggregate access ---
        get_element_ptr,
        extract_value,
        insert_value,

        // --- Misc ---
        nop,
    };

    pub const Data = union {
        binary: struct { lhs: u32, rhs: u32 },
        unary: struct { operand: u32 },
        constant: struct { value: u64 },
        branch: struct { cond: u32, then_block: u32, else_block: u32 },
        call: struct { callee: u32, args_start: u32, args_count: u16 },
        none: void,
    };
};
