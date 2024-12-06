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
const Widget = gui.Widget;
const InputState = gui.InputState;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const WindowAction = gui.WindowAction;
const Color = gui.Color;
const Layout = gui.layout.Layout;
const ScrollView = gui.scroll_view.ScrollView;

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

const App = struct {
    button_state: [2]bool = .{ true, false },
    adjustable_float: [2]f32 = .{ 1.0, 1.0 },
    counter: i64 = 0,
    hightlight_color: Color = GlobalStyle.default_color,
    sample_color: Color = GlobalStyle.default_color,
    text_input: [5]std.ArrayListUnmanaged(u8) = .{.{}} ** 5,
    item_list: std.ArrayListUnmanaged([]const u8) = .{},
    selected_item: usize = 0,
    new_item_name: std.ArrayListUnmanaged(u8) = .{},

    fn deinit(self: *App, alloc: Allocator) void {
        for (&self.text_input) |*input| {
            input.deinit(alloc);
        }
        for (self.item_list.items) |item| {
            alloc.free(item);
        }
        self.item_list.deinit(alloc);
    }
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
    change_sample_color: Color,
    append_letter: struct {
        notifier: gui.textbox.TextboxNotifier,
        input_idx: usize,
        insert_idx: usize,
        text: []const gui.KeyEvent,
    },
    select_item: usize,
    edit_new_item_name: struct {
        notifier: gui.textbox.TextboxNotifier,
        insert_idx: usize,
        text: []const gui.KeyEvent,
    },
    commit_new_item,
    remove_selected_item,

    fn makeSelectItem(idx: usize) UiAction {
        return .{
            .select_item = idx,
        };
    }

    fn makeEditNewItemName(notifier: gui.textbox.TextboxNotifier, insert_idx: usize, events: []const gui.KeyEvent) UiAction {
        return .{
            .edit_new_item_name = .{
                .notifier = notifier,
                .insert_idx = insert_idx,
                .text = events,
            },
        };
    }

    fn makeChangeHighlightColor(color: Color) UiAction {
        return .{ .change_highlight_color = color };
    }

    fn makeChangeSampleColor(color: Color) UiAction {
        return .{ .change_sample_color = color };
    }
};

const MakeInsertLetter = struct {
    input_idx: usize,

    pub fn generate(self: MakeInsertLetter, notifier: gui.textbox.TextboxNotifier, insert_idx: usize, events: []const gui.KeyEvent) UiAction {
        return .{
            .append_letter = .{
                .notifier = notifier,
                .input_idx = self.input_idx,
                .insert_idx = insert_idx,
                .text = events,
            },
        };
    }
};

