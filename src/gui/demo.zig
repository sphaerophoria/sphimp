const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const gl = sphrender.gl;
const sphtext = @import("sphtext");
const TextRenderer = sphtext.TextRenderer;
const ttf_mod = sphtext.ttf;
const sphmath = @import("sphmath");
const gui = @import("sphui");
const SquircleRenderer = gui.SquircleRenderer;
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
    hightlight_color: Color = gui.default_gui.GlobalStyle.default_color,
    sample_color: Color = gui.default_gui.GlobalStyle.default_color,
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

fn generateLayoutForApp(gui_gen: *gui.default_gui.DefaultGui(UiAction), window_size: PixelSize, app: *App) !Widget(UiAction) {

    const layout = try gui.layout.Layout(UiAction).init(gui_gen.alloc, gui_gen.layout_pad);
    errdefer layout.deinit(gui_gen.alloc);

    {
        const label = try gui_gen.makeLabel("Hello world", window_size.width);
        try layout.pushOrDeinitWidget(gui_gen.alloc, label);
    }

    for (0..app.button_state.len) |idx| {
        const button = try gui_gen.makeButton(
            AppButtonTextGenerator{ .app = app, .idx = idx },
            .{ .change_button_state = idx },
        );
        try layout.pushOrDeinitWidget(gui_gen.alloc, button);
    }

    const text_input_label = try gui_gen.makeLabel(
        "text input",
        std.math.maxInt(u31),
    );
    try layout.pushOrDeinitWidget(gui_gen.alloc, text_input_label);

    for (0..app.text_input.len) |idx| {
        const text_input = try gui_gen.makeTextbox(
            ArrayListLabelData{ .al = &app.text_input[idx] },
            MakeInsertLetter{ .input_idx = idx },
        );
        try layout.pushOrDeinitWidget(gui_gen.alloc, text_input);
    }

    {
        const add_label = try gui_gen.makeLabel(
            "New label",
            std.math.maxInt(u31),
        );
        try layout.pushOrDeinitWidget(gui_gen.alloc, add_label);

        const NewItemNameAdapter = struct {
            app: *App,

            pub fn getText(adap: @This()) []const u8 {
                return adap.app.new_item_name.items;
            }
        };
        const text_input = try gui_gen.makeTextbox(
            NewItemNameAdapter{ .app = app },
            &UiAction.makeEditNewItemName,
        );
        try layout.pushOrDeinitWidget(gui_gen.alloc, text_input);

        const button = try gui_gen.makeButton(
            "add",
            .commit_new_item,
        );
        try layout.pushOrDeinitWidget(gui_gen.alloc, button);

        const remove_button = try gui_gen.makeButton(
            "remove",
            .remove_selected_item,
        );
        try layout.pushOrDeinitWidget(gui_gen.alloc, remove_button);

        const label = try gui_gen.makeLabel(
            "Select an item",
            std.math.maxInt(u31),
        );
        try layout.pushOrDeinitWidget(gui_gen.alloc, label);

        const selectable_list = try gui_gen.makeSelectableList(
            RetrieveSelectableItems{ .app = app },
            &UiAction.makeSelectItem,
        );
        try layout.pushOrDeinitWidget(gui_gen.alloc, selectable_list);
    }

    {
        const color_label = try gui_gen.makeLabel(
            "Highlight color",
            std.math.maxInt(u31),
        );
        try layout.pushOrDeinitWidget(gui_gen.alloc, color_label);
    }

    {
        const color_popup = try gui_gen.makeColorPicker(
            &app.hightlight_color,
            &UiAction.makeChangeHighlightColor,
        );
        try layout.pushOrDeinitWidget(gui_gen.alloc, color_popup);
    }

    {
        const color_popup = try gui_gen.makeColorPicker(
            &app.sample_color,
            &UiAction.makeChangeSampleColor,
        );
        try layout.pushOrDeinitWidget(gui_gen.alloc, color_popup);
    }

    for (0..app.adjustable_float.len) |i| {
        const label = try gui_gen.makeLabel(
            "float value",
            layout.availableSize(window_size).width,
        );
        try layout.pushOrDeinitWidget(gui_gen.alloc, label);

        const drag_float = try gui_gen.makeDragFloat(
            AppGetAdjustableFloat{ .app = app, .idx = i },
            AppDragGenerator{ .idx = i },
        );
        try layout.pushOrDeinitWidget(gui_gen.alloc, drag_float);
    }

    {
        const label = try gui_gen.makeLabel(
            CounterText{ .app = app },
            layout.availableSize(window_size).width,
        );
        try layout.pushOrDeinitWidget(gui_gen.alloc, label);

        const dec = try gui_gen.makeButton(
            "decrement",
            .decrement_counter,
        );
        try layout.pushOrDeinitWidget(gui_gen.alloc, dec);

        const inc = try gui_gen.makeButton(
            "increment",
            .increment_counter,
        );
        try layout.pushOrDeinitWidget(gui_gen.alloc, inc);
    }

    {
        const label = try gui_gen.makeLabel(
            @embedFile("res/lorem_ipsum.txt"),
            layout.availableSize(window_size).width,
        );
        try layout.pushOrDeinitWidget(gui_gen.alloc, label);
    }

    // FIXME: makeScrollView
    const scroll = try ScrollView(UiAction).init(gui_gen.alloc, layout.asWidget(), &gui_gen.scroll_style, &gui_gen.squircle_renderer);
    return scroll;
}

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

    for (0..5) |i| {
        const item_text = try std.fmt.allocPrint(alloc, "item {d}", .{i});
        errdefer alloc.free(item_text);

        try app.item_list.append(alloc, item_text);
    }

    const gui_gen = try gui.default_gui.defaultGui(UiAction, alloc);
    defer gui_gen.deinit();
    const root_widget = try generateLayoutForApp(gui_gen, .{
        .width = window_width,
        .height = window_height,
    }, &app);

    try gui_gen.setRootWidgetOrDeinit(root_widget);

    while (!glfw.closed()) {
        const width, const height = glfw.getWindowSize();

        gl.glScissor(0, 0, @intCast(width), @intCast(height));
        gl.glViewport(0, 0, @intCast(width), @intCast(height));
        gl.glClearColor(0.1, 0.1, 0.1, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);


        const window_size = PixelSize{
            .width = @intCast(width),
            .height = @intCast(height),
        };
        const window_bbox = PixelBBox {
            .top = 0,
            .left = 0,
            .bottom = window_size.height,
            .right = window_size.width,
        };

        const action_opt = try gui_gen.step(window_bbox, window_size, &glfw.queue);

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
                    const new_hover = gui.default_gui.GlobalStyle.hoverColor(color);
                    const new_active = gui.default_gui.GlobalStyle.activeColor(color);

                    gui_gen.drag_style.default_color = color;
                    gui_gen.drag_style.hover_color = new_hover;
                    gui_gen.drag_style.active_color = new_active;

                    gui_gen.shared_button_state.style.default_color = color;
                    gui_gen.shared_button_state.style.hover_color = new_hover;
                    gui_gen.shared_button_state.style.click_color = new_active;

                    gui_gen.scroll_style.default_color = color;
                    gui_gen.scroll_style.hover_color = new_hover;
                    gui_gen.scroll_style.active_color = new_active;

                    gui_gen.shared_color.style.drag_style.default_color = color;
                    gui_gen.shared_color.style.drag_style.hover_color = new_hover;
                    gui_gen.shared_color.style.drag_style.active_color = new_active;

                    gui_gen.shared_textbox_state.style.background_color = color;

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

        glfw.swapBuffers();
    }
}

// FIXME: duped with textbox
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
