const std = @import("std");

const Builder = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,

    check_step: *std.Build.Step,

    sphmath: *std.Build.Module,
    sphrender: *std.Build.Module,
    sphtext: *std.Build.Module,
    sphui: *std.Build.Module,

    fn init(b: *std.Build) Builder {
        const target = b.standardTargetOptions(.{});
        const opt = b.standardOptimizeOption(.{});

        const check_step = b.step("check", "");

        const sphmath = b.createModule(.{
            .root_source_file = b.path("src/sphmath.zig"),
        });

        const sphrender = b.createModule(.{
            .root_source_file = b.path("src/sphrender/sphrender.zig"),
        });
        sphrender.addImport("sphmath", sphmath);

        const sphtext = b.createModule(.{
            .root_source_file = b.path("src/sphtext/sphtext.zig"),
        });
        sphtext.addImport("sphrender", sphrender);
        sphtext.addImport("sphmath", sphmath);

        const sphui = b.createModule(.{
            .root_source_file = b.path("src/gui/gui.zig"),
        });
        sphui.addImport("sphrender", sphrender);
        sphui.addImport("sphmath", sphmath);
        sphui.addImport("sphtext", sphtext);

        return .{
            .b = b,
            .check_step = check_step,
            .target = target,
            .opt = opt,
            .sphmath = sphmath,
            .sphrender = sphrender,
            .sphtext = sphtext,
            .sphui = sphui,
        };
    }

    fn addAppDependencies(
        self: *Builder,
        exe: *std.Build.Step.Compile,
    ) void {
        exe.addCSourceFile(.{
            .file = self.b.path("src/stb_image.c"),
        });
        exe.addCSourceFile(.{
            .file = self.b.path("src/stb_image_write.c"),
        });
        exe.linkSystemLibrary("GL");
        exe.addIncludePath(self.b.path("src"));
        exe.root_module.addImport("sphmath", self.sphmath);
        exe.root_module.addImport("sphrender", self.sphrender);
        exe.root_module.addImport("sphtext", self.sphtext);
        exe.linkLibC();
        exe.linkLibCpp();
    }

    fn addGuiDependencies(self: *Builder, exe: *std.Build.Step.Compile) void {
        exe.linkSystemLibrary("glfw");
        exe.root_module.addImport("sphui", self.sphui);
    }

    fn addExecutable(self: *Builder, name: []const u8, root_source_file: []const u8) *std.Build.Step.Compile {
        return self.b.addExecutable(.{
            .name = name,
            .root_source_file = self.b.path(root_source_file),
            .target = self.target,
            .optimize = self.opt,
        });
    }

    fn addTest(self: *Builder, name: []const u8, root_source_file: []const u8) *std.Build.Step.Compile {
        return self.b.addTest(.{
            .name = name,
            .root_source_file = self.b.path(root_source_file),
            .target = self.target,
            .optimize = self.opt,
        });
    }

    fn installAndCheck(self: *Builder, exe: *std.Build.Step.Compile) !void {
        const check_exe = try self.b.allocator.create(std.Build.Step.Compile);
        check_exe.* = exe.*;
        self.check_step.dependOn(&check_exe.step);
        self.b.installArtifact(exe);
    }
};

pub fn build(b: *std.Build) !void {
    var builder = Builder.init(b);

    const exe = builder.addExecutable("sphimp", "src/main.zig");
    builder.addAppDependencies(exe);
    builder.addGuiDependencies(exe);
    try builder.installAndCheck(exe);

    //const gui_demo = builder.addExecutable(
    //    "gui_demo",
    //    "src/gui/demo.zig",
    //);
    //gui_demo.linkSystemLibrary("glfw");
    //builder.addAppDependencies(gui_demo);
    //gui_demo.root_module.addImport("sphui", builder.sphui);
    //try builder.installAndCheck(gui_demo);

    const lint_exe = builder.addExecutable(
        "lint",
        "src/lint.zig",
    );
    lint_exe.linkSystemLibrary("EGL");
    builder.addAppDependencies(lint_exe);
    try builder.installAndCheck(lint_exe);

    const uts = builder.addTest(
        "test",
        "src/App.zig",
    );
    builder.addAppDependencies(uts);

    const test_step = b.step("test", "");
    const run_uts = b.addRunArtifact(uts);
    test_step.dependOn(&run_uts.step);

    const gui_uts = builder.addTest(
        "gui_test",
        "src/gui/gui.zig",
    );
    builder.addAppDependencies(gui_uts);

    const run_gui_uts = b.addRunArtifact(gui_uts);
    test_step.dependOn(&run_gui_uts.step);
}
