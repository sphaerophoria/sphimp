const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("App.zig");
const sphrender = @import("sphrender");
const obj_mod = @import("object.zig");
const sphmath = @import("sphmath");
const shader_storage = @import("shader_storage.zig");
const Renderer = @import("Renderer.zig");
const ShaderStorage = shader_storage.ShaderStorage;
const ShaderId = shader_storage.ShaderId;
const FontStorage = @import("FontStorage.zig");
const BrushId = shader_storage.BrushId;
const gui = @import("sphui");
const WindowAction = gui.WindowAction;
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});
const glfwb = c;

fn logError(comptime msg: []const u8, e: anyerror, trace: ?*std.builtin.StackTrace) void {
    std.log.err(msg ++ ": {s}", .{@errorName(e)});
    if (trace) |t| std.debug.dumpStackTrace(t.*);
}

fn errorCallbackGlfw(_: c_int, description: [*c]const u8) callconv(.C) void {
    std.log.err("Error: {s}\n", .{std.mem.span(description)});
}

fn keyCallbackGlfw(window: ?*glfwb.GLFWwindow, key: c_int, _: c_int, action: c_int, modifiers: c_int) callconv(.C) void {
    if (action != glfwb.GLFW_PRESS) {
        return;
    }

    const glfw: *Glfw = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(window)));

    const key_char: gui.Key = switch (key) {
        glfwb.GLFW_KEY_A...glfwb.GLFW_KEY_Z => .{ .ascii = @intCast(key - glfwb.GLFW_KEY_A + 'a') },
        glfwb.GLFW_KEY_SPACE => .{ .ascii = ' ' },
        glfwb.GLFW_KEY_LEFT => .left_arrow,
        glfwb.GLFW_KEY_RIGHT => .right_arrow,
        glfwb.GLFW_KEY_BACKSPACE => .backspace,
        glfwb.GLFW_KEY_DELETE => .delete,
        else => return,
    };

    glfw.queue.writeItem(.{
        .key_down = .{
            .key = key_char,
            .ctrl = (modifiers & glfwb.GLFW_MOD_CONTROL) != 0,
        },
    }) catch |e| {
        logError("Failed to write key press", e, @errorReturnTrace());
    };
}

fn cursorPositionCallbackGlfw(window: ?*glfwb.GLFWwindow, xpos: f64, ypos: f64) callconv(.C) void {
    const glfw: *Glfw = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(window)));
    glfw.queue.writeItem(.{
        .mouse_move = .{
            .x = @floatCast(xpos),
            .y = @floatCast(ypos),
        },
    }) catch |e| {
        logError("Failed to write mouse movement", e, @errorReturnTrace());
    };
}

fn mouseButtonCallbackGlfw(window: ?*glfwb.GLFWwindow, button: c_int, action: c_int, _: c_int) callconv(.C) void {
    const glfw: *Glfw = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(window)));
    const is_down = action == glfwb.GLFW_PRESS;
    var write_obj: ?WindowAction = null;

    if (button == glfwb.GLFW_MOUSE_BUTTON_LEFT and is_down) {
        write_obj = .mouse_down;
    } else if (button == glfwb.GLFW_MOUSE_BUTTON_LEFT and !is_down) {
        write_obj = .mouse_up;
    } else if (button == glfwb.GLFW_MOUSE_BUTTON_MIDDLE and is_down) {
        write_obj = .middle_down;
    } else if (button == glfwb.GLFW_MOUSE_BUTTON_MIDDLE and !is_down) {
        write_obj = .middle_up;
    } else if (button == glfwb.GLFW_MOUSE_BUTTON_RIGHT and is_down) {
        write_obj = .right_click;
    }

    if (write_obj) |w| {
        glfw.queue.writeItem(w) catch |e| {
            logError("Failed to write mouse press/release", e, @errorReturnTrace());
        };
    }
}

fn scrollCallbackGlfw(window: ?*glfwb.GLFWwindow, _: f64, y: f64) callconv(.C) void {
    const glfw: *Glfw = @ptrCast(@alignCast(glfwb.glfwGetWindowUserPointer(window)));
    glfw.queue.writeItem(.{
        .scroll = @floatCast(y),
    }) catch |e| {
        logError("Failed to write scroll", e, @errorReturnTrace());
    };
}