const GlobalStyle = struct {
    const default_color = Color{ .r = 0.38, .g = 0.35, .b = 0.44, .a = 1.0 };
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

const ArrayListLabelData = struct {
    al: *std.ArrayListUnmanaged(u8),

    pub fn getText(self: ArrayListLabelData) []const u8 {
        return self.al.items;
    }
};

const RetrieveSelectableItems = struct {
    app: *const App,

    pub fn numItems(self: @This()) usize {
        return self.app.item_list.items.len;
    }

    pub fn getText(self: RetrieveSelectableItems, idx: usize) []const u8 {
        return self.app.item_list.items[idx];
    }

    pub fn selectedId(self: RetrieveSelectableItems) usize {
        return self.app.selected_item;
    }
};

const AppLayoutGenerator = struct {
    guitext_state: *const gui.gui_text.SharedState,
    drag_style: *const DragFloatStyle,
    shared_button_state: *const SharedButtonState,
    squircle_renderer: *const SquircleRenderer,
    scroll_style: *const gui.scrollbar.Style,
    shared_color: *const gui.color_picker.SharedColorPickerState,
    shared_textbox_state: *const gui.textbox.SharedTextboxState,
    shared_selecatble_list_state: *const gui.selectable_list.SharedState,
    overlay: *gui.popup_layer.PopupLayer(UiAction),
    layout_item_pad: u31,

    fn generateLayoutForApp(self: AppLayoutGenerator, alloc: Allocator, window_size: PixelSize, app: *App) !Widget(UiAction) {
        var layout = try Layout(UiAction).init(alloc, self.layout_item_pad);
        errdefer layout.deinit(alloc);

        {
            const label = try gui.label.makeLabel(
                UiAction,
                alloc,
                "Hello world",
                layout.availableSize(window_size).width,
                self.guitext_state,
            );
            try layout.pushOrDeinitWidget(alloc, label);
        }

        for (0..app.button_state.len) |idx| {
            const button = try Button(UiAction).init(
                alloc,
                AppButtonTextGenerator{ .app = app, .idx = idx },
                self.shared_button_state,
                .{ .change_button_state = idx },
            );
            try layout.pushOrDeinitWidget(alloc, button);
        }

        const text_input_label = try gui.label.makeLabel(
            UiAction,
            alloc,
            "text input",
            std.math.maxInt(u31),
            self.guitext_state,
        );
        try layout.pushOrDeinitWidget(alloc, text_input_label);

        for (0..app.text_input.len) |idx| {
            const text_input = try gui.textbox.makeTextbox(
                UiAction,
                alloc,
                ArrayListLabelData{ .al = &app.text_input[idx] },
                MakeInsertLetter{ .input_idx = idx },
                self.shared_textbox_state,
            );
            try layout.pushOrDeinitWidget(alloc, text_input);
        }

        {
            const add_label = try gui.label.makeLabel(
                UiAction,
                alloc,
                "New label",
                std.math.maxInt(u31),
                self.guitext_state,
            );
            try layout.pushOrDeinitWidget(alloc, add_label);

            const NewItemNameAdapter = struct {
                app: *App,

                pub fn getText(adap: @This()) []const u8 {
                    return adap.app.new_item_name.items;
                }
            };
            const text_input = try gui.textbox.makeTextbox(
                UiAction,
                alloc,
                NewItemNameAdapter{ .app = app },
                &UiAction.makeEditNewItemName,
                self.shared_textbox_state,
            );
            try layout.pushOrDeinitWidget(alloc, text_input);

            const button = try gui.button.makeButton(
                UiAction,
                alloc,
                "add",
                self.shared_button_state,
                .commit_new_item,
            );
            try layout.pushOrDeinitWidget(alloc, button);

            const remove_button = try gui.button.makeButton(
                UiAction,
                alloc,
                "remove",
                self.shared_button_state,
                .remove_selected_item,
            );
            try layout.pushOrDeinitWidget(alloc, remove_button);

            const label = try gui.label.makeLabel(
                UiAction,
                alloc,
                "Select an item",
                std.math.maxInt(u31),
                self.guitext_state,
            );
            try layout.pushOrDeinitWidget(alloc, label);

            const selectable_list = try gui.selectable_list.selectableList(
                UiAction,
                alloc,
                RetrieveSelectableItems{ .app = app },
                &UiAction.makeSelectItem,
                self.shared_selecatble_list_state,
            );
            try layout.pushOrDeinitWidget(alloc, selectable_list);
        }

        {
            const color_label = try gui.label.makeLabel(
                UiAction,
                alloc,
                "Highlight color",
                std.math.maxInt(u31),
                self.guitext_state,
            );
            try layout.pushOrDeinitWidget(alloc, color_label);
        }

        {
            const color_popup = try gui.color_picker.makeColorPicker(
                UiAction,
                alloc,
                &app.hightlight_color,
                &UiAction.makeChangeHighlightColor,
                self.shared_color,
                self.overlay,
            );
            try layout.pushOrDeinitWidget(alloc, color_popup);
        }

        {
            const color_popup = try gui.color_picker.makeColorPicker(
                UiAction,
                alloc,
                &app.sample_color,
                &UiAction.makeChangeSampleColor,
                self.shared_color,
                self.overlay,
            );
            try layout.pushOrDeinitWidget(alloc, color_popup);
        }

        for (0..app.adjustable_float.len) |i| {
            const label = try gui.label.makeLabel(
                UiAction,
                alloc,
                "float value",
                layout.availableSize(window_size).width,
                self.guitext_state,
            );
            try layout.pushOrDeinitWidget(alloc, label);

            const drag_float = try gui.drag_float.makeWidget(
                UiAction,
                alloc,
                AppGetAdjustableFloat{ .app = app, .idx = i },
                AppDragGenerator{ .idx = i },
                self.drag_style,
                self.guitext_state,
                self.squircle_renderer,
            );
            try layout.pushOrDeinitWidget(alloc, drag_float);
        }

        {
            const label = try gui.label.makeLabel(
                UiAction,
                alloc,
                CounterText{ .app = app },
                layout.availableSize(window_size).width,
                self.guitext_state,
            );
            try layout.pushOrDeinitWidget(alloc, label);

            const dec = try gui.button.makeButton(
                UiAction,
                alloc,
                "decrement",
                self.shared_button_state,
                .decrement_counter,
            );
            try layout.pushOrDeinitWidget(alloc, dec);

            const inc = try gui.button.makeButton(
                UiAction,
                alloc,
                "increment",
                self.shared_button_state,
                .increment_counter,
            );
            try layout.pushOrDeinitWidget(alloc, inc);
        }

        {
            const label = try gui.label.makeLabel(
                UiAction,
                alloc,
                @embedFile("res/lorem_ipsum.txt"),
                layout.availableSize(window_size).width,
                self.guitext_state,
            );
            try layout.pushOrDeinitWidget(alloc, label);
        }

        return try ScrollView(UiAction).init(alloc, layout.asWidget(), self.scroll_style, self.squircle_renderer);
    }
};

fn getInputAction(layout: Widget(UiAction), overlay: Widget(UiAction), input_state: InputState, layout_bounds: PixelBBox) ?UiAction {
    if (overlay.getSize().width != 0) {
        const input_response = overlay.setInputState(layout_bounds, input_state);
        return input_response.action;
    }

    return layout.setInputState(layout_bounds, input_state).action;
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
    gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);

    var app = App{};
    defer app.deinit(alloc);

    var input_state = InputState{};
    defer input_state.deinit(alloc);

    for (0..5) |i| {
        const item_text = try std.fmt.allocPrint(alloc, "item {d}", .{i});
        errdefer alloc.free(item_text);

        try app.item_list.append(alloc, item_text);
    }

    const font_size = 11.0;
    var text_renderer = try TextRenderer.init(alloc, font_size);
    defer text_renderer.deinit(alloc);

    const distance_field_renderer = try sphrender.DistanceFieldGenerator.init();
    defer distance_field_renderer.deinit();

    const font_data = @embedFile("res/Hack-Regular.ttf");
    var ttf = try ttf_mod.Ttf.init(alloc, font_data);
    defer ttf.deinit(alloc);

    const unit: f32 = @floatFromInt(ttf_mod.lineHeightPx(ttf, font_size));

    const widget_width: u31 = @intFromFloat(unit * 8);
    const button_height: u31 = @intFromFloat(unit * 2);
    const text_wrapped_height: u31 = @intFromFloat(unit * 1.3);
    const widget_text_padding: u31 = @intFromFloat(unit / 5);
    const corner_radius: f32 = unit / 5;

    var drag_style = DragFloatStyle{
        .size = .{
            .width = widget_width,
            .height = text_wrapped_height,
        },
        .corner_radius = corner_radius,
        .default_color = GlobalStyle.default_color,
        .hover_color = GlobalStyle.hover_color,
        .active_color = GlobalStyle.active_color,
    };

    const squircle_renderer = try SquircleRenderer.init(alloc);
    defer squircle_renderer.deinit(alloc);

    var guitext_shared = gui.gui_text.SharedState{
        .ttf = &ttf,
        .text_renderer = &text_renderer,
        .distance_field_generator = &distance_field_renderer,
    };

    var shared_button_state = SharedButtonState{
        .text_shared = &guitext_shared,
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
            .preview_width = widget_width,
            .popup_width = widget_width,
            .popup_background = GlobalStyle.background_color2,
            .color_preview_height = text_wrapped_height,
            .item_pad = widget_text_padding,
            .corner_radius = corner_radius,
            .drag_style = drag_style,
        },
        &guitext_shared,
        &squircle_renderer,
    );
    defer color_picker_state.deinit(alloc);
    var textbox_state = gui.textbox.SharedTextboxState{
        .squircle_renderer = &squircle_renderer,
        .guitext_shared = &guitext_shared,
        .style = .{
            .cursor_width = @intFromFloat(unit * 0.1),
            .cursor_height = @intFromFloat(unit * 0.9),
            .corner_radius = corner_radius,
            .cursor_color = Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
            .label_pad = widget_text_padding,
            .background_color = GlobalStyle.default_color,
            .size = .{
                .width = widget_width,
                .height = text_wrapped_height,
            },
        },
    };

    var selectable_list_state = gui.selectable_list.SharedState{
        .gui_state = &guitext_shared,
        .squircle_renderer = &squircle_renderer,
        .style = .{
            .highlight_color = GlobalStyle.default_color,
            .hover_color = GlobalStyle.hover_color,
            .active_color = GlobalStyle.active_color,
            .background_color = GlobalStyle.background_color2,
            .corner_radius = corner_radius,
            .item_pad = widget_text_padding,
            .width = widget_width,
            .min_item_height = @intFromFloat(unit),
        },
    };

    var root_stack = try gui.stack.Stack(UiAction).init(alloc);
    defer root_stack.deinit(alloc);

    var overlay = gui.popup_layer.PopupLayer(UiAction){};
    // FIXME: Leak if it's pushed into the root stack too late

    const root_stack_widget = root_stack.toWidget();

    const layout_generator = AppLayoutGenerator{ .guitext_state = &guitext_shared, .drag_style = &drag_style, .shared_button_state = &shared_button_state, .scroll_style = &scroll_style, .squircle_renderer = &squircle_renderer, .layout_item_pad = @intFromFloat(unit / 2.0), .shared_color = &color_picker_state, .overlay = &overlay, .shared_textbox_state = &textbox_state, .shared_selecatble_list_state = &selectable_list_state };

    const layout = try layout_generator.generateLayoutForApp(alloc, .{
        .width = window_width,
        .height = window_height,
    }, &app);
    try root_stack.pushWidgetOrDeinit(alloc, layout, .{ .offset = .{ .x_offs = 0, .y_offs = 0 } });
    try root_stack.pushWidgetOrDeinit(alloc, overlay.asWidget(), .{ .offset = .{ .x_offs = 0, .y_offs = 0 } });

    while (!glfw.closed()) {
        const width, const height = glfw.getWindowSize();

        gl.glScissor(0, 0, @intCast(width), @intCast(height));
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

        try root_stack_widget.update(window_size);

        input_state.startFrame();
        while (glfw.queue.readItem()) |action| {
            try input_state.pushInput(alloc, action);
        }

        const input_response = root_stack_widget.setInputState(window_bounds, input_state);
        root_stack_widget.setFocused(input_response.wants_focus);

        if (input_response.action) |action| {
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

                    textbox_state.style.background_color = color;

                    app.hightlight_color = color;
                },
                .change_sample_color => |color| {
                    app.sample_color = color;
                },
                .select_item => |item| {
                    app.selected_item = item;
                },
                .append_letter => |v| {
                    const text_input = &app.text_input[v.input_idx];
                    try editText(alloc, text_input, v.insert_idx, v.notifier, v.text);
                },
                .edit_new_item_name => |v| {
                    try editText(alloc, &app.new_item_name, v.insert_idx, v.notifier, v.text);
                },
                .commit_new_item => {
                    const new_item_name = try app.new_item_name.toOwnedSlice(alloc);
                    errdefer alloc.free(new_item_name);
                    try app.item_list.append(alloc, new_item_name);
                },
                .remove_selected_item => {
                    if (app.item_list.items.len > app.selected_item) {
                        const item = app.item_list.orderedRemove(app.selected_item);
                        alloc.free(item);
                        app.selected_item = @min(app.item_list.items.len -| 1, app.selected_item);
                    }
                },
            }
        }

        root_stack_widget.render(window_bounds, window_bounds);

        glfw.swapBuffers();
    }
}

