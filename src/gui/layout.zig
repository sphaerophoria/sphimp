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
    x: u31 = 0,
    y: u31 = 0,

    direction: enum {
        vertical,
        horizontal,
    } = .vertical,

    fn reset(self: *Cursor) void {
        self.x = 0;
        self.y = 0;
    }

    fn apply(self: *Cursor, size: PixelSize, padding: u31) PixelBBox {
        const bounds = PixelBBox{
            .left = self.x,
            .right = self.x + size.width,
            .top = self.y,
            .bottom = self.y + size.height,
        };

        switch (self.direction) {
            .vertical => self.y += size.height + padding,
            .horizontal => self.x += size.width + padding,
        }

        return bounds;
    }
};

pub fn Layout(comptime ActionType: type) type {
    return struct {
        cursor: Cursor,
        items: std.ArrayListUnmanaged(LayoutItem),
        item_pad: u31,
        focused_id: ?usize,
        // FIXME: Only store non-layout dimension
        max_item_size: PixelSize,

        const LayoutItem = struct {
            widget: Widget(ActionType),
            bounds: PixelBBox,
        };
        const Self = @This();

        const widget_vtable = Widget(ActionType).VTable{
            .deinit = Self.widgetDeinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
        };

        pub fn init(alloc: Allocator, item_pad: u31) !*Self {
            const layout = try alloc.create(Self);
            layout.* = .{
                .cursor = .{},
                .items = .{},
                .item_pad = item_pad,
                .focused_id = null,
                .max_item_size = .{
                    .width = 0,
                    .height = 0,
                },
            };
            return layout;
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            for (self.items.items) |item| {
                item.widget.deinit(alloc);
            }
            self.items.deinit(alloc);
            alloc.destroy(self);
        }

        pub fn reset(self: *Self, alloc: Allocator) void {
            for (self.items.items) |item| {
                item.widget.deinit(alloc);
            }
            self.items.deinit(alloc);
            self.items = .{};
            self.cursor.reset();
            self.focused_id = null;
            self.max_item_size = .{
                .width = 0,
                .height = 0,
            };
        }

        fn widgetDeinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.deinit(alloc);
        }

        pub fn pushOrDeinitWidget(self: *Self, alloc: Allocator, widget: Widget(ActionType)) !void {
            errdefer widget.deinit(alloc);
            const size = widget.getSize();
            const bounds = self.cursor.apply(size, self.item_pad);

            try self.items.append(alloc, .{ .bounds = bounds, .widget = widget });

            const width = @max(self.max_item_size.width, bounds.calcWidth());
            const height = @max(self.max_item_size.height, bounds.calcHeight());
            self.max_item_size = .{
                .width = width,
                .height = height,
            };
        }

        pub fn asWidget(self: *Self) Widget(ActionType) {
            return .{
                .ctx = self,
                .vtable = &widget_vtable,
            };
        }

        pub fn update(ctx: ?*anyopaque, container_size: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.cursor.reset();

            var max_width: u31 = 0;
            var max_height: u31 = 0;

            for (self.items.items) |*item| {
                try item.widget.update(self.availableSize(container_size));
                const widget_size = item.widget.getSize();
                item.bounds = self.cursor.apply(widget_size, self.item_pad);
                max_width = @max(max_width, widget_size.width);
                max_height = @max(max_height, widget_size.height);
            }

            self.max_item_size = .{
                .width = max_width,
                .height = max_height,
            };
        }

        pub fn availableSize(self: *Self, container_size: PixelSize) PixelSize {
            const available_height = if (container_size.height > self.cursor.y)
                container_size.height - self.cursor.y
            else
                0;

            const available_width = if (container_size.width > self.cursor.x)
                container_size.width - self.cursor.x
            else
                0;

            return .{
                .width = available_width,
                .height = available_height,
            };
        }

        fn setInputState(ctx: ?*anyopaque, bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) gui.InputResponse(ActionType) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var ret = gui.InputResponse(ActionType){
                .wants_focus = false,
                .action = null,
            };

            for (self.items.items, 0..) |item, idx| {
                // FIXME: duplicated with render()
                const child_bounds = PixelBBox{
                    .top = bounds.top + item.bounds.top,
                    .bottom = bounds.top + item.bounds.bottom,
                    .left = bounds.left + item.bounds.left,
                    .right = bounds.left + item.bounds.right,
                };

                const input_response = item.widget.setInputState(child_bounds, child_bounds.calcIntersection(input_bounds), input_state);

                if (input_response.wants_focus) {
                    if (self.focused_id) |id| {
                        self.items.items[id].widget.setFocused(false);
                    }
                    self.focused_id = idx;
                    ret.wants_focus = true;
                }

                if (input_response.action) |action| {
                    ret.action = action;
                }
            }

            return ret;
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            for (self.items.items) |item| {
                const child_bounds = PixelBBox{
                    .top = bounds.top + item.bounds.top,
                    .bottom = bounds.top + item.bounds.bottom,
                    .left = bounds.left + item.bounds.left,
                    .right = bounds.left + item.bounds.right,
                };

                item.widget.render(child_bounds, window_bounds);
            }
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            switch (self.cursor.direction) {
                .horizontal => {
                    return .{
                        .width = self.cursor.x,
                        .height = self.max_item_size.height,
                    };
                },
                .vertical => {
                    return .{
                        .width = self.max_item_size.width,
                        .height = self.cursor.y,
                    };
                },
            }
        }

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.focused_id) |id| {
                self.items.items[id].widget.setFocused(focused);
            }
        }
    };
}
