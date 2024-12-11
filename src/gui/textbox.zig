const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const Widget = gui.Widget;
const Rect = gui.rect.Rect;
const Stack = gui.stack.Stack;
const SharedLabelState = gui.label.SharedLabelState;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const SquircleRenderer = @import("SquircleRenderer.zig");

//pub fn Textbox(comptime ActionType: type) type {
//    return struct {
//
//
//
//    };
//}
//
pub const TextboxStyle = struct {
    background_color: gui.Color,
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
        stack: Widget(ActionType),
        text_action: TextAction,
        mouse_state: enum {
            not_clicked,
            clicked,
        } = .not_clicked,

        const Self = @This();

        const widget_vtable = Widget(ActionType).VTable {
            .deinit = Self.deinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
        };

        fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.stack.deinit(alloc);
            alloc.destroy(self);
        }

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.stack.render(widget_bounds, window_bounds);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.stack.getSize();
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize)!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.stack.update(available_size);
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_state: InputState) ?ActionType{
            const self: *Self = @ptrCast(@alignCast(ctx));

            var ret: ?ActionType = null;
            switch (self.mouse_state) {
                .not_clicked => {
                    if (widget_bounds.containsOptMousePos(input_state.mouse_down_location)) {
                        ret = self.text_action.generate('a');
                        self.mouse_state = .clicked;
                    }
                },
                .clicked => {
                    if (input_state.mouse_released) {
                        self.mouse_state = .not_clicked;
                    }

                },
            }
            return ret;
        }
    };
}

pub fn makeTextbox(comptime ActionType: type, alloc: Allocator, text_retreiver: anytype, text_action: anytype, shared: *const SharedTextboxState) !Widget(ActionType) {
    const stack = try Stack(ActionType).init(alloc);
    errdefer stack.deinit(alloc);

    const rect = try Rect(ActionType).init(
        alloc,
        shared.style.size,
        shared.style.background_color,
        shared.squircle_renderer,
    );
    try stack.pushWidgetOrDeinit(alloc, rect, .{ .offset = .{ .x_offs = 0, .y_offs = 0 }});

    const label = try gui.label.makeLabel(ActionType, alloc, text_retreiver, std.math.maxInt(u31), shared.label_state);
    const label_size = label.getSize();

    const rect_size = rect.getSize();
    const y_offs = @divTrunc(rect_size.height - label_size.height, 2);
    const x_offs = shared.style.label_pad;
    try stack.pushWidgetOrDeinit(alloc, label, .{ .offset = .{.x_offs = x_offs, .y_offs = y_offs} });

    const TB = Textbox(ActionType, @TypeOf(text_action));
    const box = try alloc.create(TB);
    box.* = .{
        .stack = stack.toWidget(),
        .text_action = text_action,
    };

    return .{
        .vtable = &TB.widget_vtable,
        .ctx = box,
    };
}
