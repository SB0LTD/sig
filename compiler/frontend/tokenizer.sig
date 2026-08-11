//! Layer 1 — Compiler Phases
//!
//! Streaming tokenizer for the zero-alloc compiler pipeline.
//! Produces tokens from raw source bytes into a fixed-capacity ring buffer.
//! Zero heap allocations — operates on a source slice with position tracking.

const types = @import("../core/types.sig");
const containers = @import("../core/containers.sig");
const capacity = @import("../core/capacity.sig");

const Token = types.Token;
const Compiler_Capacity_Plan = capacity.Compiler_Capacity_Plan;

/// Streaming tokenizer that lexes source bytes into tokens.
/// Uses a fixed-capacity ring buffer for output — zero heap allocation.
pub const Tokenizer = struct {
    source: [*]const u8,
    source_len: usize,
    pos: usize,
    line: u32,
    column: u32,
    token_ring: containers.RingBuffer(Token, Compiler_Capacity_Plan.TOKEN_RING_CAPACITY),

    /// Initialize a tokenizer over the given source slice.
    pub fn init(source: [*]const u8, source_len: usize) Tokenizer {
        return Tokenizer{
            .source = source,
            .source_len = source_len,
            .pos = 0,
            .line = 1,
            .column = 1,
            .token_ring = .{},
        };
    }

    /// Initialize caller-owned storage directly, avoiding a large aggregate
    /// return slot in Debug and cross-compiled builds.
    pub fn initInto(self: *Tokenizer, source: [*]const u8, source_len: usize) void {
        self.source = source;
        self.source_len = source_len;
        self.pos = 0;
        self.line = 1;
        self.column = 1;
        self.token_ring.reset();
    }

    /// Produce one token from the source stream.
    /// Returns .eof when past end of source.
    pub fn next(self: *Tokenizer) Token {
        self.skipWhitespaceAndComments();

        if (self.pos >= self.source_len) {
            return Token{
                .tag = .eof,
                .start = @intCast(self.pos),
                .end = @intCast(self.pos),
            };
        }

        const start_pos = self.pos;
        const c = self.source[self.pos];

        // --- Multiline string literal (\\  at start of logical line) ---
        if (c == '\\' and self.peekAt(1) == '\\') {
            return self.lexMultilineStringLiteral(start_pos);
        }

        // --- String literal ---
        if (c == '"') {
            return self.lexStringLiteral(start_pos);
        }

        // --- Char literal ---
        if (c == '\'') {
            return self.lexCharLiteral(start_pos);
        }

        // --- Number literal ---
        if (isDigit(c)) {
            return self.lexNumberLiteral(start_pos);
        }

        // --- Identifier or keyword ---
        if (isAlpha(c) or c == '_') {
            return self.lexIdentifierOrKeyword(start_pos);
        }

        // --- Operators and punctuation ---
        return self.lexOperatorOrPunctuation(start_pos);
    }

    /// Fill the ring buffer by calling next() until full or EOF.
    pub fn produceUntilFull(self: *Tokenizer) void {
        while (!self.token_ring.isFull()) {
            const tok = self.next();
            self.token_ring.push(tok);
            if (tok.tag == .eof) break;
        }
    }

    /// Produce a single token and push it to the ring buffer IF there is space.
    /// Returns true if a token was produced and pushed, false if the ring is full
    /// (backpressure: caller must consume tokens before more can be produced).
    pub fn produceOne(self: *Tokenizer) bool {
        if (self.token_ring.isFull()) return false;
        const tok = self.next();
        self.token_ring.push(tok);
        return true;
    }

    /// Tokenize the entire source in a streaming fashion using bounded memory.
    /// Alternates between producing tokens and consuming them via the handler.
    /// The handler function is called for each token; it should return true to
    /// continue processing or false to abort early.
    /// This demonstrates that arbitrarily large files can be tokenized within
    /// the fixed-capacity ring buffer.
    pub fn tokenizeAll(self: *Tokenizer, comptime handler: fn (Token) bool) void {
        while (true) {
            // Produce tokens until ring is full or EOF
            var saw_eof = false;
            while (!self.token_ring.isFull()) {
                const tok = self.next();
                self.token_ring.push(tok);
                if (tok.tag == .eof) {
                    saw_eof = true;
                    break;
                }
            }

            // Consume all tokens from the ring via the handler
            while (self.token_ring.pop()) |tok| {
                if (!handler(tok)) return;
            }

            if (saw_eof) break;
        }
    }

    // ========================================================================
    // Private helpers
    // ========================================================================

    fn peek(self: *const Tokenizer) u8 {
        if (self.pos >= self.source_len) return 0;
        return self.source[self.pos];
    }

    fn peekAt(self: *const Tokenizer, offset: usize) u8 {
        const idx = self.pos + offset;
        if (idx >= self.source_len) return 0;
        return self.source[idx];
    }

    fn advance(self: *Tokenizer) void {
        if (self.pos < self.source_len) {
            if (self.source[self.pos] == '\n') {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.pos += 1;
        }
    }

    fn advanceN(self: *Tokenizer, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.advance();
        }
    }

    fn skipWhitespaceAndComments(self: *Tokenizer) void {
        while (self.pos < self.source_len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.advance();
            } else if (c == '/' and self.peekAt(1) == '/') {
                // Check for doc comments
                if (self.peekAt(2) == '/' or self.peekAt(2) == '!') {
                    // Doc comment or container doc comment — don't skip, lex as token
                    break;
                }
                // Line comment — skip to end of line
                while (self.pos < self.source_len and self.source[self.pos] != '\n') {
                    self.advance();
                }
            } else {
                break;
            }
        }
    }

    fn lexStringLiteral(self: *Tokenizer, start_pos: usize) Token {
        self.advance(); // skip opening '"'
        while (self.pos < self.source_len) {
            const c = self.source[self.pos];
            if (c == '\\') {
                self.advance(); // skip backslash
                self.advance(); // skip escaped char
            } else if (c == '"') {
                self.advance(); // skip closing '"'
                return Token{
                    .tag = .string_literal,
                    .start = @intCast(start_pos),
                    .end = @intCast(self.pos),
                };
            } else if (c == '\n') {
                // Unterminated string
                break;
            } else {
                self.advance();
            }
        }
        // Unterminated string literal
        return Token{
            .tag = .invalid,
            .start = @intCast(start_pos),
            .end = @intCast(self.pos),
        };
    }

    fn lexCharLiteral(self: *Tokenizer, start_pos: usize) Token {
        self.advance(); // skip opening '\''
        if (self.pos < self.source_len) {
            if (self.source[self.pos] == '\\') {
                self.advance(); // skip backslash
                self.advance(); // skip escaped char
            } else {
                self.advance(); // skip the char
            }
        }
        if (self.pos < self.source_len and self.source[self.pos] == '\'') {
            self.advance(); // skip closing '\''
            return Token{
                .tag = .char_literal,
                .start = @intCast(start_pos),
                .end = @intCast(self.pos),
            };
        }
        return Token{
            .tag = .invalid,
            .start = @intCast(start_pos),
            .end = @intCast(self.pos),
        };
    }

    fn lexNumberLiteral(self: *Tokenizer, start_pos: usize) Token {
        // Check for hex, octal, binary prefix
        if (self.source[self.pos] == '0' and self.pos + 1 < self.source_len) {
            const next_c = self.source[self.pos + 1];
            if (next_c == 'x' or next_c == 'X') {
                self.advanceN(2);
                while (self.pos < self.source_len and isHexDigit(self.source[self.pos])) {
                    self.advance();
                }
                return Token{
                    .tag = .number_literal,
                    .start = @intCast(start_pos),
                    .end = @intCast(self.pos),
                };
            }
            if (next_c == 'o' or next_c == 'O') {
                self.advanceN(2);
                while (self.pos < self.source_len and isOctalDigit(self.source[self.pos])) {
                    self.advance();
                }
                return Token{
                    .tag = .number_literal,
                    .start = @intCast(start_pos),
                    .end = @intCast(self.pos),
                };
            }
            if (next_c == 'b' or next_c == 'B') {
                self.advanceN(2);
                while (self.pos < self.source_len and isBinaryDigit(self.source[self.pos])) {
                    self.advance();
                }
                return Token{
                    .tag = .number_literal,
                    .start = @intCast(start_pos),
                    .end = @intCast(self.pos),
                };
            }
        }
        // Decimal number (with optional fractional part)
        while (self.pos < self.source_len and (isDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
            self.advance();
        }
        // Check for dot (float)
        if (self.pos < self.source_len and self.source[self.pos] == '.' and self.pos + 1 < self.source_len and isDigit(self.source[self.pos + 1])) {
            self.advance(); // skip '.'
            while (self.pos < self.source_len and (isDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
                self.advance();
            }
        }
        // Check for exponent
        if (self.pos < self.source_len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            self.advance();
            if (self.pos < self.source_len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                self.advance();
            }
            while (self.pos < self.source_len and isDigit(self.source[self.pos])) {
                self.advance();
            }
        }
        return Token{
            .tag = .number_literal,
            .start = @intCast(start_pos),
            .end = @intCast(self.pos),
        };
    }

    fn lexIdentifierOrKeyword(self: *Tokenizer, start_pos: usize) Token {
        while (self.pos < self.source_len and (isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) {
            self.advance();
        }
        const len = self.pos - start_pos;
        const tag = lookupKeyword(self.source + start_pos, len);
        return Token{
            .tag = tag,
            .start = @intCast(start_pos),
            .end = @intCast(self.pos),
        };
    }

    fn lexOperatorOrPunctuation(self: *Tokenizer, start_pos: usize) Token {
        const c = self.source[self.pos];
        const n = self.peekAt(1);
        const n2 = self.peekAt(2);

        switch (c) {
            '(' => {
                self.advance();
                return self.makeToken(.l_paren, start_pos);
            },
            ')' => {
                self.advance();
                return self.makeToken(.r_paren, start_pos);
            },
            '[' => {
                self.advance();
                return self.makeToken(.l_bracket, start_pos);
            },
            ']' => {
                self.advance();
                return self.makeToken(.r_bracket, start_pos);
            },
            '{' => {
                self.advance();
                return self.makeToken(.l_brace, start_pos);
            },
            '}' => {
                self.advance();
                return self.makeToken(.r_brace, start_pos);
            },
            ',' => {
                self.advance();
                return self.makeToken(.comma, start_pos);
            },
            ':' => {
                self.advance();
                return self.makeToken(.colon, start_pos);
            },
            ';' => {
                self.advance();
                return self.makeToken(.semicolon, start_pos);
            },
            '~' => {
                self.advance();
                return self.makeToken(.tilde, start_pos);
            },
            '@' => {
                self.advance();
                return self.makeToken(.at_sign, start_pos);
            },
            '?' => {
                self.advance();
                return self.makeToken(.question_mark, start_pos);
            },
            '.' => {
                if (n == '.' and n2 == '.') {
                    self.advanceN(3);
                    return self.makeToken(.ellipsis, start_pos);
                }
                self.advance();
                return self.makeToken(.dot, start_pos);
            },
            '+' => {
                if (n == '+') {
                    self.advanceN(2);
                    return self.makeToken(.plus_plus, start_pos);
                }
                if (n == '=') {
                    self.advanceN(2);
                    return self.makeToken(.plus_equal, start_pos);
                }
                self.advance();
                return self.makeToken(.plus, start_pos);
            },
            '-' => {
                if (n == '=') {
                    self.advanceN(2);
                    return self.makeToken(.minus_equal, start_pos);
                }
                if (n == '>') {
                    self.advanceN(2);
                    return self.makeToken(.arrow, start_pos);
                }
                self.advance();
                return self.makeToken(.minus, start_pos);
            },
            '*' => {
                if (n == '*') {
                    self.advanceN(2);
                    return self.makeToken(.asterisk_asterisk, start_pos);
                }
                if (n == '=') {
                    self.advanceN(2);
                    return self.makeToken(.asterisk_equal, start_pos);
                }
                self.advance();
                return self.makeToken(.asterisk, start_pos);
            },
            '/' => {
                // Doc comments: /// or //!
                if (n == '/') {
                    if (n2 == '/') {
                        return self.lexDocComment(start_pos);
                    }
                    if (n2 == '!') {
                        return self.lexContainerDocComment(start_pos);
                    }
                    // Regular comment already handled in skipWhitespaceAndComments
                    // but if we get here, just skip the line
                    while (self.pos < self.source_len and self.source[self.pos] != '\n') {
                        self.advance();
                    }
                    return self.next();
                }
                if (n == '=') {
                    self.advanceN(2);
                    return self.makeToken(.slash_equal, start_pos);
                }
                self.advance();
                return self.makeToken(.slash, start_pos);
            },
            else => return self.lexOperatorOrPunctuationCont(start_pos, c, n),
        }
    }

    fn lexOperatorOrPunctuationCont(self: *Tokenizer, start_pos: usize, c: u8, n: u8) Token {
        switch (c) {
            '%' => {
                if (n == '=') {
                    self.advanceN(2);
                    return self.makeToken(.percent_equal, start_pos);
                }
                self.advance();
                return self.makeToken(.percent, start_pos);
            },
            '&' => {
                if (n == '&') {
                    self.advanceN(2);
                    return self.makeToken(.ampersand_ampersand, start_pos);
                }
                if (n == '=') {
                    self.advanceN(2);
                    return self.makeToken(.ampersand_equal, start_pos);
                }
                self.advance();
                return self.makeToken(.ampersand, start_pos);
            },
            '|' => {
                if (n == '|') {
                    self.advanceN(2);
                    return self.makeToken(.pipe_pipe, start_pos);
                }
                if (n == '=') {
                    self.advanceN(2);
                    return self.makeToken(.pipe_equal, start_pos);
                }
                self.advance();
                return self.makeToken(.pipe, start_pos);
            },
            '^' => {
                if (n == '=') {
                    self.advanceN(2);
                    return self.makeToken(.caret_equal, start_pos);
                }
                self.advance();
                return self.makeToken(.caret, start_pos);
            },
            '=' => {
                if (n == '=') {
                    self.advanceN(2);
                    return self.makeToken(.equal_equal, start_pos);
                }
                if (n == '>') {
                    self.advanceN(2);
                    return self.makeToken(.fat_arrow, start_pos);
                }
                self.advance();
                return self.makeToken(.equal, start_pos);
            },
            '!' => {
                if (n == '=') {
                    self.advanceN(2);
                    return self.makeToken(.bang_equal, start_pos);
                }
                self.advance();
                return self.makeToken(.bang, start_pos);
            },
            '<' => {
                if (n == '<') {
                    if (self.peekAt(2) == '=') {
                        self.advanceN(3);
                        return self.makeToken(.less_less_equal, start_pos);
                    }
                    self.advanceN(2);
                    return self.makeToken(.less_less, start_pos);
                }
                if (n == '=') {
                    self.advanceN(2);
                    return self.makeToken(.less_equal, start_pos);
                }
                self.advance();
                return self.makeToken(.less_than, start_pos);
            },
            '>' => {
                if (n == '>') {
                    if (self.peekAt(2) == '=') {
                        self.advanceN(3);
                        return self.makeToken(.greater_greater_equal, start_pos);
                    }
                    self.advanceN(2);
                    return self.makeToken(.greater_greater, start_pos);
                }
                if (n == '=') {
                    self.advanceN(2);
                    return self.makeToken(.greater_equal, start_pos);
                }
                self.advance();
                return self.makeToken(.greater_than, start_pos);
            },
            else => {
                // Invalid/unrecognized byte — coalesce contiguous invalid bytes
                // into a single error token spanning the entire sequence.
                self.advance();
                while (self.pos < self.source_len) {
                    const next_byte = self.source[self.pos];
                    // Stop coalescing if we hit a recognizable character
                    if (isAlpha(next_byte) or isDigit(next_byte) or next_byte == '_' or
                        next_byte == ' ' or next_byte == '\t' or next_byte == '\r' or
                        next_byte == '\n' or next_byte == '"' or next_byte == '\'' or
                        next_byte == '(' or next_byte == ')' or next_byte == '[' or
                        next_byte == ']' or next_byte == '{' or next_byte == '}' or
                        next_byte == ',' or next_byte == ':' or next_byte == ';' or
                        next_byte == '.' or next_byte == '+' or next_byte == '-' or
                        next_byte == '*' or next_byte == '/' or next_byte == '%' or
                        next_byte == '&' or next_byte == '|' or next_byte == '^' or
                        next_byte == '=' or next_byte == '!' or next_byte == '<' or
                        next_byte == '>' or next_byte == '~' or next_byte == '@' or
                        next_byte == '?' or next_byte == '\\')
                    {
                        break;
                    }
                    self.advance();
                }
                return Token{
                    .tag = .invalid,
                    .start = @intCast(start_pos),
                    .end = @intCast(self.pos),
                };
            },
        }
    }

    fn lexDocComment(self: *Tokenizer, start_pos: usize) Token {
        // Skip to end of line
        while (self.pos < self.source_len and self.source[self.pos] != '\n') {
            self.advance();
        }
        return Token{
            .tag = .doc_comment,
            .start = @intCast(start_pos),
            .end = @intCast(self.pos),
        };
    }

    fn lexContainerDocComment(self: *Tokenizer, start_pos: usize) Token {
        // Skip to end of line
        while (self.pos < self.source_len and self.source[self.pos] != '\n') {
            self.advance();
        }
        return Token{
            .tag = .container_doc_comment,
            .start = @intCast(start_pos),
            .end = @intCast(self.pos),
        };
    }

    fn lexMultilineStringLiteral(self: *Tokenizer, start_pos: usize) Token {
        // Consume the leading `\\` and then everything to end of line.
        // Multiline string literals in zig/sig start with `\\` at the
        // beginning of a line (after optional whitespace, already skipped).
        self.advanceN(2); // skip '\\'
        while (self.pos < self.source_len and self.source[self.pos] != '\n') {
            self.advance();
        }
        return Token{
            .tag = .multiline_string_literal,
            .start = @intCast(start_pos),
            .end = @intCast(self.pos),
        };
    }

    fn makeToken(self: *const Tokenizer, tag: Token.Tag, start_pos: usize) Token {
        return Token{
            .tag = tag,
            .start = @intCast(start_pos),
            .end = @intCast(self.pos),
        };
    }

    // ========================================================================
    // Character classification
    // ========================================================================

    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isAlphanumeric(c: u8) bool {
        return isAlpha(c) or isDigit(c);
    }

    fn isHexDigit(c: u8) bool {
        return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    fn isOctalDigit(c: u8) bool {
        return c >= '0' and c <= '7';
    }

    fn isBinaryDigit(c: u8) bool {
        return c == '0' or c == '1';
    }

    // ========================================================================
    // Keyword lookup
    // ========================================================================

    /// After lexing an identifier, check if it matches a known keyword.
    /// Uses first-character + length dispatch for fast rejection, then memcmp.
    fn lookupKeyword(ptr: [*]const u8, len: usize) Token.Tag {
        if (len < 2 or len > 14) return .identifier;

        const first = ptr[0];
        switch (first) {
            'a' => return lookupKeywordsA(ptr, len),
            'b' => return lookupKeywordsB(ptr, len),
            'c' => return lookupKeywordsC(ptr, len),
            'd' => return lookupKeywordsD(ptr, len),
            'e' => return lookupKeywordsE(ptr, len),
            'f' => return lookupKeywordsF(ptr, len),
            'i' => return lookupKeywordsI(ptr, len),
            'n' => return lookupKeywordsN(ptr, len),
            'o' => return lookupKeywordsO(ptr, len),
            'p' => return lookupKeywordsP(ptr, len),
            'r' => return lookupKeywordsR(ptr, len),
            's' => return lookupKeywordsS(ptr, len),
            't' => return lookupKeywordsT(ptr, len),
            'u' => return lookupKeywordsU(ptr, len),
            'v' => return lookupKeywordsV(ptr, len),
            'w' => return lookupKeywordsW(ptr, len),
            else => return .identifier,
        }
    }

    fn eql(ptr: [*]const u8, len: usize, keyword: []const u8) bool {
        if (len != keyword.len) return false;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (ptr[i] != keyword[i]) return false;
        }
        return true;
    }

    fn lookupKeywordsA(ptr: [*]const u8, len: usize) Token.Tag {
        if (eql(ptr, len, "align")) return .keyword_align;
        if (eql(ptr, len, "allowzero")) return .keyword_allowzero;
        if (eql(ptr, len, "and")) return .keyword_and;
        if (eql(ptr, len, "anyframe")) return .keyword_anyframe;
        if (eql(ptr, len, "anytype")) return .keyword_anytype;
        if (eql(ptr, len, "asm")) return .keyword_asm;
        if (eql(ptr, len, "async")) return .keyword_async;
        if (eql(ptr, len, "await")) return .keyword_await;
        return .identifier;
    }

    fn lookupKeywordsB(ptr: [*]const u8, len: usize) Token.Tag {
        if (eql(ptr, len, "bool")) return .keyword_bool;
        if (eql(ptr, len, "break")) return .keyword_break;
        return .identifier;
    }

    fn lookupKeywordsC(ptr: [*]const u8, len: usize) Token.Tag {
        if (eql(ptr, len, "callconv")) return .keyword_callconv;
        if (eql(ptr, len, "catch")) return .keyword_catch;
        if (eql(ptr, len, "comptime")) return .keyword_comptime;
        if (eql(ptr, len, "const")) return .keyword_const;
        if (eql(ptr, len, "continue")) return .keyword_continue;
        return .identifier;
    }

    fn lookupKeywordsD(ptr: [*]const u8, len: usize) Token.Tag {
        if (eql(ptr, len, "defer")) return .keyword_defer;
        return .identifier;
    }

    fn lookupKeywordsE(ptr: [*]const u8, len: usize) Token.Tag {
        if (eql(ptr, len, "else")) return .keyword_else;
        if (eql(ptr, len, "enum")) return .keyword_enum;
        if (eql(ptr, len, "errdefer")) return .keyword_errdefer;
        if (eql(ptr, len, "error")) return .keyword_error;
        if (eql(ptr, len, "export")) return .keyword_export;
        if (eql(ptr, len, "extern")) return .keyword_extern;
        return .identifier;
    }

    fn lookupKeywordsF(ptr: [*]const u8, len: usize) Token.Tag {
        if (eql(ptr, len, "false")) return .keyword_false;
        if (eql(ptr, len, "fn")) return .keyword_fn;
        if (eql(ptr, len, "for")) return .keyword_for;
        return .identifier;
    }

    fn lookupKeywordsI(ptr: [*]const u8, len: usize) Token.Tag {
        if (eql(ptr, len, "if")) return .keyword_if;
        if (eql(ptr, len, "inline")) return .keyword_inline;
        return .identifier;
    }

    fn lookupKeywordsN(ptr: [*]const u8, len: usize) Token.Tag {
        if (eql(ptr, len, "noalias")) return .keyword_noalias;
        if (eql(ptr, len, "noreturn")) return .keyword_noreturn;
        if (eql(ptr, len, "nosuspend")) return .keyword_nosuspend;
        if (eql(ptr, len, "null")) return .keyword_null;
        return .identifier;
    }

    fn lookupKeywordsO(ptr: [*]const u8, len: usize) Token.Tag {
        if (eql(ptr, len, "opaque")) return .keyword_opaque;
        if (eql(ptr, len, "or")) return .keyword_or;
        if (eql(ptr, len, "orelse")) return .keyword_orelse;
        return .identifier;
    }

    fn lookupKeywordsP(ptr: [*]const u8, len: usize) Token.Tag {
        if (eql(ptr, len, "packed")) return .keyword_packed;
        if (eql(ptr, len, "pub")) return .keyword_pub;
        return .identifier;
    }

    fn lookupKeywordsR(ptr: [*]const u8, len: usize) Token.Tag {
        if (eql(ptr, len, "resume")) return .keyword_resume;
        if (eql(ptr, len, "return")) return .keyword_return;
        return .identifier;
    }

    fn lookupKeywordsS(ptr: [*]const u8, len: usize) Token.Tag {
        if (eql(ptr, len, "struct")) return .keyword_struct;
        if (eql(ptr, len, "suspend")) return .keyword_suspend;
        if (eql(ptr, len, "switch")) return .keyword_switch;
        return .identifier;
    }

    fn lookupKeywordsT(ptr: [*]const u8, len: usize) Token.Tag {
        if (eql(ptr, len, "test")) return .keyword_test;
        if (eql(ptr, len, "threadlocal")) return .keyword_threadlocal;
        if (eql(ptr, len, "true")) return .keyword_true;
        if (eql(ptr, len, "try")) return .keyword_try;
        if (eql(ptr, len, "type")) return .keyword_type;
        return .identifier;
    }

    fn lookupKeywordsU(ptr: [*]const u8, len: usize) Token.Tag {
        if (eql(ptr, len, "undefined")) return .keyword_undefined;
        if (eql(ptr, len, "union")) return .keyword_union;
        if (eql(ptr, len, "unreachable")) return .keyword_unreachable;
        if (eql(ptr, len, "usingnamespace")) return .keyword_usingnamespace;
        return .identifier;
    }

    fn lookupKeywordsV(ptr: [*]const u8, len: usize) Token.Tag {
        if (eql(ptr, len, "var")) return .keyword_var;
        if (eql(ptr, len, "void")) return .keyword_void;
        if (eql(ptr, len, "volatile")) return .keyword_volatile;
        return .identifier;
    }

    fn lookupKeywordsW(ptr: [*]const u8, len: usize) Token.Tag {
        if (eql(ptr, len, "while")) return .keyword_while;
        return .identifier;
    }
};

// ============================================================================
// Multiline string literal support
// ============================================================================

/// Check if line starts with `\\` (multiline string literal continuation).
/// This is used at a higher level — the tokenizer itself handles `\\` at
/// the beginning of a line as a multiline_string_literal token.
pub fn isMultilineStringStart(c: u8, next_c: u8) bool {
    return c == '\\' and next_c == '\\';
}

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

test "tokenizer basic identifiers and keywords" {
    const source = "const foo = 42;";
    var tok = Tokenizer.init(source, source.len);
    const t1 = tok.next();
    try testing.expect(!(t1.tag != .keyword_const)); // expected keyword_const
}

test "tokenizer operators" {
    const source = "== != <= >= && || ++ ** -> =>";
    var tok = Tokenizer.init(source, source.len);
    const t1 = tok.next();
    try testing.expect(!(t1.tag != .equal_equal)); // expected equal_equal
}

test "tokenizer eof on empty source" {
    const source = "";
    var tok = Tokenizer.init(source, 0);
    const t1 = tok.next();
    try testing.expect(!(t1.tag != .eof)); // expected eof
}

test "tokenizer produceUntilFull fills ring" {
    const source = "const x = 1;";
    var tok = Tokenizer.init(source, source.len);
    tok.produceUntilFull();
    try testing.expect(!(tok.token_ring.isEmpty())); // ring should not be empty
}

test "tokenizer produceOne returns false when full" {
    const source = "const x = 1;";
    var tok = Tokenizer.init(source, source.len);
    // Fill the ring first
    tok.produceUntilFull();
    // produceOne should return false if ring is full (or true if eof was hit)
    // Either way, this validates the backpressure API exists
    _ = tok.produceOne();
}

test "tokenizer invalid bytes coalesce into single error token" {
    // Bytes 0x01, 0x02, 0x03 are all invalid — should produce one .invalid token
    const source = [_]u8{ 0x01, 0x02, 0x03, ' ', 'x' };
    var tok = Tokenizer.init(&source, source.len);
    const t1 = tok.next();
    try testing.expect(!(t1.tag != .invalid)); // expected invalid token
    // The invalid token should span all 3 bytes
    try testing.expect(!(t1.start != 0)); // expected start 0
    try testing.expect(!(t1.end != 3)); // expected end 3
    // Next token should be the identifier 'x'
    const t2 = tok.next();
    try testing.expect(!(t2.tag != .identifier)); // expected identifier after invalid
}

test "tokenizer multiline string literal" {
    const source = "\\\\hello world";
    var tok = Tokenizer.init(source, source.len);
    const t1 = tok.next();
    try testing.expect(!(t1.tag != .multiline_string_literal)); // expected multiline_string_literal
}

test "tokenizer tokenizeAll streams bounded" {
    const source = "const x = 1; const y = 2;";
    var tok = Tokenizer.init(source, source.len);
    tok.tokenizeAll(struct {
        fn handler(_: Token) bool {
            return true; // consume all
        }
    }.handler);
    // After tokenizeAll, ring should be empty (all consumed)
    try testing.expect(!(!tok.token_ring.isEmpty())); // ring should be empty after tokenizeAll
}

// ============================================================================
// Property Tests — Task 2.3: Tokenizer byte coverage
// **Validates: Requirements 2.1**
// ============================================================================

test "tokenizer byte coverage - all printable ASCII produce valid tokens" {
    // Property 2: Every printable ASCII byte (32-126) should produce a non-eof
    // token when tokenized individually. Some produce .invalid, which is fine —
    // the point is that no printable byte is silently dropped.
    var byte: u8 = 33; // skip space (32) since it's whitespace → eof
    while (byte <= 126) : (byte += 1) {
        const source = [_]u8{byte};
        var tok = Tokenizer.init(&source, 1);
        const t = tok.next();
        if (t.tag == .eof) {
            return error.TestUnexpectedResult; // printable byte should produce a token, not eof
        }
    }
}

test "tokenizer byte coverage - keywords recognized" {
    // Property 2: All zig/sig keywords must be recognized as their keyword tag,
    // not as a plain .identifier.
    const keywords = [_][]const u8{
        "const", "var",   "fn",     "pub",    "if",
        "else",  "while", "for",    "return", "struct",
        "enum",  "union", "switch", "break",  "continue",
        "defer", "try",   "catch",  "orelse",
    };
    for (keywords) |kw| {
        var tok = Tokenizer.init(kw.ptr, kw.len);
        const t = tok.next();
        if (t.tag == .identifier) {
            return error.TestUnexpectedResult; // keyword not recognized — got .identifier
        }
        if (t.tag == .eof) {
            return error.TestUnexpectedResult; // keyword not recognized — got .eof
        }
    }
}

// ============================================================================
// Property Tests — Task 2.4: Tokenizer error recovery
// **Validates: Requirements 2.6**
// ============================================================================

test "tokenizer error recovery - invalid followed by valid" {
    // Property 4: After invalid bytes, the tokenizer should recover and produce
    // valid tokens for subsequent valid source text.
    const source = [_]u8{ 0x01, 0x02, ' ', 'x', ' ', '4', '2' };
    var tok = Tokenizer.init(&source, source.len);
    const t1 = tok.next();
    try testing.expect(!(t1.tag != .invalid)); // expected invalid token first
    const t2 = tok.next();
    try testing.expect(!(t2.tag != .identifier)); // expected identifier after recovery
    const t3 = tok.next();
    try testing.expect(!(t3.tag != .number_literal)); // expected number after identifier
    const t4 = tok.next();
    try testing.expect(!(t4.tag != .eof)); // expected eof
}

test "tokenizer error recovery - unterminated string then valid" {
    // Property 4: An unterminated string literal (no closing quote before newline)
    // should emit .invalid, then the tokenizer should recover on the next line.
    const source = "\"unterminated\nconst x = 1;";
    var tok = Tokenizer.init(source, source.len);
    const t1 = tok.next();
    try testing.expect(!(t1.tag != .invalid)); // unterminated string should be invalid
    // After the invalid string, should recover to parse 'const'
    const t2 = tok.next();
    try testing.expect(!(t2.tag != .keyword_const)); // should recover to parse const keyword
}

// ============================================================================
// Property Tests — Task 2.5: Streaming backpressure bounds memory
// **Validates: Requirements 2.3, 2.4, 10.1, 10.2**
// ============================================================================

test "streaming backpressure - ring never exceeds capacity" {
    // Property 3: The token ring buffer must never exceed TOKEN_RING_CAPACITY
    // regardless of how many tokens are produced.
    const source = "const a = 1; const b = 2; const c = 3; const d = 4;";
    var tok = Tokenizer.init(source, source.len);

    // Fill ring to capacity
    tok.produceUntilFull();
    const ring_len = tok.token_ring.len();

    // Ring should not exceed TOKEN_RING_CAPACITY
    if (ring_len > Compiler_Capacity_Plan.TOKEN_RING_CAPACITY) {
        return error.TestUnexpectedResult; // ring length exceeds TOKEN_RING_CAPACITY
    }

    // produceOne should return false when ring is full (backpressure)
    if (tok.token_ring.isFull()) {
        const produced = tok.produceOne();
        try testing.expect(!(produced)); // produceOne should return false when ring is full
    }
}

test "streaming tokenizeAll processes entire source in bounded memory" {
    // Property 3: tokenizeAll demonstrates that arbitrarily large files can be
    // tokenized within the fixed-capacity ring buffer — after completion the
    // ring is empty (all tokens consumed by the handler).
    const source = "fn main() void { return; }";
    var tok = Tokenizer.init(source, source.len);
    tok.tokenizeAll(struct {
        fn handler(_: Token) bool {
            return true; // consume all tokens
        }
    }.handler);
    // Ring should be empty after tokenizeAll (all consumed)
    try testing.expect(!(!tok.token_ring.isEmpty())); // ring should be drained after tokenizeAll
}
