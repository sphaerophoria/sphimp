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

    fn apply(self: *Cursor, size: PixelSize, padding: u31) PixelBBox {
        const bounds = PixelBBox{
            .left = self.x,
            .right = self.x + size.width,
            .top = self.y,
            .bottom = self.y + size.height,
        };

        self.y += size.height + padding;
        return bounds;
    }
};

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

pub fn ScrollView(comptime ActionType: type) type {
    return struct {
        layout: Layout(ActionType),

        scrollbar_present: bool = false,
        scroll_offs: i32 = 0,
        scrollbar: Scrollbar,

        const top_pad: u31 = 10;
        const left_pad: u31 = 10;

        const Self = @This();

        pub fn init(layout: Layout(ActionType), scrollbar_style: *const gui.scrollbar.Style, squircle_renderer: *const SquircleRenderer) Self {
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

            return self.layout.dispatchInput(self.layoutBounds(bounds), input_state).action;
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
            return self.layout.contentHeight() + top_pad;
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

pub fn Layout(comptime ActionType: type) type {
    return struct {
        cursor: Cursor = .{},
        items: std.ArrayListUnmanaged(LayoutItem) = .{},
        item_pad: u31,
        focused_id: ?usize = null,
        max_width: u31 = 0,

        const LayoutItem = struct {
            widget: Widget(ActionType),
            bounds: PixelBBox,
        };
        const Self = @This();

        const widget_vtable = Widget(ActionType).VTable{
            .deinit = Self.widgetDeinit,
            .render = Self.widgetRender,
            .getSize = Self.widgetGetSize,
            .update = Self.widgetUpdate,
            .setInputState = Self.widgetSetInputState,
        };

        pub fn deinit(self: *Self, alloc: Allocator) void {
            for (self.items.items) |item| {
                item.widget.deinit(alloc);
            }
            self.items.deinit(alloc);
        }

        fn widgetDeinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.deinit(alloc);
            alloc.destroy(self);
        }

        pub fn pushOrDeinitWidget(self: *Self, alloc: Allocator, widget: Widget(ActionType)) !void {
            errdefer widget.deinit(alloc);
            const size = widget.getSize();
            const bounds = self.cursor.apply(size, self.item_pad);

            try self.items.append(alloc, .{ .bounds = bounds, .widget = widget });
            self.max_width = @max(self.max_width, bounds.calcWidth());
        }

        pub fn toWidget(self: Self, alloc: Allocator) !Widget(ActionType) {
            const ctx = try alloc.create(Layout(ActionType));
            ctx.* = self;
            return .{
                .ctx = ctx,
                .vtable = &widget_vtable,
            };
        }

        pub fn update(self: *Self, container_size: PixelSize) !void {
            self.cursor = .{};

            var max_width: u31 = 0;

            for (self.items.items) |*item| {
                try item.widget.update(self.availableSize(container_size));
                const widget_size = item.widget.getSize();
                item.bounds = self.cursor.apply(widget_size, self.item_pad);
                max_width = @max(max_width, widget_size.width);
            }

            self.max_width = max_width;
        }

        fn widgetUpdate(ctx: ?*anyopaque, container_size: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.update(container_size);
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

        pub fn dispatchInput(self: *Self, bounds: PixelBBox, input_state: InputState) gui.InputResponse(ActionType) {
            var ret = gui.InputResponse(ActionType) {
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
                const input_response = item.widget.setInputState(child_bounds, input_state);

                if (input_response.wants_focus) {
                    if (self.focused_id) |id| {
                        self.items.items[id].widget.setFocused(false);
                    }
                    self.focused_id = idx;
                    // FIXME: layout needs to check if it is focused as well
                    // This should be self.focused && widget focus or something
                    if (self.focused_id) |id| {
                        self.items.items[id].widget.setFocused(true);
                    }
                    ret.wants_focus = true;
                }

                if (input_response.action) |action| {
                    ret.action = action;
                }
            }

            return ret;
        }

        fn widgetSetInputState(ctx: ?*anyopaque, bounds: PixelBBox, input_state: InputState) gui.InputResponse(ActionType) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.dispatchInput(bounds, input_state);
        }

        pub fn render(self: *Self, bounds: PixelBBox, window_bounds: PixelBBox) void {
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

        fn widgetRender(ctx: ?*anyopaque, bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.render(bounds, window_bounds);
        }

        pub fn contentHeight(self: Self) u31 {
            return self.cursor.y;
        }

        pub fn contentSize(self: Self) PixelSize {
            return PixelSize{
                .width = self.max_width,
                .height = self.contentHeight(),
            };
        }

        fn widgetGetSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.contentSize();
        }
    };
}
