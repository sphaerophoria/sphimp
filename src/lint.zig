const std = @import("std");
const Allocator = std.mem.Allocator;
const egl = @cImport({
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
});
const sphimp = @import("sphimp");
const App = sphimp.App;
const AppView = sphimp.AppView;
const sphmath = @import("sphmath");
const obj_mod = sphimp.object;
const stbiw = @import("stb_image_write");
const sphalloc = @import("sphalloc");
const Sphalloc = sphalloc.Sphalloc;
const ScratchAlloc = sphalloc.ScratchAlloc;

const sphrender = @import("sphrender");
const RenderAlloc = sphrender.RenderAlloc;
const GlAlloc = sphrender.GlAlloc;
const ViewState = sphimp.ViewState;

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

pub fn inputOnCanvas(app_view: *AppView, now: std.time.Instant) !void {
    const selected_object = app_view.selectedObject();
    var new_name_buf: [1024]u8 = undefined;
    const new_name = try std.fmt.bufPrint(&new_name_buf, "{s}1", .{selected_object.name});
    try selected_object.updateName(new_name);

    // Try dragging some stuff around
    try app_view.setMousePos(300, 300);
    try app_view.setMouseDown();
    try app_view.render(now);

    try app_view.setMousePos(100, 100);
    app_view.setMouseUp();
    try app_view.render(now);

    // Try panning
    try app_view.setMousePos(100, 100);
    app_view.setMiddleDown();
    try app_view.render(now);

    try app_view.setMousePos(200, 200);
    app_view.setMiddleUp();
    try app_view.render(now);

    // Render sometimes in debug mode
    if (selected_object.data == .composition) {
        try app_view.app.toggleCompositionDebug();
    }

    // Click the right mouse button a few times (create path elements)
    try app_view.setMousePos(400, 400);
    try app_view.setRightDown();
    try app_view.render(now);

    try app_view.setMousePos(200, 300);
    try app_view.setRightDown();
    try app_view.render(now);

    const keys = [_]u8{ 'S', 'R' };
    for (keys) |key| {
        // Try to apply transformation to an object
        try app_view.setKeyDown(key, false);
        try app_view.render(now);

        try app_view.setMousePos(400, 400);
        try app_view.render(now);

        // Cancel the transformation
        try app_view.setRightDown();

        // Try to apply transformation to an object
        try app_view.setKeyDown(key, false);
        try app_view.render(now);

        try app_view.setMousePos(400, 400);
        try app_view.render(now);

        // Submit the transformation
        try app_view.setMouseDown();
        app_view.setMouseUp();
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

fn loadFonts(app: *App) !void {
    const font_paths = [_][:0]const u8{ "res/ttf/Hack-Regular.ttf", "res/ttf/NotoSans-Regular.ttf" };
    for (&font_paths) |p| {
        _ = try app.loadFont(p);
    }
}

pub fn main() !void {
    var page_alloc = sphalloc.TinyPageAllocator(100){ .page_allocator = std.heap.page_allocator };
    var root_alloc: Sphalloc = undefined;
    try root_alloc.initPinned(page_alloc.allocator(), "root");
    defer root_alloc.deinit();

    const args = try std.process.argsAlloc(root_alloc.arena());

    const alloc = root_alloc.general();
    const scratch_buf = try alloc.alloc(u8, 10 * 1024 * 1024);
    var scratch_alloc = ScratchAlloc.init(scratch_buf);

    var egl_context = try EglContext.init();
    defer egl_context.deinit();

    var root_gl_alloc = try GlAlloc.init(&root_alloc);
    defer root_gl_alloc.reset();

    const root_render_alloc = RenderAlloc.init(&root_alloc, &root_gl_alloc);

    const scratch_gl = try root_gl_alloc.makeSubAlloc(&root_alloc);

    var app = try App.init(root_render_alloc, &scratch_alloc, scratch_gl, args[0]);
    defer app.deinit();

    var app_view = AppView{
        .app = &app,
        .view_state = .{
            .window_width = 800,
            .window_height = 800,
        },
    };

    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    var tmpdir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmpdir_path = try tmpdir.dir.realpath(".", &tmpdir_path_buf);

    var dummy_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dummy_path = try std.fmt.bufPrintZ(&dummy_path_buf, "{s}/dummy.png", .{tmpdir_path});
    try writeDummyImage(alloc, dummy_path);

    const swap_colors_id = try app.addShaderFromFragmentSource("swap colors", swap_colors_frag);
    _ = try app.addBrushFromFragmnetSource("default brush", default_brush);

    const now = try std.time.Instant.now();

    for (0..2) |_| {
        const composition_id = try app.addComposition();

        const id = try app.loadImage(dummy_path);

        var buf: [1024]u8 = undefined;
        const swapped_name = try std.fmt.bufPrint(&buf, "{s}_swapped", .{dummy_path});
        const shader_id = try app.addShaderObject(
            swapped_name,
            swap_colors_id,
        );
        try app.setShaderImage(shader_id, 0, id);

        _ = try app.addToComposition(composition_id, id);
        const shader_composition_idx = try app.addToComposition(composition_id, shader_id);
        _ = try app.addToComposition(composition_id, shader_id);
        try app.deleteFromComposition(composition_id, shader_composition_idx);

        _ = try app.createPath(id);

        const path_id = try app.createPath(shader_id);

        try app.updatePathDisplayObj(path_id, id);
    }

    try loadFonts(&app);

    {
        var id_iter = app.objects.idIter();
        _ = try app.addDrawing(id_iter.next().?);
    }

    var font_ids = app.fonts.idIter();
    _ = font_ids.next(); // Discard first id, it will be used by default
    const second_font_id = font_ids.next() orelse return error.NotEnoughFonts;

    const text_id = try app.addText();

    try app.updateTextObjectContent(text_id, "hello world");
    try app.updateFontId(text_id, second_font_id);
    try app.updateFontSize(text_id, 10.0);

    var it = app.objects.idIter();
    while (it.next()) |i| {
        scratch_gl.reset();
        app_view.setSelectedObject(i);
        try inputOnCanvas(&app_view, now);
    }

    var save_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const save_path = try std.fmt.bufPrint(&save_path_buf, "{s}/save.json", .{tmpdir_path});

    try app.save(save_path);
    app.deinit();

    app = try App.init(root_render_alloc, &scratch_alloc, scratch_gl, args[0]);
    try app.load(save_path);

    it = app.objects.idIter();
    while (it.next()) |i| {
        scratch_gl.reset();
        app_view.setSelectedObject(i);
        try inputOnCanvas(&app_view, now);
    }
}
