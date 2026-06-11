//! This file is generated, do not edit manually! To generate, run:
//! zig run ./tools/gen_parser_oracle.zig -- ./doc/langref/grammar.peg > ./lib/std/zig/parser_generated_oracle.zig

const std = @import("std");

/// Returns true if the input source is in the language defined by
/// the grammar.
pub fn parse(source: []const u8) bool {
    var p: Parser = .{ .source = source, .i = 0 };
    return p.parseRoot();
}

const Parser = struct {
    source: []const u8,
    i: usize,
    pub fn parseRoot(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseskip() and p.parseContainerMembers() and p.parseeof()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseContainerMembers(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.parsecontainer_doc_comment() or true) and blk_1: {
                while (p.parseContainerDeclaration()) {}
                break :blk_1 true;
            } and blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseContainerField() and p.parseCOMMA()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            } and blk_2: {
                const pos_2 = p.i;
                if (p.parseContainerField()) break :blk_2 true;
                p.i = pos_2;
                if (blk_3: {
                    while (p.parseContainerDeclaration()) {}
                    break :blk_3 true;
                }) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseContainerDeclaration(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseTestDecl()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseComptimeDecl()) break :blk_0 true;
            p.i = pos_0;
            if ((p.parsedoc_comment() or true) and (p.parseKEYWORD_pub() or true) and p.parseDecl()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseTestDecl(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_test() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseSTRINGLITERALSINGLE()) break :blk_3 true;
                p.i = pos_3;
                if (p.parseIDENTIFIER()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and p.parseBlock()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseComptimeDecl(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_comptime() and p.parseBlock()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseDecl(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((blk_3: {
                const pos_3 = p.i;
                if (p.parseKEYWORD_export()) break :blk_3 true;
                p.i = pos_3;
                if (p.parseKEYWORD_inline()) break :blk_3 true;
                p.i = pos_3;
                if (p.parseKEYWORD_noinline()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and p.parseFnProto() and blk_2: {
                const pos_2 = p.i;
                if (p.parseSEMICOLON()) break :blk_2 true;
                p.i = pos_2;
                if (p.parseBlock()) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            }) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_extern() and (p.parseSTRINGLITERALSINGLE() or true) and p.parseFnProto() and p.parseSEMICOLON()) break :blk_0 true;
            p.i = pos_0;
            if ((blk_3: {
                const pos_3 = p.i;
                if (p.parseKEYWORD_export()) break :blk_3 true;
                p.i = pos_3;
                if (p.parseKEYWORD_extern() and (p.parseSTRINGLITERALSINGLE() or true)) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and (p.parseKEYWORD_threadlocal() or true) and p.parseGlobalVarDecl()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseFnProto(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_fn() and (p.parseIDENTIFIER() or true) and p.parseLPAREN() and p.parseParamDeclList() and p.parseRPAREN() and (p.parseByteAlign() or true) and (p.parseAddrSpace() or true) and (p.parseLinkSection() or true) and (p.parseCallConv() or true) and (p.parseEXCLAMATIONMARK() or true) and p.parseTypeExpr() and blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseExprSuffix();
                p.i = pos_1;
                break :blk_1 !match_1;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseVarDeclProto(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_2: {
                const pos_2 = p.i;
                if (p.parseKEYWORD_const()) break :blk_2 true;
                p.i = pos_2;
                if (p.parseKEYWORD_var()) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            } and p.parseIDENTIFIER() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseCOLON() and p.parseTypeExpr()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and (p.parseByteAlign() or true) and (p.parseAddrSpace() or true) and (p.parseLinkSection() or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseGlobalVarDecl(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseVarDeclProto() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseEQUAL() and p.parseExpr()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and p.parseSEMICOLON()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseContainerField(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.parsedoc_comment() or true) and blk_2: {
                const pos_2 = p.i;
                if (p.parseKEYWORD_comptime()) break :blk_2 true;
                p.i = pos_2;
                if (blk_3: {
                    const pos_3 = p.i;
                    const match_3 = p.parseKEYWORD_comptime();
                    p.i = pos_3;
                    break :blk_3 !match_3;
                }) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseKEYWORD_fn();
                p.i = pos_1;
                break :blk_1 !match_1;
            } and (blk_3: {
                const pos_3 = p.i;
                if (p.parseIDENTIFIER() and p.parseCOLON()) break :blk_3 true;
                p.i = pos_3;
                if (blk_4: {
                    const pos_4 = p.i;
                    const match_4 = blk_6: {
                        const pos_6 = p.i;
                        if (p.parseIDENTIFIER() and p.parseCOLON()) break :blk_6 true;
                        p.i = pos_6;
                        break :blk_6 false;
                    };
                    p.i = pos_4;
                    break :blk_4 !match_4;
                }) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and p.parseTypeExpr() and (p.parseByteAlign() or true) and (blk_3: {
                const pos_3 = p.i;
                if (p.parseEQUAL() and p.parseExpr()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseBlockStatement(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseStatement()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_defer() and p.parseBlockExprStatement()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_errdefer() and p.parseBlockExprStatement()) break :blk_0 true;
            p.i = pos_0;
            if (blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseExprStatement();
                p.i = pos_1;
                break :blk_1 !match_1;
            } and (blk_3: {
                const pos_3 = p.i;
                if (p.parseKEYWORD_comptime() and blk_4: {
                    const pos_4 = p.i;
                    const match_4 = p.parseBlockExpr();
                    p.i = pos_4;
                    break :blk_4 !match_4;
                }) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and p.parseVarAssignStatement()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseStatement(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseExprStatement()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_suspend() and p.parseBlockExprStatement()) break :blk_0 true;
            p.i = pos_0;
            if (blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseExprStatement();
                p.i = pos_1;
                break :blk_1 !match_1;
            } and (blk_3: {
                const pos_3 = p.i;
                if (p.parseKEYWORD_comptime() and blk_4: {
                    const pos_4 = p.i;
                    const match_4 = p.parseBlockExpr();
                    p.i = pos_4;
                    break :blk_4 !match_4;
                }) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and p.parseAssignExpr() and p.parseSEMICOLON()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseExprStatement(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseIfStatement()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseLabeledStatement()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_nosuspend() and p.parseBlockExprStatement()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_comptime() and p.parseBlockExpr()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseIfStatement(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseIfPrefix() and p.parseBlockExpr() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseKEYWORD_else() and (p.parsePayload() or true) and p.parseStatement()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true)) break :blk_0 true;
            p.i = pos_0;
            if (p.parseIfPrefix() and blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseBlockExpr();
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseAssignExpr() and blk_2: {
                const pos_2 = p.i;
                if (p.parseSEMICOLON()) break :blk_2 true;
                p.i = pos_2;
                if (p.parseKEYWORD_else() and (p.parsePayload() or true) and p.parseStatement()) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseLabeledStatement(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.parseBlockLabel() or true) and blk_2: {
                const pos_2 = p.i;
                if (p.parseBlock()) break :blk_2 true;
                p.i = pos_2;
                if (p.parseLoopStatement()) break :blk_2 true;
                p.i = pos_2;
                if (p.parseSwitchExpr()) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseLoopStatement(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.parseKEYWORD_inline() or true) and blk_2: {
                const pos_2 = p.i;
                if (p.parseForStatement()) break :blk_2 true;
                p.i = pos_2;
                if (p.parseWhileStatement()) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseForStatement(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseForPrefix() and p.parseBlockExpr() and blk_2: {
                const pos_2 = p.i;
                if (p.parseKEYWORD_else() and p.parseStatement()) break :blk_2 true;
                p.i = pos_2;
                if (blk_3: {
                    const pos_3 = p.i;
                    const match_3 = p.parseKEYWORD_else();
                    p.i = pos_3;
                    break :blk_3 !match_3;
                }) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            }) break :blk_0 true;
            p.i = pos_0;
            if (p.parseForPrefix() and blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseBlockExpr();
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseAssignExpr() and blk_2: {
                const pos_2 = p.i;
                if (p.parseSEMICOLON()) break :blk_2 true;
                p.i = pos_2;
                if (p.parseKEYWORD_else() and p.parseStatement()) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseWhileStatement(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseWhilePrefix() and p.parseBlockExpr() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseKEYWORD_else() and (p.parsePayload() or true) and p.parseStatement()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true)) break :blk_0 true;
            p.i = pos_0;
            if (p.parseWhilePrefix() and blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseBlockExpr();
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseAssignExpr() and blk_2: {
                const pos_2 = p.i;
                if (p.parseSEMICOLON()) break :blk_2 true;
                p.i = pos_2;
                if (p.parseKEYWORD_else() and (p.parsePayload() or true) and p.parseStatement()) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseBlockExprStatement(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseBlockExpr()) break :blk_0 true;
            p.i = pos_0;
            if (blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseBlockExpr();
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseAssignExpr() and p.parseSEMICOLON()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseBlockExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.parseBlockLabel() or true) and p.parseBlock()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseVarAssignStatement(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_2: {
                const pos_2 = p.i;
                if (p.parseVarDeclProto()) break :blk_2 true;
                p.i = pos_2;
                if (p.parseExpr()) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            } and blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseCOMMA() and blk_5: {
                        const pos_5 = p.i;
                        if (p.parseVarDeclProto()) break :blk_5 true;
                        p.i = pos_5;
                        if (p.parseExpr()) break :blk_5 true;
                        p.i = pos_5;
                        break :blk_5 false;
                    }) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            } and p.parseEQUAL() and p.parseExpr() and p.parseSEMICOLON()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseAssignExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseExpr() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseAssignOp() and p.parseExpr()) break :blk_3 true;
                p.i = pos_3;
                if (blk_4: {
                    var match_4 = false;
                    while (blk_6: {
                        const pos_6 = p.i;
                        if (p.parseCOMMA() and p.parseExpr()) break :blk_6 true;
                        p.i = pos_6;
                        break :blk_6 false;
                    }) {
                        match_4 = true;
                    }
                    break :blk_4 match_4;
                } and p.parseEQUAL() and p.parseExpr()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseSingleAssignExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseExpr() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseAssignOp() and p.parseExpr()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseBoolOrExpr()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseBoolOrExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseBoolAndExpr() and blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseKEYWORD_or() and p.parseBoolAndExpr()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseBoolAndExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseCompareExpr() and blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseKEYWORD_and() and p.parseCompareExpr()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseCompareExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseBitwiseExpr() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseCompareOp() and p.parseBitwiseExpr()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseBitwiseExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseBitShiftExpr() and blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseBitwiseOp() and p.parseBitShiftExpr()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseBitShiftExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseAdditionExpr() and blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseBitShiftOp() and p.parseAdditionExpr()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseAdditionExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseMultiplyExpr() and blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseAdditionOp() and p.parseMultiplyExpr()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseMultiplyExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parsePrefixExpr() and blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseMultiplyOp() and p.parsePrefixExpr()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePrefixExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                while (p.parsePrefixOp()) {}
                break :blk_1 true;
            } and p.parsePrimaryExpr()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePrimaryExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseAsmExpr()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseIfExpr()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_break() and blk_2: {
                const pos_2 = p.i;
                if (p.parseBreakLabel()) break :blk_2 true;
                p.i = pos_2;
                if (blk_3: {
                    const pos_3 = p.i;
                    const match_3 = p.parseBreakLabel();
                    p.i = pos_3;
                    break :blk_3 !match_3;
                }) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            } and blk_2: {
                const pos_2 = p.i;
                if (p.parseExpr() and blk_3: {
                    const pos_3 = p.i;
                    const match_3 = p.parseExprSuffix();
                    p.i = pos_3;
                    break :blk_3 !match_3;
                }) break :blk_2 true;
                p.i = pos_2;
                if (blk_3: {
                    const pos_3 = p.i;
                    const match_3 = p.parseSinglePtrTypeStart();
                    p.i = pos_3;
                    break :blk_3 !match_3;
                }) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            }) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_comptime() and p.parseExpr() and blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseExprSuffix();
                p.i = pos_1;
                break :blk_1 !match_1;
            }) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_nosuspend() and p.parseExpr() and blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseExprSuffix();
                p.i = pos_1;
                break :blk_1 !match_1;
            }) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_continue() and blk_2: {
                const pos_2 = p.i;
                if (p.parseBreakLabel()) break :blk_2 true;
                p.i = pos_2;
                if (blk_3: {
                    const pos_3 = p.i;
                    const match_3 = p.parseBreakLabel();
                    p.i = pos_3;
                    break :blk_3 !match_3;
                }) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            } and blk_2: {
                const pos_2 = p.i;
                if (p.parseExpr() and blk_3: {
                    const pos_3 = p.i;
                    const match_3 = p.parseExprSuffix();
                    p.i = pos_3;
                    break :blk_3 !match_3;
                }) break :blk_2 true;
                p.i = pos_2;
                if (blk_3: {
                    const pos_3 = p.i;
                    const match_3 = p.parseSinglePtrTypeStart();
                    p.i = pos_3;
                    break :blk_3 !match_3;
                }) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            }) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_resume() and p.parseExpr() and blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseExprSuffix();
                p.i = pos_1;
                break :blk_1 !match_1;
            }) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_return() and blk_2: {
                const pos_2 = p.i;
                if (p.parseExpr() and blk_3: {
                    const pos_3 = p.i;
                    const match_3 = p.parseExprSuffix();
                    p.i = pos_3;
                    break :blk_3 !match_3;
                }) break :blk_2 true;
                p.i = pos_2;
                if (blk_3: {
                    const pos_3 = p.i;
                    const match_3 = p.parseSinglePtrTypeStart();
                    p.i = pos_3;
                    break :blk_3 !match_3;
                }) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            }) break :blk_0 true;
            p.i = pos_0;
            if ((p.parseBlockLabel() or true) and p.parseLoopExpr()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseBlock()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseCurlySuffixExpr()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseIfExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseIfPrefix() and p.parseExpr() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseKEYWORD_else() and (p.parsePayload() or true) and p.parseExpr()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseExprSuffix();
                p.i = pos_1;
                break :blk_1 !match_1;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseBlock(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseLBRACE() and blk_1: {
                while (p.parseBlockStatement()) {}
                break :blk_1 true;
            } and p.parseRBRACE()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseLoopExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.parseKEYWORD_inline() or true) and blk_2: {
                const pos_2 = p.i;
                if (p.parseForExpr()) break :blk_2 true;
                p.i = pos_2;
                if (p.parseWhileExpr()) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseForExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseForPrefix() and p.parseExpr() and blk_2: {
                const pos_2 = p.i;
                if (p.parseKEYWORD_else() and p.parseExpr()) break :blk_2 true;
                p.i = pos_2;
                if (blk_3: {
                    const pos_3 = p.i;
                    const match_3 = p.parseKEYWORD_else();
                    p.i = pos_3;
                    break :blk_3 !match_3;
                }) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseExprSuffix();
                p.i = pos_1;
                break :blk_1 !match_1;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseWhileExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseWhilePrefix() and p.parseExpr() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseKEYWORD_else() and (p.parsePayload() or true) and p.parseExpr()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseExprSuffix();
                p.i = pos_1;
                break :blk_1 !match_1;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseCurlySuffixExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseTypeExpr() and (p.parseInitList() or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseInitList(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseLBRACE() and p.parseFieldInit() and blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseCOMMA() and p.parseFieldInit()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            } and (p.parseCOMMA() or true) and p.parseRBRACE()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseLBRACE() and p.parseExpr() and blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseCOMMA() and p.parseExpr()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            } and (p.parseCOMMA() or true) and p.parseRBRACE()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseLBRACE() and p.parseRBRACE()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseTypeExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                while (p.parsePrefixTypeOp()) {}
                break :blk_1 true;
            } and p.parseErrorUnionExpr()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseErrorUnionExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseSuffixExpr() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseEXCLAMATIONMARK() and p.parseTypeExpr()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseSuffixExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parsePrimaryTypeExpr() and blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseSuffixOp()) break :blk_3 true;
                    p.i = pos_3;
                    if (p.parseFnCallArguments()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePrimaryTypeExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseBUILTINIDENTIFIER() and p.parseFnCallArguments()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseCHAR_LITERAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseContainerDecl()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseDOT() and p.parseIDENTIFIER()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseDOT() and p.parseInitList()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseErrorSetDecl()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseFLOAT()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseFnProto()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseGroupedExpr()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseLabeledTypeExpr()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseIDENTIFIER() and blk_1: {
                const pos_1 = p.i;
                const match_1 = blk_3: {
                    const pos_3 = p.i;
                    if (p.parseCOLON() and p.parseLabelableExpr()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                };
                p.i = pos_1;
                break :blk_1 !match_1;
            }) break :blk_0 true;
            p.i = pos_0;
            if (p.parseIfTypeExpr()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseINTEGER()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_comptime() and p.parseTypeExpr() and blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseExprSuffix();
                p.i = pos_1;
                break :blk_1 !match_1;
            }) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_error() and p.parseDOT() and p.parseIDENTIFIER()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_anyframe()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_unreachable()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseSTRINGLITERAL()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseContainerDecl(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((blk_3: {
                const pos_3 = p.i;
                if (p.parseKEYWORD_extern()) break :blk_3 true;
                p.i = pos_3;
                if (p.parseKEYWORD_packed()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and p.parseContainerDeclAuto()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseErrorSetDecl(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_error() and p.parseLBRACE() and p.parseIdentifierList() and p.parseRBRACE()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseGroupedExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseLPAREN() and p.parseExpr() and p.parseRPAREN()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseIfTypeExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseIfPrefix() and p.parseTypeExpr() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseKEYWORD_else() and (p.parsePayload() or true) and p.parseTypeExpr()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseExprSuffix();
                p.i = pos_1;
                break :blk_1 !match_1;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseLabeledTypeExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseBlockLabel() and p.parseBlock()) break :blk_0 true;
            p.i = pos_0;
            if ((p.parseBlockLabel() or true) and p.parseLoopTypeExpr()) break :blk_0 true;
            p.i = pos_0;
            if ((p.parseBlockLabel() or true) and p.parseSwitchExpr()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseLoopTypeExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.parseKEYWORD_inline() or true) and blk_2: {
                const pos_2 = p.i;
                if (p.parseForTypeExpr()) break :blk_2 true;
                p.i = pos_2;
                if (p.parseWhileTypeExpr()) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseForTypeExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseForPrefix() and p.parseTypeExpr() and blk_2: {
                const pos_2 = p.i;
                if (p.parseKEYWORD_else() and p.parseTypeExpr()) break :blk_2 true;
                p.i = pos_2;
                if (blk_3: {
                    const pos_3 = p.i;
                    const match_3 = p.parseKEYWORD_else();
                    p.i = pos_3;
                    break :blk_3 !match_3;
                }) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseExprSuffix();
                p.i = pos_1;
                break :blk_1 !match_1;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseWhileTypeExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseWhilePrefix() and p.parseTypeExpr() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseKEYWORD_else() and (p.parsePayload() or true) and p.parseTypeExpr()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseExprSuffix();
                p.i = pos_1;
                break :blk_1 !match_1;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseSwitchExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_switch() and p.parseLPAREN() and p.parseExpr() and p.parseRPAREN() and p.parseLBRACE() and p.parseSwitchProngList() and p.parseRBRACE()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseAsmExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_asm() and (p.parseKEYWORD_volatile() or true) and p.parseLPAREN() and p.parseExpr() and (p.parseAsmOutput() or true) and p.parseRPAREN()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseAsmOutput(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseCOLON() and p.parseAsmOutputList() and (p.parseAsmInput() or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseAsmOutputItem(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseLBRACKET() and p.parseIDENTIFIER() and p.parseRBRACKET() and p.parseSTRINGLITERALSINGLE() and p.parseLPAREN() and blk_2: {
                const pos_2 = p.i;
                if (p.parseMINUSRARROW() and p.parseTypeExpr()) break :blk_2 true;
                p.i = pos_2;
                if (p.parseIDENTIFIER()) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            } and p.parseRPAREN()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseAsmInput(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseCOLON() and p.parseAsmInputList() and (p.parseAsmClobbers() or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseAsmInputItem(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseLBRACKET() and p.parseIDENTIFIER() and p.parseRBRACKET() and p.parseSTRINGLITERALSINGLE() and p.parseLPAREN() and p.parseExpr() and p.parseRPAREN()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseAsmClobbers(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseCOLON() and p.parseExpr()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseBreakLabel(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseCOLON() and p.parseIDENTIFIER()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseBlockLabel(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseIDENTIFIER() and p.parseCOLON()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseFieldInit(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseDOT() and p.parseIDENTIFIER() and p.parseEQUAL() and p.parseExpr()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseWhileContinueExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseCOLON() and p.parseLPAREN() and p.parseAssignExpr() and p.parseRPAREN()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseLinkSection(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_linksection() and p.parseLPAREN() and p.parseExpr() and p.parseRPAREN()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseAddrSpace(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_addrspace() and p.parseLPAREN() and p.parseExpr() and p.parseRPAREN()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseCallConv(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_callconv() and p.parseLPAREN() and p.parseExpr() and p.parseRPAREN()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseParamDecl(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.parsedoc_comment() or true) and blk_2: {
                const pos_2 = p.i;
                if (p.parseKEYWORD_noalias()) break :blk_2 true;
                p.i = pos_2;
                if (p.parseKEYWORD_comptime()) break :blk_2 true;
                p.i = pos_2;
                if (blk_3: {
                    const pos_3 = p.i;
                    const match_3 = p.parseKEYWORD_comptime();
                    p.i = pos_3;
                    break :blk_3 !match_3;
                }) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            } and blk_2: {
                const pos_2 = p.i;
                if (p.parseIDENTIFIER() and p.parseCOLON()) break :blk_2 true;
                p.i = pos_2;
                if (blk_3: {
                    const pos_3 = p.i;
                    const match_3 = blk_5: {
                        const pos_5 = p.i;
                        if (p.parseIDENTIFIER() and p.parseCOLON()) break :blk_5 true;
                        p.i = pos_5;
                        break :blk_5 false;
                    };
                    p.i = pos_3;
                    break :blk_3 !match_3;
                }) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            } and p.parseParamType()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseParamType(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_anytype()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseTypeExpr()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseIfPrefix(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_if() and p.parseLPAREN() and p.parseExpr() and p.parseRPAREN() and (p.parsePtrPayload() or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseWhilePrefix(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_while() and p.parseLPAREN() and p.parseExpr() and p.parseRPAREN() and (p.parsePtrPayload() or true) and (p.parseWhileContinueExpr() or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseForPrefix(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_for() and p.parseLPAREN() and p.parseForArgumentsList() and p.parseRPAREN() and p.parsePtrListPayload()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePayload(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parsePIPE() and p.parseIDENTIFIER() and p.parsePIPE()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePtrPayload(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parsePIPE() and (p.parseASTERISK() or true) and p.parseIDENTIFIER() and p.parsePIPE()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePtrIndexPayload(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parsePIPE() and (p.parseASTERISK() or true) and p.parseIDENTIFIER() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseCOMMA() and p.parseIDENTIFIER()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and p.parsePIPE()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePtrListPayload(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parsePIPE() and (p.parseASTERISK() or true) and p.parseIDENTIFIER() and blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseCOMMA() and (p.parseASTERISK() or true) and p.parseIDENTIFIER()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            } and (p.parseCOMMA() or true) and p.parsePIPE()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseSwitchProng(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.parseKEYWORD_inline() or true) and p.parseSwitchCase() and p.parseEQUALRARROW() and (p.parsePtrIndexPayload() or true) and p.parseSingleAssignExpr()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseSwitchCase(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseSwitchItem() and blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseCOMMA() and p.parseSwitchItem()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            } and (p.parseCOMMA() or true)) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_else()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseSwitchItem(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseExpr() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseDOT3() and p.parseExpr()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseForArgumentsList(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseForItem() and blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseCOMMA() and p.parseForItem()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            } and (p.parseCOMMA() or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseForItem(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseExpr() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseDOT2() and (p.parseExpr() or true)) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseAssignOp(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseASTERISKEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseASTERISKPIPEEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseSLASHEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parsePERCENTEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parsePLUSEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parsePLUSPIPEEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseMINUSEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseMINUSPIPEEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseLARROW2EQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseLARROW2PIPEEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseRARROW2EQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseAMPERSANDEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseCARETEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parsePIPEEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseASTERISKPERCENTEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parsePLUSPERCENTEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseMINUSPERCENTEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseEQUAL()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseCompareOp(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseEQUALEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseEXCLAMATIONMARKEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseLARROW()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseRARROW()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseLARROWEQUAL()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseRARROWEQUAL()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseBitwiseOp(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseAMPERSAND()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseCARET()) break :blk_0 true;
            p.i = pos_0;
            if (p.parsePIPE()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_orelse()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_catch() and (p.parsePayload() or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseBitShiftOp(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseLARROW2()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseRARROW2()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseLARROW2PIPE()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseAdditionOp(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parsePLUS()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseMINUS()) break :blk_0 true;
            p.i = pos_0;
            if (p.parsePLUS2()) break :blk_0 true;
            p.i = pos_0;
            if (p.parsePLUSPERCENT()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseMINUSPERCENT()) break :blk_0 true;
            p.i = pos_0;
            if (p.parsePLUSPIPE()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseMINUSPIPE()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseMultiplyOp(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parsePIPE2()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseASTERISK()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseSLASH()) break :blk_0 true;
            p.i = pos_0;
            if (p.parsePERCENT()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseASTERISKPERCENT()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseASTERISKPIPE()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePrefixOp(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseEXCLAMATIONMARK()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseMINUS()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseTILDE()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseMINUSPERCENT()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseAMPERSAND()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_try()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePrefixTypeOp(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseQUESTIONMARK()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_anyframe() and p.parseMINUSRARROW()) break :blk_0 true;
            p.i = pos_0;
            if (blk_2: {
                const pos_2 = p.i;
                if (p.parseManyPtrTypeStart()) break :blk_2 true;
                p.i = pos_2;
                if (p.parseSliceTypeStart()) break :blk_2 true;
                p.i = pos_2;
                break :blk_2 false;
            } and (p.parseKEYWORD_allowzero() or true) and (p.parseByteAlign() or true) and (p.parseAddrSpace() or true) and (p.parseKEYWORD_const() or true) and (p.parseKEYWORD_volatile() or true)) break :blk_0 true;
            p.i = pos_0;
            if (p.parseSinglePtrTypeStart() and (p.parseKEYWORD_allowzero() or true) and (p.parseBitAlign() or true) and (p.parseAddrSpace() or true) and (p.parseKEYWORD_const() or true) and (p.parseKEYWORD_volatile() or true)) break :blk_0 true;
            p.i = pos_0;
            if (p.parseArrayTypeStart()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseSuffixOp(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseLBRACKET() and p.parseExpr() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseDOT2() and (p.parseExpr() or true) and (blk_6: {
                    const pos_6 = p.i;
                    if (p.parseCOLON() and p.parseExpr()) break :blk_6 true;
                    p.i = pos_6;
                    break :blk_6 false;
                } or true)) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and p.parseRBRACKET()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseDOT() and p.parseIDENTIFIER()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseDOTASTERISK()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseDOTQUESTIONMARK()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseFnCallArguments(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseLPAREN() and p.parseExprList() and p.parseRPAREN()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseExprSuffix(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_or()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_and()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseCompareOp()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseBitwiseOp()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseBitShiftOp()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseAdditionOp()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseMultiplyOp()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseEXCLAMATIONMARK()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseSuffixOp()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseFnCallArguments()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseLabelableExpr(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseBlock()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseSwitchExpr()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseLoopExpr()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseSliceTypeStart(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseLBRACKET() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseCOLON() and p.parseExpr()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and p.parseRBRACKET()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseSinglePtrTypeStart(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseASTERISK()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseManyPtrTypeStart(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseLBRACKET() and p.parseASTERISK() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseLETTERC()) break :blk_3 true;
                p.i = pos_3;
                if (p.parseCOLON() and p.parseExpr()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and p.parseRBRACKET()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseArrayTypeStart(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseLBRACKET() and p.parseExpr() and blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parseASTERISK();
                p.i = pos_1;
                break :blk_1 !match_1;
            } and (blk_3: {
                const pos_3 = p.i;
                if (p.parseCOLON() and p.parseExpr()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and p.parseRBRACKET()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseContainerDeclAuto(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseContainerDeclType() and p.parseLBRACE() and p.parseContainerMembers() and p.parseRBRACE()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseContainerDeclType(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_struct() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseLPAREN() and p.parseExpr() and p.parseRPAREN()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true)) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_opaque()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_enum() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseLPAREN() and p.parseExpr() and p.parseRPAREN()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true)) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_union() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseLPAREN() and blk_5: {
                    const pos_5 = p.i;
                    if (p.parseKEYWORD_enum() and (blk_8: {
                        const pos_8 = p.i;
                        if (p.parseLPAREN() and p.parseExpr() and p.parseRPAREN()) break :blk_8 true;
                        p.i = pos_8;
                        break :blk_8 false;
                    } or true)) break :blk_5 true;
                    p.i = pos_5;
                    if (blk_6: {
                        const pos_6 = p.i;
                        const match_6 = p.parseKEYWORD_enum();
                        p.i = pos_6;
                        break :blk_6 !match_6;
                    } and p.parseExpr()) break :blk_5 true;
                    p.i = pos_5;
                    break :blk_5 false;
                } and p.parseRPAREN()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseByteAlign(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_align() and p.parseLPAREN() and p.parseExpr() and p.parseRPAREN()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseBitAlign(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_align() and p.parseLPAREN() and p.parseExpr() and (blk_3: {
                const pos_3 = p.i;
                if (p.parseCOLON() and p.parseExpr() and p.parseCOLON() and p.parseExpr()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and p.parseRPAREN()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseIdentifierList(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if ((p.parsedoc_comment() or true) and p.parseIDENTIFIER() and p.parseCOMMA()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            } and (blk_3: {
                const pos_3 = p.i;
                if ((p.parsedoc_comment() or true) and p.parseIDENTIFIER()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseSwitchProngList(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseSwitchProng() and p.parseCOMMA()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            } and (p.parseSwitchProng() or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseAsmOutputList(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseAsmOutputItem() and p.parseCOMMA()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            } and (p.parseAsmOutputItem() or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseAsmInputList(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseAsmInputItem() and p.parseCOMMA()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            } and (p.parseAsmInputItem() or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseParamDeclList(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseParamDecl() and p.parseCOMMA()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            } and (blk_3: {
                const pos_3 = p.i;
                if (p.parseParamDecl()) break :blk_3 true;
                p.i = pos_3;
                if (p.parseDOT3() and (p.parseCOMMA() or true)) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseExprList(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseExpr() and p.parseCOMMA()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            } and (p.parseExpr() or true)) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseeof(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                const pos_1 = p.i;
                const match_1 = blk_2: {
                    if (p.i < p.source.len) {
                        p.i += 1;
                        break :blk_2 true;
                    }
                    break :blk_2 false;
                };
                p.i = pos_1;
                break :blk_1 !match_1;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsebin(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.i < p.source.len and switch (p.source[p.i]) {
                '0'...'0',
                '1'...'1',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            })) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsebin_(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((blk_2: {
                if (std.mem.startsWith(u8, p.source[p.i..], "_")) {
                    p.i += 1;
                    break :blk_2 true;
                }
                break :blk_2 false;
            } or true) and p.parsebin()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseoct(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.i < p.source.len and switch (p.source[p.i]) {
                '0'...'7',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            })) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseoct_(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((blk_2: {
                if (std.mem.startsWith(u8, p.source[p.i..], "_")) {
                    p.i += 1;
                    break :blk_2 true;
                }
                break :blk_2 false;
            } or true) and p.parseoct()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsehex(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.i < p.source.len and switch (p.source[p.i]) {
                '0'...'9',
                'a'...'f',
                'A'...'F',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            })) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsehex_(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((blk_2: {
                if (std.mem.startsWith(u8, p.source[p.i..], "_")) {
                    p.i += 1;
                    break :blk_2 true;
                }
                break :blk_2 false;
            } or true) and p.parsehex()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsedec(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.i < p.source.len and switch (p.source[p.i]) {
                '0'...'9',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            })) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsedec_(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((blk_2: {
                if (std.mem.startsWith(u8, p.source[p.i..], "_")) {
                    p.i += 1;
                    break :blk_2 true;
                }
                break :blk_2 false;
            } or true) and p.parsedec()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsebin_int(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parsebin() and blk_1: {
                while (p.parsebin_()) {}
                break :blk_1 true;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseoct_int(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseoct() and blk_1: {
                while (p.parseoct_()) {}
                break :blk_1 true;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsedec_int(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parsedec() and blk_1: {
                while (p.parsedec_()) {}
                break :blk_1 true;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsehex_int(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parsehex() and blk_1: {
                while (p.parsehex_()) {}
                break :blk_1 true;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseox80_oxBF(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.i < p.source.len and switch (p.source[p.i]) {
                '\x80'...'\xbf',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            })) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseoxF4(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "\xf4")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseox80_ox8F(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.i < p.source.len and switch (p.source[p.i]) {
                '\x80'...'\x8f',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            })) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseoxF1_oxF3(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.i < p.source.len and switch (p.source[p.i]) {
                '\xf1'...'\xf3',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            })) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseoxF0(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "\xf0")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseox90_0xBF(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.i < p.source.len and switch (p.source[p.i]) {
                '\x90'...'\xbf',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            })) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseoxEE_oxEF(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.i < p.source.len and switch (p.source[p.i]) {
                '\xee'...'\xef',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            })) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseoxED(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "\xed")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseox80_ox9F(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.i < p.source.len and switch (p.source[p.i]) {
                '\x80'...'\x9f',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            })) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseoxE1_oxEC(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.i < p.source.len and switch (p.source[p.i]) {
                '\xe1'...'\xec',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            })) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseoxE0(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "\xe0")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseoxA0_oxBF(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.i < p.source.len and switch (p.source[p.i]) {
                '\xa0'...'\xbf',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            })) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseoxC2_oxDF(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.i < p.source.len and switch (p.source[p.i]) {
                '\xc2'...'\xdf',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            })) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsemultibyte_utf8(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseoxF4() and p.parseox80_ox8F() and p.parseox80_oxBF() and p.parseox80_oxBF()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseoxF1_oxF3() and p.parseox80_oxBF() and p.parseox80_oxBF() and p.parseox80_oxBF()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseoxF0() and p.parseox90_0xBF() and p.parseox80_oxBF() and p.parseox80_oxBF()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseoxEE_oxEF() and p.parseox80_oxBF() and p.parseox80_oxBF()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseoxED() and p.parseox80_ox9F() and p.parseox80_oxBF()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseoxE1_oxEC() and p.parseox80_oxBF() and p.parseox80_oxBF()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseoxE0() and p.parseoxA0_oxBF() and p.parseox80_oxBF()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseoxC2_oxDF() and p.parseox80_oxBF()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsenon_control_ascii(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.i < p.source.len and switch (p.source[p.i]) {
                ' '...'~',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            })) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsenon_control_utf8(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.i < p.source.len and switch (p.source[p.i]) {
                ' '...'\xff',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            })) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsechar_escape(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "\\x")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parsehex() and p.parsehex()) break :blk_0 true;
            p.i = pos_0;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "\\u{")) {
                    p.i += 3;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                var match_1 = false;
                while (p.parsehex()) {
                    match_1 = true;
                }
                break :blk_1 match_1;
            } and blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "}")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            }) break :blk_0 true;
            p.i = pos_0;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "\\")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and (p.i < p.source.len and switch (p.source[p.i]) {
                'n'...'n',
                'r'...'r',
                '\\'...'\\',
                't'...'t',
                '\''...'\'',
                '"'...'"',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            })) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsechar_char(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parsemultibyte_utf8()) break :blk_0 true;
            p.i = pos_0;
            if (p.parsechar_escape()) break :blk_0 true;
            p.i = pos_0;
            if (blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '\\'...'\\',
                    '\''...'\'',
                    '\n'...'\n',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parsenon_control_ascii()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsestring_char(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parsemultibyte_utf8()) break :blk_0 true;
            p.i = pos_0;
            if (p.parsechar_escape()) break :blk_0 true;
            p.i = pos_0;
            if (blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '\\'...'\\',
                    '"'...'"',
                    '\n'...'\n',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parsenon_control_ascii()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsecontainer_doc_comment(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                var match_1 = false;
                while (blk_3: {
                    const pos_3 = p.i;
                    if (blk_4: {
                        if (std.mem.startsWith(u8, p.source[p.i..], "//!")) {
                            p.i += 3;
                            break :blk_4 true;
                        }
                        break :blk_4 false;
                    } and blk_4: {
                        while (p.parsenon_control_utf8()) {}
                        break :blk_4 true;
                    } and blk_4: {
                        while ((p.i < p.source.len and switch (p.source[p.i]) {
                            ' '...' ',
                            '\n'...'\n',
                            => blk_5: {
                                p.i += 1;
                                break :blk_5 true;
                            },
                            else => false,
                        })) {}
                        break :blk_4 true;
                    } and p.parseskip()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {
                    match_1 = true;
                }
                break :blk_1 match_1;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsedoc_comment(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                var match_1 = false;
                while (blk_3: {
                    const pos_3 = p.i;
                    if (blk_4: {
                        if (std.mem.startsWith(u8, p.source[p.i..], "///")) {
                            p.i += 3;
                            break :blk_4 true;
                        }
                        break :blk_4 false;
                    } and blk_4: {
                        while (p.parsenon_control_utf8()) {}
                        break :blk_4 true;
                    } and blk_4: {
                        while ((p.i < p.source.len and switch (p.source[p.i]) {
                            ' '...' ',
                            '\n'...'\n',
                            => blk_5: {
                                p.i += 1;
                                break :blk_5 true;
                            },
                            else => false,
                        })) {}
                        break :blk_4 true;
                    } and p.parseskip()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {
                    match_1 = true;
                }
                break :blk_1 match_1;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseline_comment(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "//")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '!'...'!',
                    '/'...'/',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and blk_1: {
                while (p.parsenon_control_utf8()) {}
                break :blk_1 true;
            }) break :blk_0 true;
            p.i = pos_0;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "////")) {
                    p.i += 4;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                while (p.parsenon_control_utf8()) {}
                break :blk_1 true;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseline_string(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "\\\\")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                while (p.parsenon_control_utf8()) {}
                break :blk_1 true;
            } and blk_1: {
                while ((p.i < p.source.len and switch (p.source[p.i]) {
                    ' '...' ',
                    '\n'...'\n',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                })) {}
                break :blk_1 true;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseskip(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                while (blk_3: {
                    const pos_3 = p.i;
                    if ((p.i < p.source.len and switch (p.source[p.i]) {
                        ' '...' ',
                        '\n'...'\n',
                        => blk_4: {
                            p.i += 1;
                            break :blk_4 true;
                        },
                        else => false,
                    })) break :blk_3 true;
                    p.i = pos_3;
                    if (p.parseline_comment()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {}
                break :blk_1 true;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseCHAR_LITERAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.i < p.source.len and switch (p.source[p.i]) {
                '\''...'\'',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            }) and p.parsechar_char() and (p.i < p.source.len and switch (p.source[p.i]) {
                '\''...'\'',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            }) and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseFLOAT(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "0x")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parsehex_int() and blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], ".")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parsehex_int() and (blk_3: {
                const pos_3 = p.i;
                if ((p.i < p.source.len and switch (p.source[p.i]) {
                    'p'...'p',
                    'P'...'P',
                    => blk_4: {
                        p.i += 1;
                        break :blk_4 true;
                    },
                    else => false,
                }) and ((p.i < p.source.len and switch (p.source[p.i]) {
                    '-'...'-',
                    '+'...'+',
                    => blk_5: {
                        p.i += 1;
                        break :blk_5 true;
                    },
                    else => false,
                }) or true) and p.parsedec_int()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            if (p.parsedec_int() and blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], ".")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parsedec_int() and (blk_3: {
                const pos_3 = p.i;
                if ((p.i < p.source.len and switch (p.source[p.i]) {
                    'e'...'e',
                    'E'...'E',
                    => blk_4: {
                        p.i += 1;
                        break :blk_4 true;
                    },
                    else => false,
                }) and ((p.i < p.source.len and switch (p.source[p.i]) {
                    '-'...'-',
                    '+'...'+',
                    => blk_5: {
                        p.i += 1;
                        break :blk_5 true;
                    },
                    else => false,
                }) or true) and p.parsedec_int()) break :blk_3 true;
                p.i = pos_3;
                break :blk_3 false;
            } or true) and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "0x")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parsehex_int() and (p.i < p.source.len and switch (p.source[p.i]) {
                'p'...'p',
                'P'...'P',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            }) and ((p.i < p.source.len and switch (p.source[p.i]) {
                '-'...'-',
                '+'...'+',
                => blk_2: {
                    p.i += 1;
                    break :blk_2 true;
                },
                else => false,
            }) or true) and p.parsedec_int() and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            if (p.parsedec_int() and (p.i < p.source.len and switch (p.source[p.i]) {
                'e'...'e',
                'E'...'E',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            }) and ((p.i < p.source.len and switch (p.source[p.i]) {
                '-'...'-',
                '+'...'+',
                => blk_2: {
                    p.i += 1;
                    break :blk_2 true;
                },
                else => false,
            }) or true) and p.parsedec_int() and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseINTEGER(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "0b")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parsebin_int() and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "0o")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseoct_int() and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "0x")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parsehex_int() and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            if (p.parsedec_int() and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseSTRINGLITERALSINGLE(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if ((p.i < p.source.len and switch (p.source[p.i]) {
                '"'...'"',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            }) and blk_1: {
                while (p.parsestring_char()) {}
                break :blk_1 true;
            } and (p.i < p.source.len and switch (p.source[p.i]) {
                '"'...'"',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            }) and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseSTRINGLITERAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseSTRINGLITERALSINGLE()) break :blk_0 true;
            p.i = pos_0;
            if (blk_1: {
                var match_1 = false;
                while (blk_3: {
                    const pos_3 = p.i;
                    if (p.parseline_string() and p.parseskip()) break :blk_3 true;
                    p.i = pos_3;
                    break :blk_3 false;
                }) {
                    match_1 = true;
                }
                break :blk_1 match_1;
            }) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseIDENTIFIER(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                const pos_1 = p.i;
                const match_1 = p.parsekeyword();
                p.i = pos_1;
                break :blk_1 !match_1;
            } and (p.i < p.source.len and switch (p.source[p.i]) {
                'A'...'Z',
                'a'...'z',
                '_'...'_',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            }) and blk_1: {
                while ((p.i < p.source.len and switch (p.source[p.i]) {
                    'A'...'Z',
                    'a'...'z',
                    '0'...'9',
                    '_'...'_',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                })) {}
                break :blk_1 true;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "@")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseSTRINGLITERALSINGLE()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseBUILTINIDENTIFIER(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "@")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and (p.i < p.source.len and switch (p.source[p.i]) {
                'A'...'Z',
                'a'...'z',
                '_'...'_',
                => blk_1: {
                    p.i += 1;
                    break :blk_1 true;
                },
                else => false,
            }) and blk_1: {
                while ((p.i < p.source.len and switch (p.source[p.i]) {
                    'A'...'Z',
                    'a'...'z',
                    '0'...'9',
                    '_'...'_',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                })) {}
                break :blk_1 true;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseAMPERSAND(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "&")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '='...'=',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseAMPERSANDEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "&=")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseASTERISK(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "*")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '%'...'%',
                    '='...'=',
                    '|'...'|',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseASTERISKEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "*=")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseASTERISKPERCENT(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "*%")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '='...'=',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseASTERISKPERCENTEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "*%=")) {
                    p.i += 3;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseASTERISKPIPE(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "*|")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '='...'=',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseASTERISKPIPEEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "*|=")) {
                    p.i += 3;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseCARET(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "^")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '='...'=',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseCARETEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "^=")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseCOLON(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], ":")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseCOMMA(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], ",")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseDOT(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], ".")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '*'...'*',
                    '.'...'.',
                    '?'...'?',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseDOT2(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "..")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '.'...'.',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseDOT3(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "...")) {
                    p.i += 3;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseDOTASTERISK(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], ".*")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseDOTQUESTIONMARK(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], ".?")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "=")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '>'...'>',
                    '='...'=',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseEQUALEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "==")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseEQUALRARROW(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "=>")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseEXCLAMATIONMARK(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "!")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '='...'=',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseEXCLAMATIONMARKEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "!=")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseLARROW(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "<")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '<'...'<',
                    '='...'=',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseLARROW2(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "<<")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '='...'=',
                    '|'...'|',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseLARROW2EQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "<<=")) {
                    p.i += 3;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseLARROW2PIPE(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "<<|")) {
                    p.i += 3;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '='...'=',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseLARROW2PIPEEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "<<|=")) {
                    p.i += 4;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseLARROWEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "<=")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseLBRACE(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "{")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseLBRACKET(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "[")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseLPAREN(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "(")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseMINUS(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "-")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '%'...'%',
                    '='...'=',
                    '>'...'>',
                    '|'...'|',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseMINUSEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "-=")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseMINUSPERCENT(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "-%")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '='...'=',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseMINUSPERCENTEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "-%=")) {
                    p.i += 3;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseMINUSPIPE(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "-|")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '='...'=',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseMINUSPIPEEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "-|=")) {
                    p.i += 3;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseMINUSRARROW(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "->")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePERCENT(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "%")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '='...'=',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePERCENTEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "%=")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePIPE(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "|")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '|'...'|',
                    '='...'=',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePIPE2(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "||")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePIPEEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "|=")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePLUS(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "+")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '%'...'%',
                    '+'...'+',
                    '='...'=',
                    '|'...'|',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePLUS2(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "++")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePLUSEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "+=")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePLUSPERCENT(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "+%")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '='...'=',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePLUSPERCENTEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "+%=")) {
                    p.i += 3;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePLUSPIPE(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "+|")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '='...'=',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsePLUSPIPEEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "+|=")) {
                    p.i += 3;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseLETTERC(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "c")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseQUESTIONMARK(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "?")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseRARROW(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], ">")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '>'...'>',
                    '='...'=',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseRARROW2(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], ">>")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '='...'=',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseRARROW2EQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], ">>=")) {
                    p.i += 3;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseRARROWEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], ">=")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseRBRACE(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "}")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseRBRACKET(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "]")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseRPAREN(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], ")")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseSEMICOLON(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], ";")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseSLASH(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "/")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    '='...'=',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseSLASHEQUAL(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "/=")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseTILDE(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "~")) {
                    p.i += 1;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseend_of_word(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                const pos_1 = p.i;
                const match_1 = (p.i < p.source.len and switch (p.source[p.i]) {
                    'a'...'z',
                    'A'...'Z',
                    '0'...'9',
                    '_'...'_',
                    => blk_2: {
                        p.i += 1;
                        break :blk_2 true;
                    },
                    else => false,
                });
                p.i = pos_1;
                break :blk_1 !match_1;
            } and p.parseskip()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_addrspace(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "addrspace")) {
                    p.i += 9;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_align(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "align")) {
                    p.i += 5;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_allowzero(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "allowzero")) {
                    p.i += 9;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_and(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "and")) {
                    p.i += 3;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_anyframe(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "anyframe")) {
                    p.i += 8;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_anytype(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "anytype")) {
                    p.i += 7;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_asm(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "asm")) {
                    p.i += 3;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_break(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "break")) {
                    p.i += 5;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_callconv(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "callconv")) {
                    p.i += 8;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_catch(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "catch")) {
                    p.i += 5;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_comptime(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "comptime")) {
                    p.i += 8;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_const(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "const")) {
                    p.i += 5;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_continue(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "continue")) {
                    p.i += 8;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_defer(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "defer")) {
                    p.i += 5;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_else(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "else")) {
                    p.i += 4;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_enum(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "enum")) {
                    p.i += 4;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_errdefer(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "errdefer")) {
                    p.i += 8;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_error(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "error")) {
                    p.i += 5;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_export(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "export")) {
                    p.i += 6;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_extern(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "extern")) {
                    p.i += 6;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_fn(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "fn")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_for(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "for")) {
                    p.i += 3;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_if(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "if")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_inline(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "inline")) {
                    p.i += 6;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_noalias(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "noalias")) {
                    p.i += 7;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_nosuspend(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "nosuspend")) {
                    p.i += 9;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_noinline(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "noinline")) {
                    p.i += 8;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_opaque(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "opaque")) {
                    p.i += 6;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_or(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "or")) {
                    p.i += 2;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_orelse(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "orelse")) {
                    p.i += 6;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_packed(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "packed")) {
                    p.i += 6;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_pub(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "pub")) {
                    p.i += 3;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_resume(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "resume")) {
                    p.i += 6;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_return(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "return")) {
                    p.i += 6;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_linksection(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "linksection")) {
                    p.i += 11;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_struct(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "struct")) {
                    p.i += 6;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_suspend(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "suspend")) {
                    p.i += 7;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_switch(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "switch")) {
                    p.i += 6;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_test(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "test")) {
                    p.i += 4;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_threadlocal(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "threadlocal")) {
                    p.i += 11;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_try(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "try")) {
                    p.i += 3;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_union(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "union")) {
                    p.i += 5;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_unreachable(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "unreachable")) {
                    p.i += 11;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_var(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "var")) {
                    p.i += 3;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_volatile(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "volatile")) {
                    p.i += 8;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parseKEYWORD_while(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (blk_1: {
                if (std.mem.startsWith(u8, p.source[p.i..], "while")) {
                    p.i += 5;
                    break :blk_1 true;
                }
                break :blk_1 false;
            } and p.parseend_of_word()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
    pub fn parsekeyword(p: *Parser) bool {
        return blk_0: {
            const pos_0 = p.i;
            if (p.parseKEYWORD_addrspace()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_align()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_allowzero()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_and()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_anyframe()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_anytype()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_asm()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_break()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_callconv()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_catch()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_comptime()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_const()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_continue()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_defer()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_else()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_enum()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_errdefer()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_error()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_export()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_extern()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_fn()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_for()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_if()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_inline()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_noalias()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_nosuspend()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_noinline()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_opaque()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_or()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_orelse()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_packed()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_pub()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_resume()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_return()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_linksection()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_struct()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_suspend()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_switch()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_test()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_threadlocal()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_try()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_union()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_unreachable()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_var()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_volatile()) break :blk_0 true;
            p.i = pos_0;
            if (p.parseKEYWORD_while()) break :blk_0 true;
            p.i = pos_0;
            break :blk_0 false;
        };
    }
};
