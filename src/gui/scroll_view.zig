const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const Scrollbar = gui.scrollbar.Scrollbar;
const SquircleRenderer = @import("SquircleRenderer.zig");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;

pub fn ScrollView(comptime ActionType: type) type {
    return struct {
        layout: Widget(ActionType),

        scrollbar_present: bool = false,
        scroll_offs: i32 = 0,
        scrollbar: Scrollbar,

        const top_pad: u31 = 10;
        const left_pad: u31 = 10;

        const Self = @This();

        pub fn init(layout: Widget(ActionType), scrollbar_style: *const gui.scrollbar.Style, squircle_renderer: *const SquircleRenderer) Self {
            return .{
                .layout = layout,
                .scrollbar = .{
                    .renderer = squircle_renderer,
                    .style = scrollbar_style,
                },
            };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.layout.deinit(alloc);
        }

        pub fn update(self: *Self, window_size: PixelSize) !void {
            // We cannot know if the layout requires a scrollbar without
            // actually executing a layout. Try layout with the current scroll
            // state, and re-layout if the state is wrong
            const scrollbar_options = [2]bool{
                self.scrollbar_present,
                !self.scrollbar_present,
            };

            for (scrollbar_options) |scrollbar_present| {
                self.scrollbar_present = scrollbar_present;

                var adjusted_window_size = window_size;
                adjusted_window_size.width -= self.scrollbarWidth();
                try self.layout.update(adjusted_window_size);

                // If we laid out everything and the scrollbar is in the wrong state, turn it off
                if (scrollbarInWrongState(
                    window_size.height,
                    self.contentHeight(),
                    self.scrollbar_present,
                )) {
                    continue;
                }

                break;
            }

            self.scrollbar.bar_ratio =
                @as(f32, @floatFromInt(window_size.height)) /
                @as(f32, @floatFromInt(self.contentHeight()));

            self.scrollbar.top_offs_ratio =
                @as(f32, @floatFromInt(self.scroll_offs)) /
                @as(f32, @floatFromInt(self.contentHeight()));
        }

        pub fn dispatchInput(self: *Self, input_state: InputState, bounds: PixelBBox) ?ActionType {
            if (self.scrollbar.handleInput(
                input_state,
                scrollAreaBounds(self.scrollbar, bounds),
            )) |scroll_loc| {
                const content_height: f32 = @floatFromInt(self.contentHeight());
                self.scroll_offs = @intFromFloat(content_height * scroll_loc);
            }

            self.scroll_offs -= @intFromFloat(input_state.frame_scroll * 15);

            self.scroll_offs = std.math.clamp(
                self.scroll_offs,
                0,
                @max(self.contentHeight() - bounds.calcHeight(), 0),
            );

            return self.layout.setInputState(self.layoutBounds(bounds), input_state).action;
        }

        pub fn render(self: *Self, bounds: PixelBBox, window_bounds: PixelBBox) void {
            self.layout.render(self.layoutBounds(bounds), window_bounds);

            const window_width = window_bounds.calcWidth();
            const window_height = window_bounds.calcHeight();

            if (self.scrollbar_present) {
                self.scrollbar.render(
                    scrollAreaBounds(self.scrollbar, bounds),
                    .{
                        .left = 0,
                        .right = window_width,
                        .top = 0,
                        .bottom = window_height,
                    },
                );
            }
        }

        fn layoutBounds(self: Self, bounds: PixelBBox) PixelBBox {
            var layout_bounds = bounds;
            layout_bounds.top -= self.scroll_offs;
            layout_bounds.top += top_pad;
            layout_bounds.left += left_pad;
            layout_bounds.bottom -= self.scroll_offs;
            return layout_bounds;
        }

        fn contentHeight(self: Self) i32 {
            return self.layout.getSize().height + top_pad;
        }

        fn scrollbarWidth(self: Self) u31 {
            if (self.scrollbar_present) {
                return self.scrollbar.style.width;
            } else {
                return 0;
            }
        }
    };
}

fn scrollAreaBounds(scrollbar: Scrollbar, bounds: PixelBBox) PixelBBox {
    return .{
        .left = bounds.right - scrollbar.style.width,
        .right = bounds.right,
        .top = bounds.top,
        .bottom = bounds.bottom,
    };
}
fn scrollbarMissing(window_height: i32, content_height: i32, scrollbar_present: bool) bool {
    return (content_height > window_height) and !scrollbar_present;
}

fn scrollbarInWrongState(window_height: i32, content_height: i32, scrollbar_present: bool) bool {
    return (content_height > window_height) != scrollbar_present;
}
