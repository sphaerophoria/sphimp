const std = @import("std");
const SquirqleRenderer = @import("SquircleRenderer.zig");
const gui = @import("gui.zig");
const util = @import("util.zig");
const sphmath = @import("sphmath");
const Color = gui.Color;
const PixelBBox = gui.PixelBBox;

pub const Style = struct {
    background_color: Color,
    corner_radius: f32,
};
pub const Scrollbar = struct {
    renderer: *const SquirqleRenderer,
    style: Style,

    pub fn barBounds(total_scrollable_height: f32, scroll_pos_normalized: f32, bounds: PixelBBox) PixelBBox {
        const window_height: f32 = @floatFromInt(bounds.calcHeight());
        const bar_height = window_height / total_scrollable_height * window_height;
        std.debug.print("bar height: {d}\n", .{bar_height});
        std.debug.print("window height: {d}\n", .{window_height});
        std.debug.print("total scrollable height: {d}\n", .{total_scrollable_height});
        const half_bar_height = bar_height / 2.0;
        const bar_center = std.math.lerp(half_bar_height, window_height - half_bar_height, scroll_pos_normalized);

        return .{
            .left = bounds.left,
            .right = bounds.right,
            .top = @intFromFloat(@round(bar_center - half_bar_height)),
            .bottom = @intFromFloat(@round(bar_center + half_bar_height)),
        };
    }

    pub fn pixelOffsToScrollOffs(y_offs: f32, bounds: PixelBBox, total_scrollable_height: f32) f32 {
        const window_height: f32 = @floatFromInt(bounds.calcHeight());
        const bar_height = window_height / total_scrollable_height * window_height;
        const scrollable_distance = window_height - bar_height;
        const scroll_px_to_norm = total_scrollable_height - window_height;
        const ret = y_offs / scrollable_distance * scroll_px_to_norm;
        std.debug.print("scroll offs: {d}, mouse_movement: {d}, scrollable_distance: {d}, window_height: {d}, bar_height: {d}, total_scrollable_height: {d}\n", .{ret, y_offs, scrollable_distance, window_height, bar_height, total_scrollable_height});
        return ret;
    }

    test "pixel offs calc" {
        const offs = pixelOffsToScrollOffs(100.0, .{
            .left = 0,
            .right = 100,
            .top = 0,
            .bottom = 200,
        },
         400.0
        );

        try std.testing.expectApproxEqAbs(400.0, offs, 1e-7);
    }

    pub fn render(self: Scrollbar, bar_color: Color, total_scrollable_height: f32, scroll_pos_normalized: f32, bounds: PixelBBox, window: PixelBBox) void {
        const transform = util.widgetToClipTransform(bounds, window);
        self.renderer.render(
            self.style.background_color,
            self.style.corner_radius,
            bounds,
            transform,
        );

        const bar_transform = util.widgetToClipTransform(barBounds(total_scrollable_height, scroll_pos_normalized, bounds), window);

        self.renderer.render(
            bar_color,
            self.style.corner_radius,
            bounds,
            bar_transform,
        );
    }
};