const Glfw = struct {
    window: *glfwb.GLFWwindow = undefined,
    queue: Fifo = undefined,

    const Fifo = std.fifo.LinearFifo(WindowAction, .{ .Static = 1024 });

    fn initPinned(self: *Glfw, window_width: comptime_int, window_height: comptime_int) !void {
        _ = glfwb.glfwSetErrorCallback(errorCallbackGlfw);

        if (glfwb.glfwInit() != glfwb.GLFW_TRUE) {
            return error.GLFWInit;
        }
        errdefer glfwb.glfwTerminate();

        glfwb.glfwWindowHint(glfwb.GLFW_CONTEXT_VERSION_MAJOR, 3);
        glfwb.glfwWindowHint(glfwb.GLFW_CONTEXT_VERSION_MINOR, 3);
        glfwb.glfwWindowHint(glfwb.GLFW_OPENGL_PROFILE, glfwb.GLFW_OPENGL_CORE_PROFILE);
        glfwb.glfwWindowHint(glfwb.GLFW_OPENGL_DEBUG_CONTEXT, 1);
        glfwb.glfwWindowHint(glfwb.GLFW_SAMPLES, 4);

        const window = glfwb.glfwCreateWindow(window_width, window_height, "sphimp", null, null);
        if (window == null) {
            return error.CreateWindow;
        }
        errdefer glfwb.glfwDestroyWindow(window);

        _ = glfwb.glfwSetKeyCallback(window, keyCallbackGlfw);
        _ = glfwb.glfwSetCursorPosCallback(window, cursorPositionCallbackGlfw);
        _ = glfwb.glfwSetMouseButtonCallback(window, mouseButtonCallbackGlfw);
        _ = glfwb.glfwSetScrollCallback(window, scrollCallbackGlfw);

        glfwb.glfwMakeContextCurrent(window);
        glfwb.glfwSwapInterval(1);

        glfwb.glfwSetWindowUserPointer(window, self);

        self.* = .{
            .window = window.?,
            .queue = Fifo.init(),
        };
    }

    fn deinit(self: *Glfw) void {
        glfwb.glfwDestroyWindow(self.window);
        glfwb.glfwTerminate();
    }

    fn closed(self: *Glfw) bool {
        return glfwb.glfwWindowShouldClose(self.window) == glfwb.GLFW_TRUE;
    }

    fn getWindowSize(self: *Glfw) struct { usize, usize } {
        var width: c_int = 0;
        var height: c_int = 0;
        glfwb.glfwGetFramebufferSize(self.window, &width, &height);
        return .{ @intCast(width), @intCast(height) };
    }

    fn swapBuffers(self: *Glfw) void {
        glfwb.glfwSwapBuffers(self.window);
        glfwb.glfwPollEvents();
    }
};


const Args = struct {
    action: Action,
    it: std.process.ArgIterator,

    const Action = union(enum) {
        load: []const u8,
        new: struct {
            brushes: []const [:0]const u8,
            shaders: []const [:0]const u8,
            images: []const [:0]const u8,
            fonts: []const [:0]const u8,
        },
    };

    const ParseState = enum {
        unknown,
        brushes,
        shaders,
        images,
        fonts,

        fn parse(arg: []const u8) ParseState {
            return std.meta.stringToEnum(ParseState, arg[2..]) orelse return .unknown;
        }
    };

    fn parse(alloc: Allocator) !Args {
        var it = try std.process.argsWithAllocator(alloc);
        const process_name = it.next() orelse "sphimp";

        const first_arg = it.next() orelse help(process_name);

        if (std.mem.eql(u8, first_arg, "--load")) {
            const save = it.next() orelse {
                std.log.err("No save file provided for --load", .{});
                help(process_name);
            };

            return .{
                .action = .{ .load = save },
                .it = it,
            };
        }

        var images = std.ArrayList([:0]const u8).init(alloc);
        defer images.deinit();

        var shaders = std.ArrayList([:0]const u8).init(alloc);
        defer shaders.deinit();

        var brushes = std.ArrayList([:0]const u8).init(alloc);
        defer brushes.deinit();

        var fonts = std.ArrayList([:0]const u8).init(alloc);
        defer fonts.deinit();

        var parse_state = ParseState.parse(first_arg);
        while (it.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--")) {
                const new_state = ParseState.parse(arg);
                if (new_state == .unknown) {
                    std.log.err("Unknown switch {s}", .{arg});
                    help(process_name);
                }
                parse_state = new_state;
                continue;
            }

            switch (parse_state) {
                .unknown => {
                    std.log.err("Please specify one of --load, --images, --shaders, --brushes", .{});
                    help(process_name);
                },
                .images => try images.append(arg),
                .brushes => try brushes.append(arg),
                .shaders => try shaders.append(arg),
                .fonts => try fonts.append(arg),
            }
        }

        return .{
            .action = .{
                .new = .{
                    .images = try images.toOwnedSlice(),
                    .shaders = try shaders.toOwnedSlice(),
                    .brushes = try brushes.toOwnedSlice(),
                    .fonts = try fonts.toOwnedSlice(),
                },
            },
            .it = it,
        };
    }

    fn deinit(self: *Args, alloc: Allocator) void {
        switch (self.action) {
            .load => {},
            .new => |items| {
                alloc.free(items.images);
                alloc.free(items.brushes);
                alloc.free(items.shaders);
                alloc.free(items.fonts);
            },
        }

        self.it.deinit();
    }

    fn help(process_name: []const u8) noreturn {
        const stderr = std.io.getStdErr().writer();

        stderr.print(
            \\USAGE:
            \\{s} --load <save.json>
            \\OR
            \\{s} --images <image.png> <image2.png> --shaders <shader1.glsl> ... --brushes <brush1.glsl> <brush2.glsl>... --fonts <font1.ttf> <font2.ttf>...
            \\
        , .{ process_name, process_name }) catch {};
        std.process.exit(1);
    }
};