fn editText(alloc: Allocator, text_input: *std.ArrayListUnmanaged(u8), insert_idx: usize, notifier: gui.textbox.TextboxNotifier, events: []const gui.KeyEvent) !void {
    var num_inserted: isize = 0;

    for (events) |ev| {
        const fixed_insert_idx: usize =
            // FIXME: Cast hell
            @intCast(std.math.clamp(@as(isize, @intCast(insert_idx)) + num_inserted, 0, @as(isize, @intCast(text_input.items.len))));

        switch (ev.key) {
            .ascii => |char| {
                try text_input.insert(alloc, fixed_insert_idx, char);
                num_inserted += 1;
                try notifier.notify(.{ .insert_char = fixed_insert_idx });
            },
            .backspace => {
                if (fixed_insert_idx > 0) {
                    const delete_idx = fixed_insert_idx - 1;
                    if (delete_idx < text_input.items.len) {
                        _ = text_input.orderedRemove(delete_idx);
                        num_inserted -= 1;
                        try notifier.notify(.{ .delete_char = delete_idx });
                    }
                }
            },
            .delete => {
                const delete_idx = fixed_insert_idx;
                if (delete_idx < text_input.items.len) {
                    _ = text_input.orderedRemove(delete_idx);
                    num_inserted -= 1;
                    try notifier.notify(.{ .delete_char = delete_idx });
                }
            },
            else => {},
        }
    }
}
