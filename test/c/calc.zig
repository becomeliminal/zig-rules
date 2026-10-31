// A module with a C source of its own, and a C library translated to Zig.
const mathc = @import("mathc");

extern fn add(a: c_int, b: c_int) c_int;

pub fn calc(a: c_int, b: c_int) c_int {
    return mathc.mathc_mul(add(a, b), mathc.MATHC_SCALE);
}