const background_fragment_shader =
    \\#version 330
    \\
    \\out vec4 fragment;
    \\uniform vec3 color = vec3(1.0, 1.0, 1.0);
    \\
    \\void main()
    \\{
    \\    fragment = vec4(color, 1.0);
    \\}
;

const UiAction = union(enum) {
    update_selected_object: obj_mod.ObjectId,
    create_path,
    create_composition,
    create_drawing,
    create_text,
    create_shader: ShaderId,
    delete_selected_object,
    edit_selected_object_name: struct {
        notifier: gui.textbox.TextboxNotifier,
        pos: usize,
        items: []const gui.KeyEvent,
    },
    update_composition_width: f32,
    update_composition_height: f32,

    fn makeEditName(notifier: gui.textbox.TextboxNotifier, pos: usize, items: []const gui.KeyEvent) UiAction {
        return .{
            .edit_selected_object_name = .{
                .notifier = notifier,
                .pos = pos,
                .items = items,
            },
        };
    }

    fn makeUpdateCompositionWidth(val: f32) UiAction {
        return .{ .update_composition_width = val};
    }

    fn makeUpdateCompositionHeight(val: f32) UiAction {
        return .{ .update_composition_height = val};
    }
};

const ObjectListRetriever = struct {
    app: *App,

    pub fn numItems(self: ObjectListRetriever) usize {
        return self.app.objects.numItems();
    }

    pub fn selectedId(self: ObjectListRetriever) usize {
        const selected_object = self.app.input_state.selected_object;

        var it = self.app.objects.idIter();
        var idx: usize = 0;
        while (it.next()) |id| {
            defer idx += 1;
            if (id.value == selected_object.value) {
                return idx;
            }
        }

        return 0;
    }

    pub fn getText(self: ObjectListRetriever, idx: usize) []const u8 {
        var it = self.app.objects.idIter();

        var object_id: obj_mod.ObjectId = it.next().?;
        for (0..idx) |_| {
            object_id = it.next() orelse break;
        }

        return self.app.objects.get(object_id).name;
    }
};


const ObjectListActionGen = struct {
    app: *App,
    pub fn generate(self: ObjectListActionGen, idx: usize) UiAction {
        var it = self.app.objects.idIter();

        var object_id: obj_mod.ObjectId = it.next().?;
        for (0..idx) |_| {
            object_id = it.next() orelse break;
        }

        return .{
            .update_selected_object = object_id,
        };
    }
};
const ShaderListRetriever = struct {
    app: *App,

    pub fn numItems(self: ShaderListRetriever) usize {
        return self.app.shaders.numItems();
    }

    pub fn selectedId(_: ShaderListRetriever) usize {
        return std.math.maxInt(usize);
    }

    pub fn getText(self: ShaderListRetriever, idx: usize) []const u8 {
        var it = self.app.shaders.idIter();

        var shader_id: ShaderId = it.next().?;
        for (0..idx) |_| {
            shader_id = it.next() orelse break;
        }

        return self.app.shaders.get(shader_id).name;
    }
};

