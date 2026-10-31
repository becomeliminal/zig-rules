pub fn shout(comptime word: []const u8) []const u8 {
    return word ++ "!";
}
