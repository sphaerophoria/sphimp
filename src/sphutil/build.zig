const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "");
    _ = b.addModule("sphutil", .{
        .root_source_file = b.path("src/sphutil.zig"),
    });

    const tests = b.addTest(.{
        .root_source_file = b.path("src/sphutil.zig"),
    });

    const run_test = b.addRunArtifact(tests);
    test_step.dependOn(&run_test.step);
}