const CreateShaderActionGen = struct {
    app: *App,
    pub fn generate(self: CreateShaderActionGen, idx: usize) UiAction {
        var it = self.app.shaders.idIter();

        var shader_id: ShaderId = it.next().?;
        for (0..idx) |_| {
            shader_id = it.next() orelse break;
        }

        return .{
            .create_shader = shader_id,
        };
    }
};


fn makeObjList(app: *App, default_gui: *gui.default_gui.DefaultGui(UiAction), wrap_width: u31) !gui.Widget(UiAction) {
    const object_list_layout = try default_gui.makeLayout();
    errdefer object_list_layout.deinit(default_gui.alloc);

    const label = try default_gui.makeLabel("Object list", wrap_width);
    try object_list_layout.pushOrDeinitWidget(default_gui.alloc, label);

    const obj_list = try default_gui.makeSelectableList(ObjectListRetriever { .app = app }, ObjectListActionGen { .app = app } );
    // FIXME: errdefer free obj_list
    const scroll_select = try default_gui.makeScrollView(obj_list);
    try object_list_layout.pushOrDeinitWidget(default_gui.alloc, scroll_select);

    return object_list_layout.asWidget();
}

fn makeCreateObject(app: *App, default_gui: *gui.default_gui.DefaultGui(UiAction), wrap_width: u31) !gui.Widget(UiAction) {
    const layout = try default_gui.makeLayout();
    errdefer layout.deinit(default_gui.alloc);

    {
        const label = try default_gui.makeLabel("Create an item", wrap_width);
        try layout.pushOrDeinitWidget(default_gui.alloc, label);
    }

    {
        const button = try default_gui.makeButton("New path", .create_path);
        try layout.pushOrDeinitWidget(default_gui.alloc, button);
    }
    {
        const button = try default_gui.makeButton("New composition", .create_composition);
        try layout.pushOrDeinitWidget(default_gui.alloc, button);
    }
    {
        const button = try default_gui.makeButton("New drawing", .create_drawing);
        try layout.pushOrDeinitWidget(default_gui.alloc, button);
    }
    {
        const button = try default_gui.makeButton("New text", .create_text);
        try layout.pushOrDeinitWidget(default_gui.alloc, button);
    }

    {
        const label = try default_gui.makeLabel("Create an shader", wrap_width);
        try layout.pushOrDeinitWidget(default_gui.alloc, label);

        const shader_list = try default_gui.makeSelectableList(ShaderListRetriever { .app = app }, CreateShaderActionGen { .app = app } );
        try layout.pushOrDeinitWidget(default_gui.alloc, shader_list);

    }

    return try default_gui.makeScrollView(layout.asWidget());
}

const CurrentObjectNameRetriever = struct {
    app: *App,

    pub fn getText(self: *CurrentObjectNameRetriever) []const u8 {
        return self.app.objects.get(self.app.input_state.selected_object).name;
    }
};


const CurrentObjectWidthRetriever = struct {
    app: *App,
    buf: [16]u8 = undefined,

    pub fn getText(self: *CurrentObjectWidthRetriever) []const u8 {
        return std.fmt.bufPrint(&self.buf, "Width: {d}", .{
            self.app.objects.get(self.app.input_state.selected_object).dims(&self.app.objects)[0],
        }) catch "Width: undefined";
    }
};

const CurrentObjectHeightRetriever = struct {
    app: *App,
    buf: [17]u8 = undefined,

    pub fn getText(self: *CurrentObjectHeightRetriever) []const u8 {
        return std.fmt.bufPrint(&self.buf, "Height: {d}", .{
            self.app.objects.get(self.app.input_state.selected_object).dims(&self.app.objects)[1],
        }) catch "Height: undefined";
    }
};

pub fn LabelTextBuf(comptime size: usize) type {
    return struct {
        buf: [size]u8,
        text_len: usize,

        pub fn getText(self: *const @This()) []const u8 {
            return self.buf[0..self.text_len];
        }
    };
}

fn labelTextBuf(comptime fmt: []const u8, args: anytype, comptime max_len: usize) LabelTextBuf(max_len) {
    var buf: [max_len]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..max_len];
    std.debug.print("got slice: {s}\n" ,.{slice});
    return .{
        .buf = buf,
        .text_len = slice.len,
    };
}


