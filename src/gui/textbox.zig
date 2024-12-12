const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const util = @import("util.zig");
const Widget = gui.Widget;
const Rect = gui.rect.Rect;
const Stack = gui.stack.Stack;
const SharedLabelState = gui.label.SharedLabelState;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const SquircleRenderer = @import("SquircleRenderer.zig");

pub const TextboxStyle = struct {
    background_color: gui.Color,
    // FIXME: remove
    focus_color: gui.Color,
    size: gui.PixelSize,
    label_pad: u31,
};

pub const SharedTextboxState = struct {
    label_state: *const SharedLabelState,
    squircle_renderer: *const SquircleRenderer,
    style: TextboxStyle,
};

fn Textbox(comptime ActionType: type, comptime TextAction: type) type {
    return struct {
        label: Widget(ActionType),
        shared: *const SharedTextboxState,
        text_action: TextAction,
        focused: bool = false,

        const Self = @This();

        const widget_vtable = Widget(ActionType).VTable{
            .deinit = Self.deinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
        };

        fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.label.deinit(alloc);
            alloc.destroy(self);
        }

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const transform = util.widgetToClipTransform(widget_bounds, window_bounds);
            self.shared.squircle_renderer.render(
                self.shared.style.background_color,
                0.0,
                widget_bounds,
                transform,
            );
            const rect_size = self.shared.style.size;
            const label_size = self.label.getSize();
            const y_offs = @divTrunc(rect_size.height -| label_size.height, 2);
            const x_offs = self.shared.style.label_pad;
            const left = widget_bounds.left + x_offs;
            const top = widget_bounds.top + y_offs;
            const label_bounds = PixelBBox{
                .left = left,
                .top = top,
                .right = left + label_size.width,
                .bottom = top + label_size.height,
            };
            self.label.render(label_bounds, window_bounds);

            if (self.focused) {
                const cursor_left = label_bounds.right + self.shared.style.label_pad;
                // FIXME: style
                const cursor_width = 2;
                const cursor_bounds = PixelBBox{
                    .left = cursor_left,
                    .right = cursor_left + cursor_width,
                    .top = widget_bounds.top + 2,
                    .bottom = widget_bounds.bottom - 2,
                };
                const cursor_transform = util.widgetToClipTransform(cursor_bounds, window_bounds);
                //FIXME: style
                const cursor_color = gui.Color{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 };
                self.shared.squircle_renderer.render(
                    cursor_color,
                    0.0,
                    cursor_bounds,
                    cursor_transform,
                );
            }
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.shared.style.size;
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.label.update(available_size);
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.focused = focused;
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_state: InputState) gui.InputResponse(ActionType) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var wants_focus = false;

            if (widget_bounds.containsOptMousePos(input_state.mouse_down_location)) {
                wants_focus = true;
            }

            if (input_state.mouse_down_location) |loc| {
                if (self.focused and !widget_bounds.containsMousePos(loc)) {
                    self.focused = false;
                }
            }

            var action: ?ActionType = null;
            if (self.focused) {
                action = self.text_action.generate(input_state.frame_keys.items);
            }

            return .{
                .wants_focus = wants_focus,
                .action = action,
            };
        }
    };
}

pub fn makeTextbox(comptime ActionType: type, alloc: Allocator, text_retreiver: anytype, text_action: anytype, shared: *const SharedTextboxState) !Widget(ActionType) {
    const label = try gui.label.makeLabel(ActionType, alloc, text_retreiver, std.math.maxInt(u31), shared.label_state);

    const TB = Textbox(ActionType, @TypeOf(text_action));
    const box = try alloc.create(TB);
    box.* = .{
        .label = label,
        .text_action = text_action,
        .shared = shared,
    };

    return .{
        .vtable = &TB.widget_vtable,
        .ctx = box,
    };
}
