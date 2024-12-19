const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const util = @import("util.zig");
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputResponse = gui.InputResponse;
const InputState = gui.InputState;
const Widget = gui.Widget;

pub const Shared = struct {
    border_size: u31,
    border_color: gui.Color,
    corner_raduis: f32,
    squircle_renderer: *const gui.SquircleRenderer,
};

pub fn Options(comptime Action: type) type {
    return  struct {
        inner: Widget(Action),
        shared: *const Shared,
    };
}

pub fn makeFrame(comptime Action: type, alloc: Allocator, options: Options(Action)) !Widget(Action) {
    const ctx = try alloc.create(Frame(Action));

    const inner_size = options.inner.getSize();
    const size = PixelSize {
        .width = inner_size.width + options.shared.border_size * 2,
        .height = inner_size.height + options.shared.border_size * 2,
    };

    ctx.* = .{
        .container_size = size,
        .inner = options.inner,
        .shared = options.shared,
    };

    return .{
        .ctx = ctx,
        .vtable = &Frame(Action).widget_vtable,
    };
}

pub fn Frame(comptime Action: type) type {
    return struct {
        container_size: PixelSize,
        inner: Widget(Action),
        shared: *const Shared,

        const widget_vtable = Widget(Action).VTable {
            .deinit = Self.deinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
        };

        const Self = @This();

        fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.inner.deinit(alloc);
            alloc.destroy(self);
        }

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            //const left = PixelBBox {
            //    .left = widget_bounds.left,
            //    .right = widget_bounds.left + self.border_size,
            //    .top = widget_bounds.top,
            //    .bottom = widget_bounds.bottom,
            //};

            //const right = PixelBBox {
            //    .left = widget_bounds.right - self.border_size,
            //    .right = widget_bounds.right,
            //    .top = widget_bounds.top,
            //    .bottom = widget_bounds.bottom,
            //};

            //const top = PixelBBox {
            //    .left = widget_bounds.left,
            //    .right = widget_bounds.right,
            //    .top = widget_bounds.top,
            //    .bottom = widget_bounds.top + self.border_size,
            //};

            //const bottom = PixelBBox {
            //    .left = widget_bounds.left,
            //    .right = widget_bounds.right,
            //    .top = widget_bounds.bottom - self.border_size,
            //    .bottom = widget_bounds.bottom,
            //};

            //for (&[4]PixelBBox{bottom, left, right, top}) |edge| {
            //    const transform = util.widgetToClipTransform(edge, window_bounds);
            //    self.shared.squircle_renderer.render(
            //        self.shared.border_color,
            //        self.shared.corner_raduis,
            //        edge,
            //        transform,
            //    );
            //    break;
            //}

            self.inner.render(self.adjustBounds(widget_bounds), window_bounds);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const size = self.inner.getSize();
            return .{
                .width = size.width + self.shared.border_size * 2,
                .height = size.height + self.shared.border_size * 2,
            };
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.update(self.adjustSize(available_size));
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.setInputState(self.adjustBounds(widget_bounds), self.adjustBounds(input_bounds), input_state);
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.inner.setFocused(focused);
        }

        fn adjustSize(self: Self, size: PixelSize) PixelSize {
            return .{
                .width = size.width - self.shared.border_size * 2,
                .height = size.height - self.shared.border_size * 2,
            };
        }

        fn adjustBounds(self: Self, bounds: PixelBBox) PixelBBox {
            return .{
                .top = bounds.top + self.shared.border_size,
                .bottom = bounds.bottom - self.shared.border_size,
                .left = bounds.left + self.shared.border_size,
                .right = bounds.right - self.shared.border_size,
            };
        }
    };
}
