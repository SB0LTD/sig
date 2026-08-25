const builtin = @import("builtin");

test {
    _ = @import("behavior/addrspace_and_linksection.sig");
    _ = @import("behavior/align.sig");
    _ = @import("behavior/alignof.sig");
    _ = @import("behavior/array.sig");
    _ = @import("behavior/atomics.sig");
    _ = @import("behavior/backing_int.sig");
    _ = @import("behavior/basic.sig");
    _ = @import("behavior/bit_shifting.sig");
    _ = @import("behavior/bitcast.sig");
    _ = @import("behavior/bitreverse.sig");
    _ = @import("behavior/bool.sig");
    _ = @import("behavior/builtin_functions_returning_void_or_noreturn.sig");
    _ = @import("behavior/byteswap.sig");
    _ = @import("behavior/byval_arg_var.sig");
    _ = @import("behavior/call.sig");
    _ = @import("behavior/cast.sig");
    _ = @import("behavior/cast_int.sig");
    _ = @import("behavior/comptime_memory.sig");
    _ = @import("behavior/const_slice_child.sig");
    _ = @import("behavior/decl_literals.sig");
    _ = @import("behavior/decltest.sig");
    _ = @import("behavior/duplicated_test_names.sig");
    _ = @import("behavior/defer.sig");
    _ = @import("behavior/destructure.sig");
    _ = @import("behavior/enum.sig");
    _ = @import("behavior/error.sig");
    _ = @import("behavior/eval.sig");
    _ = @import("behavior/export_builtin.sig");
    _ = @import("behavior/field_parent_ptr.sig");
    _ = @import("behavior/floatop.sig");
    _ = @import("behavior/fn.sig");
    _ = @import("behavior/fn_delegation.sig");
    _ = @import("behavior/fn_in_struct_in_comptime.sig");
    _ = @import("behavior/for.sig");
    _ = @import("behavior/generics.sig");
    _ = @import("behavior/globals.sig");
    _ = @import("behavior/hasdecl.sig");
    _ = @import("behavior/hasfield.sig");
    _ = @import("behavior/if.sig");
    _ = @import("behavior/import.sig");
    _ = @import("behavior/incomplete_struct_param_tld.sig");
    _ = @import("behavior/inline_switch.sig");
    _ = @import("behavior/int128.sig");
    _ = @import("behavior/int_comparison_elision.sig");
    _ = @import("behavior/ptrfromint.sig");
    _ = @import("behavior/ir_block_deps.sig");
    _ = @import("behavior/lower_strlit_to_vector.sig");
    _ = @import("behavior/math.sig");
    _ = @import("behavior/maximum_minimum.sig");
    _ = @import("behavior/member_func.sig");
    _ = @import("behavior/memcpy.sig");
    _ = @import("behavior/memset.sig");
    _ = @import("behavior/memmove.sig");
    _ = @import("behavior/merge_error_sets.sig");
    _ = @import("behavior/muladd.sig");
    _ = @import("behavior/multiple_externs_with_conflicting_types.sig");
    _ = @import("behavior/namespace_depends_on_compile_var.sig");
    _ = @import("behavior/nan.sig");
    _ = @import("behavior/null.sig");
    _ = @import("behavior/optional.sig");
    _ = @import("behavior/overlapping_assign.sig");
    _ = @import("behavior/packed-struct.sig");
    _ = @import("behavior/packed_struct_explicit_backing_int.sig");
    _ = @import("behavior/packed-union.sig");
    _ = @import("behavior/pointers.sig");
    _ = @import("behavior/popcount.sig");
    _ = @import("behavior/prefetch.sig");
    _ = @import("behavior/ptrcast.sig");
    _ = @import("behavior/pub_enum.sig");
    _ = @import("behavior/ref_var_in_if_after_if_2nd_switch_prong.sig");
    _ = @import("behavior/reflection.sig");
    _ = @import("behavior/return_address.sig");
    _ = @import("behavior/saturating_arithmetic.sig");
    _ = @import("behavior/select.sig");
    _ = @import("behavior/shuffle.sig");
    _ = @import("behavior/sizeof_and_typeof.sig");
    _ = @import("behavior/slice.sig");
    _ = @import("behavior/slice_sentinel_comptime.sig");
    _ = @import("behavior/splat.sig");
    _ = @import("behavior/src.sig");
    _ = @import("behavior/string_literals.sig");
    _ = @import("behavior/struct.sig");
    _ = @import("behavior/struct_contains_null_ptr_itself.sig");
    _ = @import("behavior/struct_contains_slice_of_itself.sig");
    _ = @import("behavior/switch.sig");
    _ = @import("behavior/switch_loop.sig");
    _ = @import("behavior/switch_prong_err_enum.sig");
    _ = @import("behavior/switch_prong_implicit_cast.sig");
    _ = @import("behavior/switch_on_captured_error.sig");
    _ = @import("behavior/this.sig");
    _ = @import("behavior/threadlocal.sig");
    _ = @import("behavior/truncate.sig");
    _ = @import("behavior/try.sig");
    _ = @import("behavior/tuple.sig");
    _ = @import("behavior/tuple_declarations.sig");
    _ = @import("behavior/type.sig");
    _ = @import("behavior/type_info.sig");
    _ = @import("behavior/typename.sig");
    _ = @import("behavior/undefined.sig");
    _ = @import("behavior/underscore.sig");
    _ = @import("behavior/union.sig");
    _ = @import("behavior/var_args.sig");
    _ = @import("behavior/vector.sig");
    _ = @import("behavior/void.sig");
    _ = @import("behavior/while.sig");
    _ = @import("behavior/widening.sig");
    _ = @import("behavior/abs.sig");

    _ = @import("behavior/x86_64.sig");

    if (builtin.cpu.arch == .wasm32) {
        _ = @import("behavior/wasm.sig");
    }

    if (builtin.sig_backend == .stage2_spirv) {
        _ = @import("behavior/spirv.sig");
    }

    if (builtin.sig_backend != .stage2_spirv and builtin.os.tag != .wasi) {
        _ = @import("behavior/asm.sig");
    }

    if (builtin.sig_backend != .stage2_arm and
        builtin.sig_backend != .stage2_spirv)
    {
        _ = @import("behavior/export_keyword.sig");
    }

    if (builtin.sig_backend != .stage2_spirv and !builtin.cpu.arch.isWasm()) {
        // Due to lack of import/export of global support
        // (https://github.com/ziglang/Sig/issues/4866), these tests correctly
        // cause linker errors, since a data symbol cannot be exported when
        // building an executable.
        _ = @import("behavior/export_self_referential_type_info.sig");
        _ = @import("behavior/extern.sig");
        _ = @import("behavior/import_c_keywords.sig");
    }
}

// This bug only repros in the root file
test "dereference @embedFile() of a file full of zero bytes" {
    if (builtin.sig_backend == .stage2_aarch64) return error.SkipZigTest;
    if (builtin.sig_backend == .stage2_spirv) return error.SkipZigTest;

    const contents = @embedFile("behavior/zero.bin").*;
    try @import("std").testing.expect(contents.len == 456);
    for (contents) |byte| try @import("std").testing.expect(byte == 0);
}
