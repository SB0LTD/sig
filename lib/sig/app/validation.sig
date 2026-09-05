//! Compile-time checked field rules and caller-owned validation reports.
//! Validators are pure predicates; never mutate the input while checking it.
pub const Violation = struct { field: []const u8, message: []const u8 };

pub fn nonEmpty(value: []const u8) bool { return value.len > 0; }
pub fn lengthBetween(comptime minimum: usize, comptime maximum: usize) fn ([]const u8) bool {
    if (minimum > maximum) @compileError("invalid length range");
    return struct { fn check(value: []const u8) bool { return value.len >= minimum and value.len <= maximum; } }.check;
}
pub fn range(comptime T: type, comptime minimum: T, comptime maximum: T) fn (T) bool {
    if (minimum > maximum) @compileError("invalid numeric range");
    return struct { fn check(value: T) bool { return value >= minimum and value <= maximum; } }.check;
}

/// `rules` is a comptime tuple of .{ .field, .check, .message } records.
/// Misspelled field names and incompatible predicate types are compile errors.
pub fn Schema(comptime T: type, comptime rules: anytype) type {
    if (@typeInfo(T) != .@"struct") @compileError("Schema expects a struct type");
    inline for (rules) |rule| {
        if (!@hasField(T, rule.field)) @compileError("unknown schema field: " ++ rule.field);
    }
    return struct {
        pub const Value = T;
        pub const rule_count = rules.len;
        pub fn first(value: T) ?Violation {
            inline for (rules) |rule| {
                if (!rule.check(@field(value, rule.field))) return .{ .field = rule.field, .message = rule.message };
            }
            return null;
        }
        pub fn validate(value: T) error{ValidationFailed}!void {
            if (first(value) != null) return error.ValidationFailed;
        }
        /// Report all failed rules in declaration order. Capacity failure leaves
        /// the output unchanged; report text borrows comptime rule literals.
        pub fn report(value: T, output: []Violation) error{BufferTooSmall}![]const Violation {
            var failed: [rules.len]bool = undefined;
            var count: usize = 0;
            inline for (rules, 0..) |rule, i| {
                failed[i] = !rule.check(@field(value, rule.field));
                if (failed[i]) count += 1;
            }
            if (count > output.len) return error.BufferTooSmall;
            var index: usize = 0;
            inline for (rules, 0..) |rule, i| {
                if (failed[i]) {
                    output[index] = .{ .field = rule.field, .message = rule.message };
                    index += 1;
                }
            }
            return output[0..count];
        }
    };
}

test "schema validates typed fields and reports every failure in stable order" {
    const User = struct { name: []const u8, age: u8 };
    const UserSchema = Schema(User, .{
        .{ .field = "name", .check = lengthBetween(1, 32), .message = "Use 1 to 32 bytes" },
        .{ .field = "age", .check = range(u8, 1, 120), .message = "Use age 1 to 120" },
    });
    try UserSchema.validate(.{ .name = "Ada", .age = 9 });
    if (UserSchema.validate(.{ .name = "", .age = 0 })) return error.ExpectedFailure else |err| if (err != error.ValidationFailed) return err;
    var issues: [2]Violation = undefined;
    const report = try UserSchema.report(.{ .name = "", .age = 0 }, &issues);
    const std = @import("std");
    if (report.len != 2 or !std.mem.eql(u8, report[0].field, "name") or !std.mem.eql(u8, report[1].field, "age")) return error.BadReport;
    issues[0] = .{ .field = "sentinel", .message = "untouched" };
    if (UserSchema.report(.{ .name = "", .age = 0 }, issues[0..1])) |_| return error.ExpectedFailure else |err| if (err != error.BufferTooSmall) return err;
    if (!std.mem.eql(u8, issues[0].field, "sentinel")) return error.PartialWrite;
}
