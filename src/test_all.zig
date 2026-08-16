// Aggregates host-runnable unit tests. Modules that touch SDL or D-Bus are
// deliberately absent: those are verified on hardware via --dump.
const std = @import("std");

test "test harness runs" {
    try std.testing.expect(true);
}

test {
    _ = @import("audio.zig");
    _ = @import("theme.zig");
}
