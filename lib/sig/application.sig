//! Convenient application APIs over Sig's existing standard facilities.
//! Storage belongs to the caller; exhaustion is an error, never a reallocation.
pub const collections = @import("app/collections.sig");
pub const json = @import("app/encoding.sig");
pub const validation = @import("app/validation.sig");
pub const http = @import("app/http.sig");
pub const List = collections.List;
pub const Queue = collections.Queue;
pub const Vector = collections.Vector;
pub const StringMap = collections.StringMap;
pub const StaticMap = collections.StaticMap;
pub const Schema = validation.Schema;

test {
    _ = collections;
    _ = json;
    _ = validation;
}
