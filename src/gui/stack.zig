const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const util = @import("util.zig");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;


pub fn Stack(comptime ActionType: type) type {
    return struct {
        widgets: std.ArrayListUnmanaged(Widget(ActionType)) = .{},
        total_size: PixelSize = .{ .width = 0, .height = 0 },

        const Self = @This();

        const widget_vtable = Widget(ActionType).VTable {
            .deinit = Self.deinitWidget,
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
        };

        pub fn init(alloc: Allocator) !*Self {
            const stack = try alloc.create(Self);
            stack.* = .{};
            return stack;
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            for (self.widgets.items) |widget| {
                widget.deinit(alloc);
            }
            self.widgets.deinit(alloc);
            alloc.destroy(self);
        }

        pub fn pushWidgetOrDeinit(self: *Self, alloc: Allocator, widget: Widget(ActionType)) !void {
            errdefer widget.deinit(alloc);
            try self.widgets.append(alloc, widget);

            const item_size = widget.getSize();
            self.total_size.width = @max(self.total_size.width, item_size.width);
            self.total_size.height = @max(self.total_size.height, item_size.height);
        }

        pub fn toWidget(self: *Self) Widget(ActionType) {
            return .{
                .ctx = self,
                .vtable = &widget_vtable,
            };
        }

        fn deinitWidget(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.deinit(alloc);
        }

        fn render(ctx: ?*anyopaque, stack_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.widgets.items) |widget| {
                widget.render(itemBounds(stack_bounds, widget), window_bounds);
            }
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.total_size;
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize)!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var max_width: u31 = 0;
            var max_height: u31 = 0;

            for (self.widgets.items) |widget| {
                try widget.update(available_size);

                const widget_size = widget.getSize();
                max_width = @max(max_width, widget_size.width);
                max_height = @max(max_height, widget_size.height);
            }

            self.total_size = .{
                .width = max_width,
                .height = max_height,
            };
        }

        fn setInputState(ctx: ?*anyopaque, stack_bounds: PixelBBox, input_state: InputState) ?ActionType {
            const self: *Self = @ptrCast(@alignCast(ctx));

            var ret: ?ActionType  = null;

            var i: usize = self.widgets.items.len;
            while (i > 0) {
                i -= 1;

                const widget = self.widgets.items[i];
                const item_bounds = itemBounds(stack_bounds, widget);

                if (widget.setInputState(item_bounds, input_state)) |action| {
                    ret = action;
                }

                if (itemConsumesInput(item_bounds, input_state)) {
                    break;
                }
            }

            return ret;
        }

        fn itemConsumesInput(item_bounds: PixelBBox, input_state: InputState) bool {
            // FIXME: Maybe widgets should say if they consume input
            if (input_state.mouse_down_location) |loc| {
                return item_bounds.containsMousePos(loc);
            } else {
                return item_bounds.containsMousePos(input_state.mouse_pos);
            }
        }

        fn itemBounds(stack_bounds: PixelBBox, widget: Widget(ActionType)) PixelBBox {
            return util.centerBoxInBounds(widget.getSize(), stack_bounds);
        }
    };
}


//fn main() void {
//    const stack = makeStack();
//    const rect = makeBackgroundRect(...);
//    stack.pushWidgetOrDeinit(rect);
//
//    const overlay_widget = makeOverlayWidget();
//    stack.pushWidgetOrDeinit(overlay_widget);
//
//    popup.set(stack.toWidget());
//
//}
