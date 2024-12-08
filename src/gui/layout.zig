const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const Scrollbar = gui.scrollbar.Scrollbar;
const SquircleRenderer = @import("SquircleRenderer.zig");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;

const Cursor = struct {
    x: u31 = 10,
    y: u31 = 10,

    fn reset(self: *Cursor) void {
        self.* = .{};
    }

    fn apply(self: *Cursor, size: PixelSize) PixelBBox {
        const bounds = PixelBBox{
            .left = self.x,
            .right = self.x + size.width,
            .top = self.y,
            .bottom = self.y + size.height,
        };

        const padding = 5;

        self.y += size.height + padding;
        return bounds;
    }
};

// FIXME: Layout style
const scrollbar_width = 10;

fn scrollAreaBounds(window_width: i32, window_height: i32) PixelBBox {
    return .{
        .left = window_width - scrollbar_width,
        .right = window_width,
        .top = 0,
        .bottom = window_height,
    };
}
fn scrollbarMissing(window_height: i32, content_height: i32, scrollbar_present: bool) bool {
    return (content_height > window_height) and !scrollbar_present;
}

fn scrollbarInWrongState(window_height: i32, content_height: i32, scrollbar_present: bool) bool {
    return (content_height > window_height) != scrollbar_present;
}

pub fn Layout(comptime ActionType: type) type {
    return struct {
        cursor: Cursor = .{},
        items: std.ArrayListUnmanaged(LayoutItem) = .{},

        scrollbar_present: bool = false,
        scroll_offs: i32 = 0,
        scrollbar: Scrollbar,

        const LayoutItem = struct {
            widget: Widget(ActionType),
            bounds: PixelBBox,
        };
        const Self = @This();

        pub fn init(scroll_style: *const gui.scrollbar.Style, squircle_renderer: *const SquircleRenderer) Self {
            return .{
                // FIXME: Maybe we can get away with a single scrollbar for everyone all at once
                .scrollbar = .{
                    .renderer = squircle_renderer,
                    .style = scroll_style,
                },
            };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            for (self.items.items) |item| {
                item.widget.deinit(alloc);
            }
            self.items.deinit(alloc);
        }

        pub fn pushWidget(self: *Self, alloc: Allocator, widget: Widget(ActionType)) !void {
            errdefer widget.deinit(alloc);
            const size = widget.getSize();
            const bounds = self.cursor.apply(size);

            try self.items.append(alloc, .{ .bounds = bounds, .widget = widget });
        }

        pub fn update(self: *Self, window_size: PixelSize) !void {
            // We cannot know if the layout requires a scrollbar without
            // actually executing a layout. Try layout with the current scroll
            // state, and re-layout if the state is wrong
            const scrollbar_options = [2]bool{
                self.scrollbar_present,
                !self.scrollbar_present,
            };

            start_update: for (scrollbar_options) |scrollbar_present| {
                self.scrollbar_present = scrollbar_present;
                self.cursor.reset();

                for (self.items.items) |*item| {
                    try item.widget.update(self.availableSize(window_size));
                    item.bounds = self.cursor.apply(item.widget.getSize());

                    // Early exit if we guessed the scrollbar state wrong
                    if (scrollbarMissing(
                        window_size.height,
                        self.contentHeight(),
                        self.scrollbar_present,
                    )) {
                        self.scrollbar_present = true;
                        continue :start_update;
                    }
                }

                // If we laid out everything and the scrollbar is in the wrong state, turn it off
                if (scrollbarInWrongState(
                    window_size.height,
                    self.contentHeight(),
                    self.scrollbar_present,
                )) {
                    self.scrollbar_present = false;
                    continue :start_update;
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

        pub fn availableSize(self: *Self, window_size: PixelSize) PixelSize {
            const scrollbar_adjustment: u31 = if (self.scrollbar_present) scrollbar_width else 0;
            return .{
                .width = window_size.width - self.cursor.x - scrollbar_adjustment,
                .height = std.math.maxInt(u31),
            };
        }

        pub fn dispatchInput(self: *Self, input_state: InputState, window_width: i32, window_height: i32) ActionType {
            var ret: ActionType = .none;

            if (self.scrollbar.handleInput(
                input_state,
                scrollAreaBounds(window_width, window_height),
            )) |scroll_loc| {
                const content_height: f32 = @floatFromInt(self.contentHeight());
                self.scroll_offs = @intFromFloat(content_height * scroll_loc);
            }

            self.scroll_offs -= @intFromFloat(input_state.frame_scroll * 15);

            self.scroll_offs = std.math.clamp(
                self.scroll_offs,
                0,
                self.contentHeight() - window_height,
            );

            var adjusted_input_state = input_state;

            adjusted_input_state.mouse_pos.y += @floatFromInt(self.scroll_offs);
            if (adjusted_input_state.mouse_down_location) |*pos| {
                pos.y += @floatFromInt(self.scroll_offs);
            }

            for (self.items.items) |item| {
                if (item.widget.setInputState(item.bounds, adjusted_input_state)) |action| {
                    ret = action;
                }
            }
            return ret;
        }

        pub fn render(self: *Self, window_width: i32, window_height: i32) void {
            for (self.items.items) |item| {
                var adjusted_item_bounds = item.bounds;

                if (window_height < self.contentHeight()) {
                    adjusted_item_bounds.top -= self.scroll_offs;
                    adjusted_item_bounds.bottom -= self.scroll_offs;
                }

                item.widget.render(adjusted_item_bounds, .{
                    .left = 0,
                    .bottom = window_height,
                    .right = window_width,
                    .top = 0,
                });
            }

            if (self.scrollbar_present) {
                self.scrollbar.render(
                    scrollAreaBounds(window_width, window_height),
                    .{
                        .left = 0,
                        .right = window_width,
                        .top = 0,
                        .bottom = window_height,
                    },
                );
            }
        }

        fn contentHeight(self: Self) i32 {
            return self.cursor.y;
        }
    };
}
