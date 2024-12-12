const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const util = @import("util.zig");
const Widget = gui.Widget;
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const InputState = gui.InputState;

pub fn PopupLayer(comptime ActionType: type) type {
    return struct {
        inner: ?Data = null,
        container_size: PixelSize = .{ .width = 0, .height = 0 },

        const Data = struct {
            alloc: Allocator,
            widget: Widget(ActionType),
            x_offs: i32,
            y_offs: i32,
            mouse_released: bool = false,

            fn bounds(self: Data, container_bounds: PixelBBox) PixelBBox {
                const item_size = self.widget.getSize();
                const left = container_bounds.left + self.x_offs;
                const top = container_bounds.top + self.y_offs;

                return .{
                    .left = left,
                    .top = top,
                    .right = left + item_size.width,
                    .bottom = top + item_size.height,
                };

            }
        };

        const widget_vtable = Widget(ActionType).VTable {
            .deinit = Self.widgetDeinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
        };

        const Self = @This();

        pub fn asWidget(self: *Self) Widget(ActionType) {
            return .{
                .ctx = self,
                .vtable = &widget_vtable,
            };
        }

        pub fn widgetDeinit(_: ?*anyopaque, _: Allocator) void {
            // Do nothing because this layer is expected to be longer lived
            // than whatever layout it is fed to
        }

        pub fn reset(self: *Self) void {
            if (self.inner) |*d| d.widget.deinit(d.alloc);
            self.inner = null;
        }

        pub fn set(self: *Self, alloc: Allocator, widget: Widget(ActionType), x_offs: i32, y_offs: i32) void {
            self.reset();
            self.inner = .{
                .alloc = alloc,
                .widget = widget,
                .x_offs = x_offs,
                .y_offs = y_offs,
            };
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.inner) |_| {
                return self.container_size;
            } else {
                return .{ .width = 0, .height = 0 };
            }
        }

        pub fn setInputState(ctx: ?*anyopaque, layer_bounds: PixelBBox, input_state: InputState) gui.InputResponse(ActionType) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const data = if (self.inner) |*i| i else return .{
                .wants_focus = false,
                .action = null,
            };
            const item_bounds = data.bounds(layer_bounds);
            const ret = data.widget.setInputState(item_bounds, input_state);

            if (input_state.mouse_down_location) |loc| {
                if (data.mouse_released and !item_bounds.containsMousePos(loc)) {
                    self.reset();
                }
            }
            data.mouse_released = data.mouse_released or input_state.mouse_released;

            return ret;
        }

        pub fn update(ctx: ?*anyopaque, container_size: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.container_size = container_size;
        }

        pub fn render(ctx: ?*anyopaque, layer_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const data = self.inner orelse return;
            data.widget.render(data.bounds(layer_bounds), window_bounds);
        }
    };
}
