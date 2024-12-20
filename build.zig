const std = @import("std");

const Builder = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,

    sphmath: *std.Build.Module,
    sphrender: *std.Build.Module,
    sphtext: *std.Build.Module,

    fn init(b: *std.Build) Builder {
        const target = b.standardTargetOptions(.{});
        const opt = b.standardOptimizeOption(.{});

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

        return .{
            .b = b,
            .target = target,
            .opt = opt,
            .sphmath = sphmath,
            .sphrender = sphrender,
            .sphtext = sphtext,
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
        exe.addCSourceFiles(.{
            .files = &.{
                "cimgui/cimgui.cpp",
                "cimgui/imgui/imgui.cpp",
                "cimgui/imgui/imgui_draw.cpp",
                "cimgui/imgui/imgui_demo.cpp",
                "cimgui/imgui/imgui_tables.cpp",
                "cimgui/imgui/imgui_widgets.cpp",
                "cimgui/imgui/backends/imgui_impl_glfw.cpp",
                "cimgui/imgui/backends/imgui_impl_opengl3.cpp",
            },
        });
        exe.addIncludePath(self.b.path("cimgui"));
        exe.addIncludePath(self.b.path("cimgui/generator/output"));
        exe.addIncludePath(self.b.path("cimgui/imgui/backends"));
        exe.addIncludePath(self.b.path("cimgui/imgui"));
        exe.defineCMacro("IMGUI_IMPL_API", "extern \"C\"");
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
};

pub fn build(b: *std.Build) !void {
    var builder = Builder.init(b);

    const exe = builder.addExecutable("sphimp", "src/main.zig");
    builder.addAppDependencies(exe);
    builder.addGuiDependencies(exe);
    b.installArtifact(exe);

    const lint_exe = builder.addExecutable(
        "lint",
        "src/lint.zig",
    );
    lint_exe.linkSystemLibrary("EGL");
    builder.addAppDependencies(lint_exe);
    b.installArtifact(lint_exe);

    const uts = builder.addTest(
        "test",
        "src/App.zig",
    );
    builder.addAppDependencies(uts);

    const test_step = b.step("test", "");
    const run_uts = b.addRunArtifact(uts);
    test_step.dependOn(&run_uts.step);
}
