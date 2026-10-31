// Imports util under another name, chosen by import_names.
const u = @import("u");

pub fn word() []const u8 {
    return u.shout("right");
}
