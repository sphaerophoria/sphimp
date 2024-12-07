const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;

const Cursor = struct {
    x: i32 = 10,
    y: i32 = 10,

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

pub fn Layout(comptime ActionType: type) type {
    return struct {
        cursor: Cursor = .{},
        items: std.ArrayListUnmanaged(LayoutItem) = .{},

        const LayoutItem = struct {
            widget: Widget(ActionType),
            bounds: PixelBBox,
        };
        const Self = @This();

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

        pub fn update(self: *Self) !void {
            self.cursor.reset();

            for (self.items.items) |*item| {
                try item.widget.update();
                item.bounds = self.cursor.apply(item.widget.getSize());
            }
        }

        pub fn dispatchInput(self: *Self, input_state: InputState) ActionType {
            var ret: ActionType = .none;
            for (self.items.items) |item| {
                if (item.widget.setInputState(item.bounds, input_state)) |action| {
                    ret = action;
                }
            }
            return ret;
        }

        pub fn render(self: *Self, window_width: i32, window_height: i32) void {
            for (self.items.items) |item| {
                item.widget.render(item.bounds, .{ .left = 0, .bottom = window_height, .right = window_width, .top = 0 });
            }
        }
    };
}
