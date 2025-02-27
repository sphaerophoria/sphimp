const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const Widget = gui.Widget;
const InputResponse = gui.InputResponse;

pub const FillStyle = union(enum) {
    fill_none,
    fill_width,
    fill_height,
    // Fill both would be useless
};

pub fn box(comptime Action: type, arena: Allocator, inner: Widget(Action), size: PixelSize, fill_style: FillStyle) !Widget(Action) {
    const ctx = try arena.create(Box(Action));
    ctx.* = .{
        .inner = inner,
        .size = size,
        .fill_style = fill_style,
    };

    return .{
        .ctx = ctx,
        .name = "box",
        .vtable = &Box(Action).vtable,
    };
}

pub fn Box(comptime Action: type) type {
    return struct {
        inner: Widget(Action),
        size: PixelSize,
        fill_style: FillStyle,

        const Self = @This();
        const vtable = Widget(Action).VTable{
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
            .reset = Self.reset,
        };

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.inner.render(widget_bounds, window_bounds);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.getSize();
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize, delta_s: f32) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            switch (self.fill_style) {
                .fill_none => {},
                .fill_width => self.size.width = available_size.width,
                .fill_height => self.size.height = available_size.height,
            }
            return self.inner.update(self.size, delta_s);
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.setInputState(widget_bounds, input_bounds, input_state);
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.inner.setFocused(focused);
        }

        fn reset(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.inner.reset();
        }
    };
}
