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
        items: std.ArrayListUnmanaged(StackItem) = .{},
        total_size: PixelSize = .{ .width = 0, .height = 0 },
        focused_id: ?usize = null,

        const Self = @This();

        pub const Layout = union(enum) {
            centered,
            offset: struct {
                x_offs: i32,
                y_offs: i32,
            },
        };

        const StackItem = struct {
            layout: Layout,
            widget: Widget(ActionType),
        };

        const widget_vtable = Widget(ActionType).VTable{
            .deinit = Self.deinitWidget,
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
        };

        pub fn init(alloc: Allocator) !*Self {
            const stack = try alloc.create(Self);
            stack.* = .{};
            return stack;
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            for (self.items.items) |item| {
                item.widget.deinit(alloc);
            }
            self.items.deinit(alloc);
            alloc.destroy(self);
        }

        pub fn pushWidgetOrDeinit(self: *Self, alloc: Allocator, widget: Widget(ActionType), layout: Layout) !void {
            errdefer widget.deinit(alloc);
            try self.items.append(alloc, .{
                .layout = layout,
                .widget = widget,
            });

            const item_size = widget.getSize();
            self.total_size = newTotalSize(self.total_size, layout, item_size);
        }

        pub fn asWidget(self: *Self) Widget(ActionType) {
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
            for (self.items.items) |item| {
                item.widget.render(itemBounds(stack_bounds, item.layout, item.widget), window_bounds);
            }
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.total_size;
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.total_size = .{ .width = 0, .height = 0 };

            for (self.items.items) |item| {
                try item.widget.update(available_size);

                const item_size = item.widget.getSize();
                self.total_size = newTotalSize(self.total_size, item.layout, item_size);
            }
        }

        fn setInputState(ctx: ?*anyopaque, stack_bounds: PixelBBox, input_state: InputState) gui.InputResponse(ActionType) {
            const self: *Self = @ptrCast(@alignCast(ctx));

            var ret = gui.InputResponse(ActionType){
                .wants_focus = false,
                .action = null,
            };

            var i: usize = self.items.items.len;
            while (i > 0) {
                i -= 1;

                const item = self.items.items[i];
                const item_bounds = itemBounds(stack_bounds, item.layout, item.widget);

                const input_response = item.widget.setInputState(item_bounds, input_state);
                if (input_response.wants_focus) {
                    self.focused_id = i;
                }
                // FIXME: unusre this is right
                ret.wants_focus = input_response.wants_focus;
                ret.action = input_response.action;

                if (ret.wants_focus or util.itemConsumesInput(item_bounds, input_state)) {
                    break;
                }
            }

            return ret;
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.focused_id) |id| {
                self.items.items[id].widget.setFocused(focused);
            }
        }

        fn itemBounds(stack_bounds: PixelBBox, layout: Layout, widget: Widget(ActionType)) PixelBBox {
            switch (layout) {
                .centered => return util.centerBoxInBounds(widget.getSize(), stack_bounds),
                .offset => |offs| {
                    const item_size = widget.getSize();
                    const left = stack_bounds.left + offs.x_offs;
                    const top = stack_bounds.top + offs.y_offs;
                    return .{
                        .left = left,
                        .right = left + item_size.width,
                        .top = top,
                        .bottom = top + item_size.height,
                    };
                },
            }
        }

        fn newTotalSize(old_size: PixelSize, layout: Layout, widget_size: PixelSize) PixelSize {
            var new_size = old_size;
            switch (layout) {
                .centered => {
                    new_size.width = @max(new_size.width, widget_size.width);
                    new_size.height = @max(new_size.height, widget_size.height);
                },
                .offset => |offs| {
                    new_size.width = @max(new_size.width, widget_size.width + offs.x_offs);
                    new_size.height = @max(new_size.height, widget_size.height + offs.y_offs);
                },
            }
            return new_size;
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
