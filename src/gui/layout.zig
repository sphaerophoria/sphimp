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

const ScrollState = struct {
    window_offs: i32,
    scrollbar_present: bool,
    mouse_down_window_offs: i32,
    scrollbar: Scrollbar,
};

pub fn Layout(comptime ActionType: type) type {
    return struct {
        cursor: Cursor = .{},
        items: std.ArrayListUnmanaged(LayoutItem) = .{},
        scroll_position_y: i32 = 0,
        scrollbar: Scrollbar,
        needs_scroll: bool = false,
        drag_start_scroll_y: ?i32 = null,

        const scrollbar_width = 10;

        const LayoutItem = struct {
            widget: Widget(ActionType),
            bounds: PixelBBox,
        };
        const Self = @This();

        pub fn init(squircle_renderer: *const SquircleRenderer) Self {
            return .{
                // FIXME: Maybe we can get away with a single scrollbar for everyone all at once
                .scrollbar = .{
                    .renderer = squircle_renderer,
                    .style = .{
                        // FIXME: This should live somewhere else
                        .background_color = .{ .r = 0.2, .g = 0.2, .b = 0.2, .a = 1.0 },
                        .corner_radius = 5.0,
                    },
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
            start_update: while (true) {
                self.cursor.reset();

                for (self.items.items) |*item| {
                    try item.widget.update(self.availableSize(window_size));
                    item.bounds = self.cursor.apply(item.widget.getSize());
                    if (self.cursor.y > window_size.height and !self.needs_scroll) {
                        self.needs_scroll = true;
                        continue :start_update;
                    }
                }

                if (self.cursor.y < window_size.height and self.needs_scroll) {
                    self.needs_scroll = false;
                    continue :start_update;
                }

                break;
            }
        }

        pub fn availableSize(self: *Self, window_size: PixelSize) PixelSize {
            const scrollbar_adjustment: u31 = if (self.needs_scroll) scrollbar_width else 0;
            return .{
                .width = window_size.width - self.cursor.x - scrollbar_adjustment,
                .height = std.math.maxInt(u31),
            };
        }

        pub fn dispatchInput(self: *Self, input_state: InputState, window_width: i32, window_height: i32) ActionType {
            var ret: ActionType = .none;

            const bar_bounds = Scrollbar.barBounds(
                self.contentHeight(),
                self.scroll_position_y,
                scrollAreaBounds(window_width, window_height),
            );

            // FIXME: cleanup
            if (input_state.mouse_down_location) |loc| {
                if (self.drag_start_scroll_y == null and bar_bounds.containsMousePos(loc)) {
                    self.drag_start_scroll_y = self.scroll_position_y;
                }

                if (self.drag_start_scroll_y) |start_y| {
                    self.scroll_position_y = start_y + Scrollbar.barOffsToContentOffs(
                        @intFromFloat(input_state.mouse_pos.y - loc.y),
                        // FIXME: scrollBarBounds and barBounds are heavily different concepts but sounds very similar
                        scrollAreaBounds(window_width, window_height),
                        self.contentHeight(),
                    );
                }
            } else if (self.drag_start_scroll_y != null) {
                self.drag_start_scroll_y = null;
            }

            self.scroll_position_y -= @intFromFloat(input_state.frame_scroll * 15);
            self.scroll_position_y = @max(0, self.scroll_position_y);
            self.scroll_position_y = @min(self.contentHeight() - window_height, self.scroll_position_y);

            var adjusted_input_state = input_state;

            adjusted_input_state.mouse_pos.y += @floatFromInt(self.scroll_position_y);
            if (adjusted_input_state.mouse_down_location) |*pos| {
                pos.y += @floatFromInt(self.scroll_position_y);
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
                    adjusted_item_bounds.top -= self.scroll_position_y;
                    adjusted_item_bounds.bottom -= self.scroll_position_y;
                }

                item.widget.render(adjusted_item_bounds, .{
                    .left = 0,
                    .bottom = window_height,
                    .right = window_width,
                    .top = 0,
                });
            }

            if (self.needs_scroll) {
                self.scrollbar.render(
                    .{ .r = 0.6, .g = 0.4, .b = 0.6, .a = 1.0 },
                    self.contentHeight(),
                    self.scroll_position_y,
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

        fn scrollPosNormalized(self: Self, window_height: i32) f32 {
            //FIXME: casts
            return @as(f32, @floatFromInt(self.scroll_position_y)) / @as(f32, @floatFromInt(self.cursor.y - window_height));
        }

        fn scrollAreaBounds(window_width: i32, window_height: i32) PixelBBox {
            return .{
                .left = window_width - scrollbar_width,
                .right = window_width,
                .top = 0,
                .bottom = window_height,
            };
        }
    };
}
