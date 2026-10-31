// Exported for C: zig_static_library and zig_shared_library write square.h.
export fn zig_square(x: c_int) c_int {
    return x * x;
}
