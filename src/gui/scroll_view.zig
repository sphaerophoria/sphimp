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
        size: PixelSize,

        scrollbar_present: bool = false,
        scroll_offs: i32 = 0,
        scrollbar: Scrollbar,

        const top_pad: u31 = 10;
        const left_pad: u31 = 10;

        const Self = @This();

        const widget_vtable = Widget(ActionType).VTable{
            .deinit = Self.widgetDeinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = Self.setFocused,
        };

        pub fn init(
            alloc: Allocator,
            layout: Widget(ActionType),
            scrollbar_style: *const gui.scrollbar.Style,
            squircle_renderer: *const SquircleRenderer,
        ) !Widget(ActionType) {
            const view = try alloc.create(Self);
            view.* = .{
                .layout = layout,
                .scrollbar = .{
                    .renderer = squircle_renderer,
                    .style = scrollbar_style,
                },
                .size = .{
                    .width = 0,
                    .height = 0,
                },
            };
            return .{
                .ctx = view,
                .vtable = &widget_vtable,
            };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.layout.deinit(alloc);
            alloc.destroy(self);
        }

        fn widgetDeinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.deinit(alloc);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.size;
        }

        fn update(ctx: ?*anyopaque, window_size: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
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

            self.size = window_size;

            self.scrollbar.bar_ratio =
                @as(f32, @floatFromInt(window_size.height)) /
                @as(f32, @floatFromInt(self.contentHeight()));

            self.scrollbar.top_offs_ratio =
                @as(f32, @floatFromInt(self.scroll_offs)) /
                @as(f32, @floatFromInt(self.contentHeight()));
        }

        // FIXME: container_bounds should already be intersection
        fn setInputState(ctx: ?*anyopaque, bounds: PixelBBox, container_bounds: PixelBBox, input_state: InputState) gui.InputResponse(ActionType) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.scrollbar.handleInput(
                input_state,
                scrollAreaBounds(self.scrollbar, bounds),
            )) |scroll_loc| {
                const content_height: f32 = @floatFromInt(self.contentHeight());
                self.scroll_offs = @intFromFloat(content_height * scroll_loc);
            }

            const clickable_bounds = container_bounds.calcIntersection(bounds);
            if (clickable_bounds.containsMousePos(input_state.mouse_pos)) {
                self.scroll_offs -= @intFromFloat(input_state.frame_scroll * 15);

                self.scroll_offs = std.math.clamp(
                    self.scroll_offs,
                    0,
                    @max(self.contentHeight() - bounds.calcHeight(), 0),
                );
            }

            return self.layout.setInputState(self.layoutBounds(bounds), container_bounds, input_state);
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
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

        fn setFocused(ctx: ?*anyopaque, focused: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.layout.setFocused(focused);
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
