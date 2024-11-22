const std = @import("std");
const Allocator = std.mem.Allocator;
const egl = @cImport({
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
});
const App = @import("App.zig");
const lin = @import("lin.zig");
const obj_mod = @import("object.zig");
const stbiw = @cImport({
    @cInclude("stb_image_write.h");
});

pub const EglContext = struct {
    display: egl.EGLDisplay,
    context: egl.EGLContext,

    pub fn init() !EglContext {
        const display = egl.eglGetDisplay(egl.EGL_DEFAULT_DISPLAY);
        if (display == egl.EGL_NO_DISPLAY) {
            return error.NoDisplay;
        }

        if (egl.eglInitialize(display, null, null) != egl.EGL_TRUE) {
            return error.EglInit;
        }
        errdefer _ = egl.eglTerminate(display);

        if (egl.eglBindAPI(egl.EGL_OPENGL_API) == egl.EGL_FALSE) {
            return error.BindApi;
        }

        var config: egl.EGLConfig = undefined;
        const attribs = [_]egl.EGLint{ egl.EGL_RENDERABLE_TYPE, egl.EGL_OPENGL_BIT, egl.EGL_NONE };

        var num_configs: c_int = 0;
        if (egl.eglChooseConfig(display, &attribs, &config, 1, &num_configs) != egl.EGL_TRUE) {
            return error.ChooseConfig;
        }

        const context = egl.eglCreateContext(display, config, egl.EGL_NO_CONTEXT, null);
        errdefer _ = egl.eglDestroyContext(display, context);
        if (context == egl.EGL_NO_CONTEXT) {
            return error.CreateContext;
        }

        if (egl.eglMakeCurrent(display, egl.EGL_NO_SURFACE, egl.EGL_NO_SURFACE, context) == 0) {
            return error.UpdateContext;
        }
        errdefer _ = egl.eglMakeCurrent(display, egl.EGL_NO_SURFACE, egl.EGL_NO_SURFACE, egl.EGL_NO_CONTEXT);

        return .{
            .display = display,
            .context = context,
        };
    }

    pub fn deinit(self: *EglContext) void {
        _ = egl.eglMakeCurrent(self.display, egl.EGL_NO_SURFACE, egl.EGL_NO_SURFACE, egl.EGL_NO_CONTEXT);
        _ = egl.eglDestroyContext(self.display, self.context);
        _ = egl.eglTerminate(self.display);
    }
};

pub fn writeDummyImage(alloc: Allocator, path: [:0]const u8) !void {
    const data = try alloc.alloc(u8, 100 * 100 * 4);
    defer alloc.free(data);
    @memset(data, 0xff);
    const ret = stbiw.stbi_write_png(path, 100, 100, 4, data.ptr, 100 * 4);
    if (ret == 0) {
        return error.WriteImage;
    }
}

pub fn inputOnCanvas(app: *App) !void {
    // Try dragging some stuff around
    try app.setMousePos(300, 300);
    try app.setMouseDown();
    try app.render();

    try app.setMousePos(100, 100);
    app.setMouseUp();
    try app.render();

    // Try panning
    try app.setMousePos(100, 100);
    app.setMiddleDown();
    try app.render();

    try app.setMousePos(200, 200);
    app.setMiddleUp();
    try app.render();

    // Click the right mouse button a few times (create path elements)
    try app.setMousePos(400, 400);
    try app.clickRightMouse();
    try app.render();

    try app.setMousePos(200, 300);
    try app.clickRightMouse();
    try app.render();

    const keys = [_]u8{ 'S', 'R' };
    for (keys) |key| {
        // Try to apply transformation to an object
        try app.setKeyDown(key, false);
        try app.render();

        try app.setMousePos(400, 400);
        try app.render();

        // Cancel the transformation
        try app.clickRightMouse();

        // Try to apply transformation to an object
        try app.setKeyDown(key, false);
        try app.render();

        try app.setMousePos(400, 400);
        try app.render();

        // Submit the transformation
        try app.setMouseDown();
        app.setMouseUp();
    }
}

const swap_colors_frag =
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform sampler2D u_texture;  // The texture
    \\void main()
    \\{
    \\    vec4 tmp = texture(u_texture, vec2(uv.x, 1.0 - uv.y));
    \\    fragment = vec4(tmp.y, tmp.x, tmp.z, tmp.w);
    \\}
;

const default_brush =
    \\#version 330 core
    \\
    \\in vec2 uv;
    \\out vec4 fragment;
    \\
    \\uniform sampler2D distance_field;
    \\uniform float width = 0.02;
    \\uniform vec3 color = vec3(1.0, 0.0, 0.0);
    \\uniform float alpha_falloff_multiplier = 5;
    \\
    \\void main()
    \\{
    \\    float distance = texture(distance_field, vec2(uv.x, uv.y)).r;
    \\    float alpha = 1.0 - clamp((distance - width) * alpha_falloff_multiplier * 10, 0.0, 1.0);
    \\    if (alpha <= 0.0) {
    \\        discard;
    \\    }
    \\    fragment = vec4(color, alpha);
    \\}
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() != .ok) {
            std.process.exit(1);
        }
    }

    const alloc = gpa.allocator();

    var egl_context = try EglContext.init();
    defer egl_context.deinit();

    var app = try App.init(alloc, 640, 480);
    defer app.deinit();

    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    var tmpdir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_path = try tmpdir.dir.realpath(".", &tmpdir_path_buf);

    var dummy_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dummy_path = try std.fmt.bufPrintZ(&dummy_path_buf, "{s}/dummy.png", .{tmpdir_path});
    try writeDummyImage(alloc, dummy_path);

    const swap_colors_id = try app.addShaderFromFragmentSource("swap colors", swap_colors_frag);
    _ = try app.addBrushFromFragmnetSource("default brush", default_brush);

    for (0..2) |_| {
        const composition_idx = try app.addComposition();

        const id = try app.loadImage(dummy_path);

        var buf: [1024]u8 = undefined;
        const swapped_name = try std.fmt.bufPrint(&buf, "{s}_swapped", .{dummy_path});
        const shader_id = try app.addShaderObject(
            swapped_name,
            swap_colors_id,
        );
        app.setSelectedObject(shader_id);
        try app.setShaderDependency(0, .{ .image = id });

        app.setSelectedObject(composition_idx);
        _ = try app.addToComposition(id);
        const shader_composition_idx = try app.addToComposition(shader_id);
        _ = try app.addToComposition(shader_id);
        try app.deleteFromComposition(shader_composition_idx);

        app.setSelectedObject(id);
        _ = try app.createPath();

        app.setSelectedObject(shader_id);
        const path_id = try app.createPath();

        app.setSelectedObject(path_id);
        try app.updatePathDisplayObj(id);
    }

    _ = try app.addDrawing();

    var it = app.objects.idIter();
    while (it.next()) |i| {
        app.setSelectedObject(i);
        try inputOnCanvas(&app);
    }

    var save_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const save_path = try std.fmt.bufPrint(&save_path_buf, "{s}/save.json", .{tmpdir_path});

    try app.save(save_path);
    app.deinit();

    app = try App.init(alloc, 640, 480);
    try app.load(save_path);

    it = app.objects.idIter();
    while (it.next()) |i| {
        app.setSelectedObject(i);
        try inputOnCanvas(&app);
    }
}
