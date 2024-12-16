const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const util = @import("util.zig");
const Widget = gui.Widget;
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const InputState = gui.InputState;
const Color = gui.Color;
const SquircleRenderer = @import("SquircleRenderer.zig");

pub fn Rect(comptime ActionType: type) type {
    return struct {
        size: PixelSize,
        renderer: *const SquircleRenderer,
        color: Color,

        const Self = @This();

        const widget_vtable = Widget(ActionType).VTable{
            .deinit = Self.deinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
        };

        pub fn init(
            alloc: Allocator,
            size: PixelSize,
            color: Color,
            renderer: *const SquircleRenderer,
        ) !Widget(ActionType) {
            const rect = try alloc.create(Self);
            rect.* = .{
                .size = size,
                .color = color,
                .renderer = renderer,
            };

            return .{
                .vtable = &Self.widget_vtable,
                .ctx = @ptrCast(rect),
            };
        }

        fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            alloc.destroy(self);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.size;
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize) !void  {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.size = available_size;
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const transform = util.widgetToClipTransform(bounds, window);

            self.renderer.render(
                self.color,
                1.0,
                bounds,
                transform,
            );
        }
    };
}
