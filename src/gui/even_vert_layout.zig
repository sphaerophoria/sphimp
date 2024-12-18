const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const gui = @import("gui.zig");
const Widget = gui.Widget;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;

pub fn EvenVertLayout(comptime ActionType: type) type {
    return struct {
        items: std.ArrayListUnmanaged(Widget(ActionType)) = .{},
        // FIXME: width redundant
        container_size: PixelSize = .{ .width = 0, .height = 0 },
        focused_id: ?usize = null,
        width: u31,

        const Self = @This();

        const widget_vtable = Widget(ActionType).VTable {
            .deinit = Self.widgetDeinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
        };

        pub fn pushOrDeinitWidget(self: *Self, alloc: Allocator, widget: Widget(ActionType)) !void {
            errdefer widget.deinit(alloc);
            try self.items.append(alloc, widget);
        }

        pub fn asWidget(self: *Self) Widget(ActionType) {
            return .{
                .ctx = self,
                .vtable = &widget_vtable,
            };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            for (self.items.items) |item| {
                item.deinit(alloc);
            }
            self.items.deinit(alloc);
            alloc.destroy(self);
        }

        fn widgetDeinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.deinit(alloc);
        }

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (0..self.items.items.len) |i| {
                const item = self.items.items[i];
                const child_bounds = childBounds(widget_bounds, item.getSize(), i, self.items.items.len);

                const scissor = sphrender.TemporaryScissor.init();
                defer scissor.reset();

                scissor.set(child_bounds.left, window_bounds.calcHeight() - child_bounds.bottom, child_bounds.calcWidth(), child_bounds.calcHeight());

                item.render(child_bounds, window_bounds);
            }
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.container_size;
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.container_size = .{
                .width = self.width,
                .height = available_size.height,
            };

            const child_size = PixelSize {
                .width = self.width,
                .height = @intCast(available_size.height / self.items.items.len),
            };
            for (self.items.items) |item| {
                try item.update(child_size);
            }
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) gui.InputResponse(ActionType) {
            const self: *Self = @ptrCast(@alignCast(ctx));

            var ret = gui.InputResponse(ActionType) {
                .wants_focus = false,
                .action = null,
            };

            for (self.items.items, 0..) |item, i| {
                const child_bounds = childBounds(widget_bounds, item.getSize(), i, self.items.items.len);
                const frame_area = PixelBBox {
                    .top = child_bounds.top,
                    .bottom = child_bounds.top + @as(i32, @intCast(self.container_size.height / self.items.items.len)),
                    .left = widget_bounds.left,
                    .right = widget_bounds.right,
                };

                const input_area = frame_area.calcIntersection(child_bounds).calcIntersection(input_bounds);

                const response = item.setInputState(child_bounds, input_area, input_state);

                if (response.wants_focus) {
                    ret.wants_focus = true;
                    self.focused_id = i;
                }

                if (response.action) |action| {
                    ret.action = action;
                }
            }

            return ret;
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.focused_id) |id| {
                self.items.items[id].setFocused(focused);
            }
        }
    };
}

fn childBounds(layout_bounds: PixelBBox, widget_size: PixelSize, idx: usize, num_children: usize) PixelBBox {

    const top: i32 = @intCast(layout_bounds.calcHeight() * idx / num_children);

    return .{
        .left = layout_bounds.left,
        .right = layout_bounds.left + widget_size.width,
        .top = top,
        .bottom = top + widget_size.height,
    };
}

