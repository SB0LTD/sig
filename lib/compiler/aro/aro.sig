pub const CodeGen = @import("aro/CodeGen.sig");
pub const Compilation = @import("aro/Compilation.sig");
pub const Diagnostics = @import("aro/Diagnostics.sig");
pub const Driver = @import("aro/Driver.sig");
pub const Parser = @import("aro/Parser.sig");
pub const Preprocessor = @import("aro/Preprocessor.sig");
pub const Source = @import("aro/Source.sig");
pub const StringInterner = @import("aro/StringInterner.sig");
pub const Target = @import("aro/Target.sig");
pub const Tokenizer = @import("aro/Tokenizer.sig");
pub const Toolchain = @import("aro/Toolchain.sig");
pub const Tree = @import("aro/Tree.sig");
pub const TypeStore = @import("aro/TypeStore.sig");
pub const QualType = TypeStore.QualType;
pub const Type = TypeStore.Type;
pub const Value = @import("aro/Value.sig");

const backend = @import("backend.sig");
pub const Interner = backend.Interner;
pub const Ir = backend.Ir;
pub const Object = backend.Object;
pub const CallingConvention = backend.CallingConvention;
pub const Assembly = backend.Assembly;

pub const version_str = backend.version_str;
pub const version = backend.version;

test {
    _ = @import("aro/annex_g.sig");
    _ = @import("aro/Builtins.sig");
    _ = @import("aro/char_info.sig");
    _ = @import("aro/Compilation.sig");
    _ = @import("aro/Driver/Distro.sig");
    _ = @import("aro/Driver/GCCVersion.sig");
    _ = @import("aro/InitList.sig");
    _ = @import("aro/LangOpts.sig");
    _ = @import("aro/Preprocessor.sig");
    _ = @import("aro/Target.sig");
    _ = @import("aro/Tokenizer.sig");
    _ = @import("aro/Value.sig");
}