const CurrentObjectWidthRetrieverf32 = struct {
    app: *App,

    pub fn getVal(self: *CurrentObjectWidthRetrieverf32) f32 {
        return @floatFromInt(self.app.objects.get(self.app.input_state.selected_object).dims(&self.app.objects)[0]);
    }
};

const CurrentObjectHeightRetrieverf32 = struct {
    app: *App,

    pub fn getVal(self: *CurrentObjectHeightRetrieverf32) f32 {
        return @floatFromInt(self.app.objects.get(self.app.input_state.selected_object).dims(&self.app.objects)[1]);
    }
};

fn regenerateSpecificObjectProperties(app: *App, default_gui: *gui.default_gui.DefaultGui(UiAction), layout: *gui.layout.Layout(UiAction), wrap_width: u31) !void {

    layout.reset(default_gui.alloc);

    const selected_obj = app.objects.get(app.input_state.selected_object);
    switch (selected_obj.data) {
        .filesystem => |fs_obj| {
            const object_type = try default_gui.makeLabel("Filesystem object", wrap_width);
            try layout.pushOrDeinitWidget(default_gui.alloc, object_type);

            const source_label = try default_gui.makeLabel(labelTextBuf("Source: {s}", .{fs_obj.source}, 1024), wrap_width);
            try layout.pushOrDeinitWidget(default_gui.alloc, source_label);
        },
        .generated_mask => {
            const object_type = try default_gui.makeLabel("Generated mask", wrap_width);
            try layout.pushOrDeinitWidget(default_gui.alloc, object_type);
        },
        .composition => {
            const object_type = try default_gui.makeLabel("Composition", wrap_width);
            try layout.pushOrDeinitWidget(default_gui.alloc, object_type);

            const width_label = try default_gui.makeLabel("Width", wrap_width);
            try layout.pushOrDeinitWidget(default_gui.alloc, width_label);

            const width_dragger = try default_gui.makeDragFloatWithSpeed(1.0, CurrentObjectWidthRetrieverf32 { .app = app }, &UiAction.makeUpdateCompositionWidth);
            try layout.pushOrDeinitWidget(default_gui.alloc, width_dragger);

            const height_label = try default_gui.makeLabel("Height", wrap_width);
            try layout.pushOrDeinitWidget(default_gui.alloc, height_label);

            const height_dragger = try default_gui.makeDragFloatWithSpeed(1.0, CurrentObjectHeightRetrieverf32 { .app = app }, &UiAction.makeUpdateCompositionHeight);
            try layout.pushOrDeinitWidget(default_gui.alloc, height_dragger);
        },
        //.shader: ShaderObject,
        //.path: PathObject,
        //.generated_mask: GeneratedMaskObject,
        //.drawing: DrawingObject,
        //.text: TextObject,
        else => {},
    }

}

fn makeObjectProperties(app: *App, default_gui: *gui.default_gui.DefaultGui(UiAction), wrap_width: u31, specific_properties: gui.Widget(UiAction)) !gui.Widget(UiAction) {
    // FIXME: Errdefer specific properties?

    const layout = try default_gui.makeLayout();
    errdefer layout.deinit(default_gui.alloc);

    const layout_name = try default_gui.makeLabel("Object properties", wrap_width);
    try layout.pushOrDeinitWidget(default_gui.alloc, layout_name);

    // Name: [name.txt]
    {
        const name_edit = try default_gui.makeLayout();
        try layout.pushOrDeinitWidget(default_gui.alloc, name_edit.asWidget());

        name_edit.cursor.direction = .horizontal;

        const name_edit_label = try default_gui.makeLabel("Name: ", wrap_width);
        try name_edit.pushOrDeinitWidget(default_gui.alloc, name_edit_label);

        const name_box = try default_gui.makeTextbox(CurrentObjectNameRetriever { .app = app }, &UiAction.makeEditName);
        try name_edit.pushOrDeinitWidget(default_gui.alloc, name_box);
    }

    const delete_button = try default_gui.makeButton("Delete", .delete_selected_object);
    try layout.pushOrDeinitWidget(default_gui.alloc, delete_button);

    const width = try default_gui.makeLabel(CurrentObjectWidthRetriever { .app = app }, wrap_width);
    try layout.pushOrDeinitWidget(default_gui.alloc, width);

    const height = try default_gui.makeLabel(CurrentObjectHeightRetriever { .app = app }, wrap_width);
    try layout.pushOrDeinitWidget(default_gui.alloc, height);

    try layout.pushOrDeinitWidget(default_gui.alloc, specific_properties);

    return layout.asWidget();
}

