const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const Widget = gui.Widget;
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const InputState = gui.InputState;

// FIXME: configuable style
const outer_pad: u31 = 10;
pub fn PositionalRenderer(comptime ActionType: type) type {
    return struct {
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

        pub fn pushOrDeinitWidget(self: *Self, alloc: Allocator, widget: Widget(ActionType), bounds: PixelBBox) !void {
            errdefer widget.deinit(alloc);
            try self.items.append(alloc, .{ .bounds = bounds, .widget = widget });
        }

        pub fn reset(self: *Self, alloc: Allocator) void {
            self.deinit(alloc);
            self.items = .{};
        }

        const InputResult = struct {
            consumed: bool = false,
            action: ?ActionType,
        };

        pub fn dispatchInput(self: *Self, input_state: InputState) ?InputResult {
            var ret: ?ActionType = null;

            var consumed = false;
            for (self.items.items) |item| {
                consumed = consumed or item.bounds.containsOptMousePos(input_state.mouse_down_location);

                if (item.widget.setInputState(item.bounds, input_state)) |action| {
                    ret = action;
                }
            }

            return .{
                .consumed = consumed,
                .action = ret,
            };
        }

        pub fn update(self: *Self, container_size: PixelSize) !void {
            for (self.items.items) |item| {
                try item.widget.update(container_size);
            }
        }

        pub fn render(self: *Self, window_bounds: PixelBBox) void {
            for (self.items.items) |item| {
                item.widget.render(item.bounds, window_bounds);
            }
        }
    };
}
