//! Sig — Strict Sig standard library.
//!
//! A capacity-first, caller-provided-buffer standard library layer
//! that sits alongside `@import("std")`.

pub const errors = @import("errors.sig");
pub const SigError = errors.SigError;

pub const fmt = @import("fmt.sig");
pub const io = @import("io.sig");
pub const containers = @import("containers.sig");
pub const string = @import("string.sig");
pub const parse = @import("parse.sig");
pub const http = @import("http.sig");
pub const fs = @import("fs.sig");
pub const compress = @import("compress.sig");
pub const tar = @import("tar.sig");
pub const zip = @import("zip.sig");
pub const zon = @import("zon.sig");
pub const uri = @import("uri.sig");
pub const json = @import("json.sig");
pub const process = @import("process.sig");
pub const os = @import("os.sig");
pub const page_arena = @import("page_arena.sig");
pub const hash = @import("hash.sig");
pub const hash_index = @import("hash_index.sig");
pub const math = @import("math.sig");
pub const mem = @import("mem.sig");