const AppWidget = struct {
    size: gui.PixelSize,
    app: *App,

    const widget_vtable = gui.Widget(UiAction).VTable {
            .deinit = AppWidget.deinit,
            .render = AppWidget.render,
            .getSize = AppWidget.getSize,
            .update = AppWidget.update,
            .setInputState = AppWidget.setInputState,
    };

    fn init(alloc: Allocator, app: *App, size: gui.PixelSize) !gui.Widget(UiAction) {
        const ctx = try alloc.create(AppWidget);
        ctx.* = .{
            .app = app,
            .size = size,
        };
        return .{
            .vtable = &widget_vtable,
            .ctx = ctx,
        };
    }

    fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
        _ = ctx;
        _ = alloc;
    }

    fn render(ctx: ?*anyopaque, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
        const self: *AppWidget = @ptrCast(@alignCast(ctx));
        const viewport = sphrender.TemporaryViewport.init();
        defer viewport.reset();
        viewport.setViewportOffset(widget_bounds.left, window_bounds.calcHeight() - widget_bounds.bottom, widget_bounds.calcWidth(), widget_bounds.calcHeight());

        const scissor = sphrender.TemporaryScissor.init();
        defer scissor.reset();
        scissor.set(widget_bounds.left, window_bounds.calcHeight() - widget_bounds.bottom, widget_bounds.calcWidth(), widget_bounds.calcHeight());


        self.app.render() catch return;

    }

    fn getSize(ctx: ?*anyopaque) gui.PixelSize {
        const self: *AppWidget = @ptrCast(@alignCast(ctx));
        return self.size;
    }

    fn update(ctx: ?*anyopaque, available_size: gui.PixelSize) anyerror!void {
        const self: *AppWidget = @ptrCast(@alignCast(ctx));
        self.size = available_size;
        self.app.view_state.window_width = available_size.width;
        self.app.view_state.window_height = available_size.height;
    }

    fn setInputState(ctx: ?*anyopaque, widget_bounds: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: gui.InputState) gui.InputResponse(UiAction) {
        const self: *AppWidget = @ptrCast(@alignCast(ctx));

        const no_action = gui.InputResponse(UiAction) {
            .wants_focus = false,
            .action = null,
        };

        self.trySetInputState(widget_bounds, input_bounds, input_state) catch |e| {
            logError("input handling failed", e, @errorReturnTrace());
        };

        return no_action;
    }

    fn trySetInputState(self: *AppWidget, widget_bounds: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: gui.InputState) !void {
        if (input_state.mouse_middle_released) self.app.setMiddleUp();
        if (input_state.mouse_released) self.app.setMouseUp();

        try self.app.setMousePos(
            input_state.mouse_pos.x - @as(f32, @floatFromInt(widget_bounds.left)),
            input_state.mouse_pos.y - @as(f32, @floatFromInt(widget_bounds.top)),
        );

        if (!input_bounds.containsMousePos(input_state.mouse_pos)) {
            return;
        }

        if (input_state.mouse_right_pressed) try self.app.clickRightMouse();
        if (input_state.mouse_middle_pressed) self.app.setMiddleDown();
        if (input_state.mouse_pressed) try self.app.setMouseDown();

        for (input_state.frame_keys.items) |key| {
            if (key.key == .ascii) {
                try self.app.setKeyDown(key.key.ascii, key.ctrl);
            }
        }

        self.app.scroll(input_state.frame_scroll);
    }

    //setFocused: ?*const fn (ctx: ?*anyopaque, focused: bool) void = null,

};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var args = try Args.parse(alloc);
    defer args.deinit(alloc);

    const window_width = 1024;
    const window_height = 600;

    var glfw = Glfw{};


    try glfw.initPinned(window_width, window_height);
    defer glfw.deinit();

    var app = try App.init(alloc, window_width, window_height);
    defer app.deinit();

    const background_shader_id = try app.addShaderFromFragmentSource("constant color", background_fragment_shader);

    switch (args.action) {
        .load => |s| {
            try app.load(s);
        },
        .new => |items| {
            for (items.images) |path| {
                _ = try app.loadImage(path);
            }

            for (items.shaders) |path| {
                _ = try app.loadShader(path);
            }

            for (items.brushes) |path| {
                _ = try app.loadBrush(path);
            }

            for (items.fonts) |path| {
                _ = try app.loadFont(path);
            }

            if (items.images.len == 0) {
                _ = try app.addShaderObject("background", background_shader_id);
                const drawing = try app.addDrawing();
                app.setSelectedObject(drawing);
            }
        },
    }

    const default_gui = try gui.default_gui.defaultGui(UiAction, alloc);
    defer default_gui.deinit();

    const object_list_stack = try default_gui.makeStack();
    const sidebar_width = window_width / 3;
    var widget_bounds = gui.PixelBBox {
        .top = 0,
        .left = 0,
        .right = sidebar_width,
        .bottom = window_height,
    };
    const object_list_background = try default_gui.makeRect(
        // FIXME: Rect should just fill space
        .{
            .width = @intCast(widget_bounds.right),
            .height = @intCast(widget_bounds.bottom),
        },
        gui.default_gui.GlobalStyle.background_color,
        true,
    );
    try object_list_stack.pushWidgetOrDeinit(default_gui.alloc, object_list_background, .{ .offset =  .{ .x_offs = 0, .y_offs = 0 }});

    const toplevel_layout = try default_gui.makeLayout();
    // FIXME: errdefer

    const sidebar_layout = try default_gui.makeEvenVertLayout(widget_bounds.calcWidth());
    try toplevel_layout.pushOrDeinitWidget(default_gui.alloc, object_list_stack.asWidget());

    // FIXME: Deinit order shennanigans
    try sidebar_layout.pushOrDeinitWidget(default_gui.alloc, try makeObjList(&app, default_gui, sidebar_width));
    try sidebar_layout.pushOrDeinitWidget(default_gui.alloc, try makeCreateObject(&app, default_gui, sidebar_width));

    const specific_object_properties = try default_gui.makeLayout();
    try sidebar_layout.pushOrDeinitWidget(default_gui.alloc, try makeObjectProperties(&app, default_gui, sidebar_width, specific_object_properties.asWidget()));
    try regenerateSpecificObjectProperties(&app, default_gui, specific_object_properties, sidebar_width);

    try object_list_stack.pushWidgetOrDeinit(default_gui.alloc, sidebar_layout.asWidget(), .centered);

    const app_widget = try AppWidget.init(alloc, &app, .{.width = window_width, .height = window_height });

    toplevel_layout.cursor.direction = .horizontal;
    toplevel_layout.item_pad = 0;
    try toplevel_layout.pushOrDeinitWidget(default_gui.alloc, app_widget);

    try default_gui.setRootWidgetOrDeinit(toplevel_layout.asWidget());


    while (!glfw.closed()) {
        const width, const height = glfw.getWindowSize();

        sphrender.gl.glViewport(0, 0, @intCast(width), @intCast(height));

        widget_bounds.bottom = @intCast(height);
        //if (try imgui.renderObjectProperties(app.input_state.selected_object, &app.objects, app.shaders, app.brushes, app.fonts)) |action| {
        //    switch (action) {
        //        .update_object_name => |name| {
        //            app.updateSelectedObjectName(name) catch |e| {
        //                logError("Failed to update selected object name", e, @errorReturnTrace());
        //            };
        //        },
        //        .delete_from_composition => |id| {
        //            app.deleteFromComposition(id) catch |e| {
        //                logError("Failed to delete item from composition", e, @errorReturnTrace());
        //            };
        //        },
        //        .add_to_composition => |id| {
        //            _ = app.addToComposition(id) catch |e| {
        //                logError("Failed to add item to composition", e, @errorReturnTrace());
        //            };
        //        },
        //        .update_path_display_obj => |id| {
        //            app.updatePathDisplayObj(id) catch |e| {
        //                logError("Failed to set path object", e, @errorReturnTrace());
        //            };
        //        },
        //        .set_shader_binding_value => |params| {
        //            app.setShaderDependency(params.idx, params.val) catch |e| {
        //                logError("Failed to set shader dependency", e, @errorReturnTrace());
        //            };
        //        },
        //        .set_brush_binding_value => |params| {
        //            app.setBrushDependency(params.idx, params.val) catch |e| {
        //                logError("Failed to set shader dependency", e, @errorReturnTrace());
        //            };
        //        },
        //        .set_shader_primary_input => |idx| {
        //            app.setShaderPrimaryInput(idx) catch |e| {
        //                logError("Failed to set primary input", e, @errorReturnTrace());
        //            };
        //        },
        //        .update_drawing_display_obj => |id| {
        //            app.updateDrawingDisplayObj(id) catch |e| {
        //                logError("Failed to set drawing object", e, @errorReturnTrace());
        //            };
        //        },
        //        .set_brush => |id| {
        //            app.setDrawingObjectBrush(id) catch |e| {
        //                logError("Failed to set drawing object", e, @errorReturnTrace());
        //            };
        //        },
        //        .delete_selected => {
        //            app.deleteSelectedObject() catch |e| {
        //                logError("Failed to delete selected object", e, @errorReturnTrace());
        //            };
        //        },
        //        .update_dims => |d| {
        //            app.updateSelectedDims(d) catch |e| {
        //                logError("Failed to update selected object dimensions", e, @errorReturnTrace());
        //            };
        //        },
        //        .update_text_content => |text| {
        //            app.updateTextObjectContent(text) catch |e| {
        //                logError("Failed to update text object content", e, @errorReturnTrace());
        //            };
        //        },
        //        .update_font => |id| {
        //            app.updateFontId(id) catch |e| {
        //                logError("Failed to update font", e, @errorReturnTrace());
        //            };
        //        },
        //        .update_font_size => |s| {
        //            app.updateFontSize(s) catch |e| {
        //                logError("Failed to update font scale", e, @errorReturnTrace());
        //            };
        //        },
        //    }
        //}

        //if (try Imgui.renderAddObjectView(app.shaders)) |action| {
        //    switch (action) {
        //        .shader_object => |id| {
        //            // FIXME: Sane size
        //            _ = try app.addShaderObject("new shader", id);
        //        },
        //        .create_path => {
        //            _ = try app.createPath();
        //        },
        //        .create_composition => {
        //            _ = try app.addComposition();
        //        },
        //        .create_drawing => {
        //            _ = try app.addDrawing();
        //        },
        //        .create_text => {
        //            _ = app.addText() catch |e| {
        //                logError("Failed to create text object", e, @errorReturnTrace());
        //            };
        //        },
        //    }
        //}

        const window_size = gui.PixelSize {
            .width = @intCast(width),
            .height = @intCast(height),
        };

        const window_bounds = gui.PixelBBox {
            .left = 0,
            .top = 0,
            .right = window_size.width,
            .bottom = window_size.height,
        };
        if (try default_gui.step(window_bounds, window_size, &glfw.queue)) |action| {
            switch (action) {
                .update_selected_object => |id| {
                    app.setSelectedObject(id);
                    try regenerateSpecificObjectProperties(&app, default_gui, specific_object_properties, sidebar_width);
                },
                .create_path => {
                    _ = app.createPath() catch |e| {
                        logError("failed to create path", e, @errorReturnTrace());
                    };
                },
                .create_composition => {
                    _ = app.addComposition() catch |e| {
                        logError("failed to create composition", e, @errorReturnTrace());
                    };
                },
                .create_drawing => {
                    _ = app.addDrawing() catch |e| {
                        logError("failed to create drawing", e, @errorReturnTrace());
                    };

                },
                .create_text => {
                    _ = app.addText() catch |e| {
                        logError("failed to create text", e, @errorReturnTrace());
                    };
                },
                .create_shader => |id| {
                    _ = app.addShaderObject("new shader", id) catch |e| {
                        logError("failed to create shader", e, @errorReturnTrace());
                    };
                },
                .delete_selected_object => {
                    app.deleteSelectedObject() catch |e| {
                        logError("failed to delete object", e, @errorReturnTrace());
                    };

                },
                .edit_selected_object_name => |params| {
                    const name = app.objects.get(app.input_state.selected_object).name;
                    var edit_name = std.ArrayListUnmanaged(u8){};
                    defer edit_name.deinit(alloc);

                    // FIXME: Should we crash on failure?
                    try edit_name.appendSlice(alloc, name);
                    try gui.textbox.executeTextEditOnArrayList(alloc, &edit_name, params.pos, params.notifier, params.items);

                    try app.updateSelectedObjectName(try edit_name.toOwnedSlice(alloc));
                },
                .update_composition_width => |new_width| {
                    app.updateSelectedWidth(new_width) catch |e| {
                        logError("Failed to update selected object width", e, @errorReturnTrace());
                    };
                },
                .update_composition_height => |new_height| {
                    app.updateSelectedHeight(new_height) catch |e| {
                        logError("Failed to update selected object width", e, @errorReturnTrace());
                    };
                },
            }
        }

        glfw.swapBuffers();
    }
}
