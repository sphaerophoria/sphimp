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
    pub fn barBounds(total_content_height: i32, window_top_offs: i32, bounds: PixelBBox) PixelBBox {
        const window_height = bounds.calcHeight();
        const bar_height = barHeightPx(window_height, total_content_height);
        const max_bar_pos = gutterScrollRange(window_height, bar_height);
        const max_window_offset = maxWindowOffset(window_height, total_content_height);

        if (max_window_offset == 0) {
            return bounds;
        }

        const top = @divTrunc(max_bar_pos * window_top_offs, max_window_offset);
        const bottom = top + bar_height;

        return .{
            .left = bounds.left,
            .right = bounds.right,
            .top = top,
            .bottom = bottom,
        };
    }

    // Given a mouse movement on the scrollbar, how far in content space should we move
    pub fn barOffsToContentOffs(y_offs: i32, scrollbar_bounds: PixelBBox, total_content_height: i32) i32 {
        const window_height = scrollbar_bounds.calcHeight();
        const bar_height = barHeightPx(window_height, total_content_height);
        const max_bar_pos = gutterScrollRange(window_height, bar_height);
        return @divTrunc(maxWindowOffset(window_height, total_content_height) * y_offs, max_bar_pos);
    }

    pub fn render(self: Scrollbar, bar_color: Color, total_scrollable_height: i32, window_top_offset: i32, bounds: PixelBBox, window: PixelBBox) void {
        const transform = util.widgetToClipTransform(bounds, window);
        self.renderer.render(
            self.style.background_color,
            self.style.corner_radius,
            bounds,
            transform,
        );

        const bar_transform = util.widgetToClipTransform(barBounds(total_scrollable_height, window_top_offset, bounds), window);

        self.renderer.render(
            bar_color,
            self.style.corner_radius,
            bounds,
            bar_transform,
        );
    }
};

test "pixel offs calc" {
    const offs = Scrollbar.barOffsToContentOffs(100.0, .{
        .left = 0,
        .right = 100,
        .top = 0,
        .bottom = 200,
    }, 400.0);

    try std.testing.expectApproxEqAbs(400.0, offs, 1e-7);
}

// Assuming the bar takes up the whole window, how many pixels tall is the
// bar in the scroll area
fn barHeightPx(window_height: i32, total_content_height: i32) i32 {
    // window_height / total_content_height == [0,1] ratio of size
    // Size in pixels is ratio * number of vertical pixels
    // So we get the integer math of window * window / total
    return @divTrunc(window_height * window_height, total_content_height);
}

// In pixels, what movement results in a 100% scroll from top to bottom
fn gutterScrollRange(window_height: i32, bar_height_px: i32) i32 {
    return window_height - bar_height_px;
}

// In pixels, what is the maximum distance the top of the viewport be
// offset from the content
fn maxWindowOffset(window_height: i32, total_content_height: i32) i32 {
    return total_content_height - window_height;
}
