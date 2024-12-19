const std = @import("std");
const SquirqleRenderer = @import("SquircleRenderer.zig");
const gui = @import("gui.zig");
const util = @import("util.zig");
const sphmath = @import("sphmath");
const Color = gui.Color;
const InputState = gui.InputState;
const PixelBBox = gui.PixelBBox;

pub const Style = struct {
    gutter_color: Color,
    default_color: Color,
    hover_color: Color,
    active_color: Color,
    corner_radius: f32,
    width: u31,
};

pub const Scrollbar = struct {
    renderer: *const SquirqleRenderer,
    style: *const Style,
    bar_ratio: f32 = 1.0,
    top_offs_ratio: f32 = 0.0,
    scroll_input_state: ScrollState = .none,

    const ScrollState = union(enum) {
        dragging: f32, // start offs
        hovered,
        none,
    };

    // Returns desired scroll height as ratio of total scrollable area
    pub fn handleInput(self: *Scrollbar, input_state: InputState, bounds: PixelBBox) ?f32 {
        self.updateDragState(input_state, bounds);

        switch (self.scroll_input_state) {
            .dragging => |start_offs| {
                const scrollbar_height: f32 = @floatFromInt(bounds.calcHeight());

                const ret =  std.math.clamp(
                    (input_state.mouse_pos.y - input_state.mouse_down_location.?.y) / scrollbar_height + start_offs,
                    0.0,
                    1.0 - self.bar_ratio,
                );
                return ret;
            },
            else => {
                return null;
            },
        }
    }

    pub fn render(self: Scrollbar, bounds: PixelBBox, window: PixelBBox) void {
        const transform = util.widgetToClipTransform(bounds, window);
        self.renderer.render(
            self.style.gutter_color,
            0.0,
            bounds,
            transform,
        );

        const bar_transform = util.widgetToClipTransform(self.calcHandleBounds(bounds), window);
        const bar_color = switch (self.scroll_input_state) {
            .dragging => self.style.active_color,
            .hovered => self.style.hover_color,
            .none => self.style.default_color,
        };

        self.renderer.render(
            bar_color,
            self.style.corner_radius,
            bounds,
            bar_transform,
        );
    }

    fn calcHandleBounds(self: Scrollbar, scrollbar_bounds: PixelBBox) PixelBBox {
        const scrollbar_height: f32 = @floatFromInt(scrollbar_bounds.calcHeight());
        const bar_height_px = scrollbar_height * self.bar_ratio;
        const offs_px = self.top_offs_ratio * scrollbar_height;
        const top_px = @as(f32, @floatFromInt(scrollbar_bounds.top)) + offs_px;
        return .{
            .left = scrollbar_bounds.left,
            .right = scrollbar_bounds.right,
            .top = @intFromFloat(top_px),
            .bottom = @intFromFloat(top_px + bar_height_px),
        };
    }

    fn updateDragState(self: *Scrollbar, input_state: InputState, bounds: PixelBBox) void {
        const is_dragging = self.scroll_input_state == .dragging and input_state.mouse_down_location != null;

        if (is_dragging) return;

        if (bounds.containsOptMousePos(input_state.mouse_down_location)) {
            self.scroll_input_state = .{ .dragging = self.top_offs_ratio };
        } else if (bounds.containsMousePos(input_state.mouse_pos)) {
            self.scroll_input_state = .hovered;
        } else {
            self.scroll_input_state = .none;
        }
    }
};
