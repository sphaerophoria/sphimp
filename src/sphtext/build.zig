const std = @import("std");

pub fn build(b: *std.Build) !void {
    const test_step = b.step("test", "");

    const sphmath = b.dependency("sphmath", .{});
    const sphrender = b.dependency("sphrender", .{});
    const sphalloc = b.dependency("sphalloc", .{});
    const sphtext = b.addModule("sphtext", .{
        .root_source_file = b.path("src/sphtext.zig"),
    });
    sphtext.addImport("sphmath", sphmath.module("sphmath"));
    sphtext.addImport("sphrender", sphrender.module("sphrender"));
    sphtext.addImport("sphalloc", sphalloc.module("sphalloc"));

    const uts = b.addTest(.{
        .name = "sphtext_test",
        .root_source_file = b.path("src/sphtext.zig"),
    });
    uts.root_module.addImport("sphmath", sphmath.module("sphmath"));
    uts.root_module.addImport("sphrender", sphrender.module("sphrender"));
    uts.root_module.addImport("sphalloc", sphalloc.module("sphalloc"));

    const run_uts = b.addRunArtifact(uts);
    test_step.dependOn(&run_uts.step);
}
