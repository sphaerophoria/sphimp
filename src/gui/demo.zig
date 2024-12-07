const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const gl = sphrender.gl;
const sphtext = @import("sphtext");
const TextRenderer = sphtext.TextRenderer;
const ttf_mod = sphtext.ttf;
const sphmath = @import("sphmath");
const gui = @import("gui.zig");
const SquircleRenderer = @import("SquircleRenderer.zig");
const DragFloatStyle = gui.drag_float.DragFloatStyle;
const SharedButtonState = gui.button.SharedButtonState;
const ButtonStyle = gui.button.ButtonStyle;
const Button = gui.button.Button;
const Label = gui.label.Label;
const SharedLabelState = gui.label.SharedLabelState;
const Widget = gui.Widget;
const InputState = gui.InputState;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const WindowAction = gui.WindowAction;
const Color = gui.Color;
const Layout = gui.layout.Layout;

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
    glfw.queue.writeItem(.{
        .key_down = .{
            .key = key,
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

const App = struct {
    button_state: [2]bool = .{ true, false },
    adjustable_float: [2]f32 = .{ 1.0, 1.0 },
    counter: i64 = 0,
};

const UiAction = union(enum) {
    change_color: usize,
    change_float: struct {
        idx: usize,
        val: f32,
    },
    increment_counter,
    decrement_counter,
    none,
};

const GlobalStyle = struct {
    const default_color = Color{ .r = 0.3, .g = 0.2, .b = 0.3, .a = 1.0 };
    const hover_color = Color{ .r = 0.6, .g = 0.4, .b = 0.6, .a = 1.0 };
    const click_color = Color{ .r = 0.6, .g = 0.2, .b = 0.6, .a = 1.0 };
};

const AppGetAdjustableFloat = struct {
    app: *App,
    idx: usize,

    pub fn getVal(self: AppGetAdjustableFloat) f32 {
        return self.app.adjustable_float[self.idx];
    }
};

const AppDragGenerator = struct {
    idx: usize,

    pub fn generate(self: AppDragGenerator, val: f32) UiAction {
        return .{ .change_float = .{ .idx = self.idx, .val = val } };
    }
};

const CounterText = struct {
    app: *App,
    buf: [25]u8 = undefined,

    pub fn getText(self: *CounterText) []const u8 {
        return std.fmt.bufPrint(&self.buf, "Pressed {d} times", .{self.app.counter}) catch return "Pressed <unknown> times";
    }
};

const AppButtonTextGenerator = struct {
    app: *App,
    idx: usize,

    pub fn getText(self: AppButtonTextGenerator) []const u8 {
        return if (self.app.button_state[self.idx]) "on" else "off";
    }
};

const AppLayoutGenerator = struct {
    shared_label_state: *const SharedLabelState,
    drag_style: *const DragFloatStyle,
    shared_button_state: *const SharedButtonState,
    squircle_renderer: *const SquircleRenderer,

    fn generateLayoutForApp(self: AppLayoutGenerator, alloc: Allocator, app: *App) !Layout(UiAction) {
        var layout = Layout(UiAction){};
        errdefer layout.deinit(alloc);

        {
            const label = try gui.label.makeLabel(
                UiAction,
                alloc,
                "Hello world",
                self.shared_label_state,
            );
            try layout.pushWidget(alloc, label);
        }

        for (0..app.button_state.len) |idx| {
            const button = try Button(UiAction).init(
                alloc,
                AppButtonTextGenerator{ .app = app, .idx = idx },
                self.shared_button_state,
                .{ .change_color = idx },
            );
            try layout.pushWidget(alloc, button);
        }

        for (0..app.adjustable_float.len) |i| {
            const label = try gui.label.makeLabel(
                UiAction,
                alloc,
                "float value",
                self.shared_label_state,
            );
            try layout.pushWidget(alloc, label);

            const drag_float = try gui.drag_float.makeWidget(
                alloc,
                AppGetAdjustableFloat{ .app = app, .idx = i },
                AppDragGenerator{ .idx = i },
                self.drag_style.*,
                self.shared_label_state,
                self.squircle_renderer,
            );
            try layout.pushWidget(alloc, drag_float);
        }

        {
            const label = try gui.label.makeLabel(
                UiAction,
                alloc,
                CounterText{ .app = app },
                self.shared_label_state,
            );
            try layout.pushWidget(alloc, label);

            const dec = try gui.button.makeButton(
                UiAction,
                alloc,
                "decrement",
                self.shared_button_state,
                .decrement_counter,
            );
            try layout.pushWidget(alloc, dec);

            const inc = try gui.button.makeButton(
                UiAction,
                alloc,
                "increment",
                self.shared_button_state,
                .increment_counter,
            );
            try layout.pushWidget(alloc, inc);
        }
        return layout;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 100,
    }){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    const window_width = 640;
    const window_height = 480;

    var glfw = Glfw{};

    try glfw.initPinned(window_width, window_height);
    defer glfw.deinit();

    gl.glEnable(gl.GL_MULTISAMPLE);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);

    var app = App{};

    var input_state = InputState{};

    const font_size = 12.0;
    var text_renderer = try TextRenderer.init(alloc, font_size);
    defer text_renderer.deinit(alloc);

    const distance_field_renderer = try sphrender.DistanceFieldGenerator.init();
    defer distance_field_renderer.deinit();

    const font_data = @embedFile("res/Hack-Regular.ttf");
    var ttf = try ttf_mod.Ttf.init(alloc, font_data);
    defer ttf.deinit(alloc);

    const unit: f32 = @floatFromInt(ttf_mod.lineHeightPx(ttf, font_size));

    var shared_label_state = SharedLabelState{
        .text_renderer = &text_renderer,
        .ttf = &ttf,
        .distance_field_generator = &distance_field_renderer,
    };

    const widget_width: u31 = @intFromFloat(unit * 8);
    const button_height: u31 = @intFromFloat(unit * 2);
    const slider_height: u31 = @intFromFloat(unit * 1.3);
    const widget_text_padding: u31 = @intFromFloat(unit / 5);
    const corner_radius: f32 = unit / 5;

    const drag_style = DragFloatStyle{
        .size = .{
            .width = widget_width,
            .height = slider_height,
        },
        .corner_radius = corner_radius,
        .default_color = GlobalStyle.default_color,
        .hover_color = GlobalStyle.hover_color,
        .active_color = GlobalStyle.click_color,
    };

    const squircle_renderer = try SquircleRenderer.init(alloc);
    defer squircle_renderer.deinit(alloc);

    const shared_button_state = SharedButtonState{
        .label_state = &shared_label_state,
        .style = .{
            .default_color = GlobalStyle.default_color,
            .hover_color = GlobalStyle.hover_color,
            .click_color = GlobalStyle.click_color,
            .desired_width = widget_width,
            .desired_height = button_height,
            .corner_radius = corner_radius,
            .padding = widget_text_padding,
        },
        .squircle_renderer = &squircle_renderer,
    };

    const layout_generator = AppLayoutGenerator{
        .shared_label_state = &shared_label_state,
        .drag_style = &drag_style,
        .shared_button_state = &shared_button_state,
        .squircle_renderer = &squircle_renderer,
    };

    var layout = try layout_generator.generateLayoutForApp(alloc, &app);
    defer layout.deinit(alloc);

    while (!glfw.closed()) {
        const width, const height = glfw.getWindowSize();

        gl.glViewport(0, 0, @intCast(width), @intCast(height));
        gl.glClearColor(0.1, 0.1, 0.1, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        try layout.update();

        input_state.update();
        while (glfw.queue.readItem()) |action| {
            input_state.pushInput(action);
        }

        const action = layout.dispatchInput(input_state);
        switch (action) {
            .change_color => |idx| {
                app.button_state[idx] = !app.button_state[idx];
            },
            .change_float => |ev| {
                app.adjustable_float[ev.idx] = ev.val;
            },
            .increment_counter => app.counter += 1,
            .decrement_counter => app.counter -= 1,
            .none => {},
        }

        layout.render(@intCast(width), @intCast(height));

        glfw.swapBuffers();
    }
}
