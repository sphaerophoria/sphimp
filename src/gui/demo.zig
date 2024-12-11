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
const LayoutStyle = gui.layout.LayoutStyle;
const ScrollView = gui.layout.ScrollView;

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
    hightlight_color: Color = GlobalStyle.default_color,
};

const UiAction = union(enum) {
    change_button_state: usize,
    change_float: struct {
        idx: usize,
        val: f32,
    },
    increment_counter,
    decrement_counter,
    change_highlight_color: Color,
    popup_overlay,
    close_overlay,

    fn makeChangeHighlightColor(color: Color) UiAction {
        return .{ .change_highlight_color = color };
    }
};

const GlobalStyle = struct {
    const default_color = Color{ .r = 0.75, .g = 0.43, .b = 0.6, .a = 1.0 };
    const hover_color = hoverColor(default_color);
    const active_color = activeColor(default_color);
    const background_color = Color{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1.0 };
    const background_color2 = Color{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 };

    fn hoverColor(default: Color) Color {
        return .{
            .r = default.r * 3.0 / 2.0,
            .g = default.g * 3.0 / 2.0,
            .b = default.b * 3.0 / 2.0,
            .a = default.a,
        };
    }

    fn activeColor(default: Color) Color {
        // FIXME: Make more saturated
        return .{
            .r = default.r * 4.0 / 2.0,
            .g = default.g * 4.0 / 2.0,
            .b = default.b * 4.0 / 2.0,
            .a = default.a,
        };
    }
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
    scroll_style: *const gui.scrollbar.Style,
    shared_color: *const gui.color_picker.SharedColorPickerState,
    overlay: *gui.positional_renderer.PositionalRenderer(UiAction),
    layout_item_pad: u31,

    fn generateLayoutForApp(self: AppLayoutGenerator, alloc: Allocator, window_size: PixelSize, app: *App) !ScrollView(UiAction) {
        var layout = Layout(UiAction){
            .item_pad = self.layout_item_pad,
        };

        errdefer layout.deinit(alloc, .full);

        {
            const label = try gui.label.makeLabel(
                UiAction,
                alloc,
                "Hello world",
                layout.availableSize(window_size).width,
                self.shared_label_state,
            );
            // FIXME: leaks
            try layout.pushWidget(alloc, label);
        }

        for (0..app.button_state.len) |idx| {
            const button = try Button(UiAction).init(
                alloc,
                AppButtonTextGenerator{ .app = app, .idx = idx },
                self.shared_button_state,
                .{ .change_button_state = idx },
            );
            try layout.pushWidget(alloc, button);
        }

        {
            const button = try Button(UiAction).init(
                alloc,
                "popup overlay",
                self.shared_button_state,
                .popup_overlay,
            );
            try layout.pushWidget(alloc, button);
        }

        {
            const color_label = try gui.label.makeLabel(
                UiAction,
                alloc,
                "Highlight color",
                std.math.maxInt(u31),
                self.shared_label_state,
            );
            errdefer color_label.deinit(alloc);
            try layout.pushWidget(alloc, color_label);
        }

        {
            const color_popup = try gui.color_picker.makeColorPreview2(
                UiAction,
                alloc,
                &app.hightlight_color,
                &UiAction.makeChangeHighlightColor,
                self.shared_color,
                self.overlay,
            );
            try layout.pushWidget(alloc, color_popup);
        }

        for (0..app.adjustable_float.len) |i| {
            const label = try gui.label.makeLabel(
                UiAction,
                alloc,
                "float value",
                layout.availableSize(window_size).width,
                self.shared_label_state,
            );
            try layout.pushWidget(alloc, label);

            const drag_float = try gui.drag_float.makeWidget(
                UiAction,
                alloc,
                AppGetAdjustableFloat{ .app = app, .idx = i },
                AppDragGenerator{ .idx = i },
                self.drag_style,
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
                layout.availableSize(window_size).width,
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

        {
            //const color_picker = try gui.color_picker.makeColorPicker(
            //    UiAction,
            //    alloc,
            //    &app.hightlight_color,
            //    &UiAction.makeChangeHighlightColor,
            //    self.shared_color,
            //    self.overlay,
            //);
            //try layout.pushWidget(alloc, color_picker);
        }

        {
            const label = try gui.label.makeLabel(
                UiAction,
                alloc,
                @embedFile("res/lorem_ipsum.txt"),
                layout.availableSize(window_size).width,
                self.shared_label_state,
            );
            try layout.pushWidget(alloc, label);
        }

        return ScrollView(UiAction).init(layout, self.scroll_style, self.squircle_renderer);
    }
};

fn getInputAction(layout: *ScrollView(UiAction), overlay: *gui.positional_renderer.PositionalRenderer(UiAction), input_state: InputState, layout_bounds: PixelBBox) ?UiAction {
    if (overlay.dispatchInput(input_state)) |input_res| {
        if (input_res.consumed) {
            return input_res.action;
        }
    }

    return layout.dispatchInput(input_state, layout_bounds);
}

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

    const font_size = 11.0;
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

    var drag_style = DragFloatStyle{
        .size = .{
            .width = widget_width,
            .height = slider_height,
        },
        .corner_radius = corner_radius,
        .default_color = GlobalStyle.default_color,
        .hover_color = GlobalStyle.hover_color,
        .active_color = GlobalStyle.active_color,
    };

    const squircle_renderer = try SquircleRenderer.init(alloc);
    defer squircle_renderer.deinit(alloc);

    var shared_button_state = SharedButtonState{
        .label_state = &shared_label_state,
        .style = .{
            .default_color = GlobalStyle.default_color,
            .hover_color = GlobalStyle.hover_color,
            .click_color = GlobalStyle.active_color,
            .desired_width = widget_width,
            .desired_height = button_height,
            .corner_radius = corner_radius,
            .padding = widget_text_padding,
        },
        .squircle_renderer = &squircle_renderer,
    };

    var scroll_style = gui.scrollbar.Style{
        .default_color = GlobalStyle.default_color,
        .hover_color = GlobalStyle.hover_color,
        .active_color = GlobalStyle.active_color,
        .gutter_color = GlobalStyle.background_color2,
        .corner_radius = corner_radius,
        .width = @intFromFloat(unit * 0.75),
    };

    var color_picker_state = try gui.color_picker.SharedColorPickerState.init(
        alloc,
        gui.color_picker.ColorStyle{
            .width = widget_width,
            .popup_background = GlobalStyle.background_color2,
            .color_preview_height = slider_height,
            .item_pad = widget_text_padding,
            .corner_radius = corner_radius,
            .drag_style = drag_style,
        },
        &shared_label_state,
        &squircle_renderer,
    );
    defer color_picker_state.deinit(alloc);

    var overlay = gui.positional_renderer.PositionalRenderer(UiAction){};
    defer overlay.deinit(alloc);

    const layout_generator = AppLayoutGenerator{
        .shared_label_state = &shared_label_state,
        .drag_style = &drag_style,
        .shared_button_state = &shared_button_state,
        .scroll_style = &scroll_style,
        .squircle_renderer = &squircle_renderer,
        .layout_item_pad = @intFromFloat(unit / 2.0),
        .shared_color = &color_picker_state,
        .overlay = &overlay,
    };

    var layout = try layout_generator.generateLayoutForApp(alloc, .{
        .width = window_width,
        .height = window_height,
    }, &app);
    defer layout.deinit(alloc);

    var overlay_content = Layout(UiAction){ .item_pad = widget_text_padding };
    defer overlay_content.deinit(alloc, .full);

    {
        const overlay_label = try gui.label.makeLabel(
            UiAction,
            alloc,
            "hello overlay",
            std.math.maxInt(u31),
            &shared_label_state,
        );
        errdefer overlay_label.deinit(alloc);

        try overlay_content.pushWidget(alloc, overlay_label);
    }
    {
        const close_button = try gui.button.makeButton(
            UiAction,
            alloc,
            "close",
            &shared_button_state,
            .close_overlay,
        );
        errdefer close_button.deinit(alloc);

        try overlay_content.pushWidget(alloc, close_button);
    }

    const overlay_size: PixelSize = overlay_content.contentSize();
    const overlay_background = try gui.rect.Rect(UiAction).init(alloc, overlay_size, .{ .r = 1.0, .g = 0.0, .b = 0.0, .a = 1.0 }, &squircle_renderer);

    const overlay_content_widget = try overlay_content.toWidget(alloc);

    while (!glfw.closed()) {
        const width, const height = glfw.getWindowSize();

        gl.glViewport(0, 0, @intCast(width), @intCast(height));
        gl.glClearColor(0.1, 0.1, 0.1, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        const window_bounds = PixelBBox{
            .top = 0,
            .bottom = @intCast(height),
            .left = 0,
            .right = @intCast(width),
        };

        const window_size = PixelSize{
            .width = window_bounds.calcWidth(),
            .height = window_bounds.calcHeight(),
        };

        try layout.update(window_size);

        input_state.startFrame();
        while (glfw.queue.readItem()) |action| {
            input_state.pushInput(action);
        }

        const action_opt = getInputAction(&layout, &overlay, input_state, window_bounds);
        if (action_opt) |action| {
            switch (action) {
                .change_button_state => |idx| {
                    app.button_state[idx] = !app.button_state[idx];
                },
                .change_float => |ev| {
                    app.adjustable_float[ev.idx] = ev.val;
                },
                .increment_counter => app.counter += 1,
                .decrement_counter => app.counter -= 1,
                .change_highlight_color => |color| {
                    const new_hover = GlobalStyle.hoverColor(color);
                    const new_active = GlobalStyle.activeColor(color);

                    drag_style.default_color = color;
                    drag_style.hover_color = new_hover;
                    drag_style.active_color = new_active;

                    shared_button_state.style.default_color = color;
                    shared_button_state.style.hover_color = new_hover;
                    shared_button_state.style.click_color = new_active;

                    scroll_style.default_color = color;
                    scroll_style.hover_color = new_hover;
                    scroll_style.active_color = new_active;

                    color_picker_state.style.drag_style.default_color = color;
                    color_picker_state.style.drag_style.hover_color = new_hover;
                    color_picker_state.style.drag_style.active_color = new_active;

                    app.hightlight_color = color;
                },
                .popup_overlay => {
                    const rect_bbox = PixelBBox{
                        .left = 0,
                        .top = 0,
                        .right = overlay_size.width + 10,
                        .bottom = overlay_size.height + 10,
                    };
                    const content_bbox = PixelBBox{
                        .left = 5,
                        .top = 5,
                        .right = overlay_size.width + 10,
                        .bottom = overlay_size.height + 10,
                    };
                    try overlay.pushWidget(alloc, overlay_background, rect_bbox);
                    try overlay.pushWidget(alloc, overlay_content_widget, content_bbox);
                },
                .close_overlay => {
                    overlay.reset();
                },
            }
        }

        layout.render(window_bounds, window_bounds);

        overlay.render(window_bounds);

        glfw.swapBuffers();
    }
}
