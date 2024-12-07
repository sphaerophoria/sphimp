const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("sphmath");
const sphrender = @import("sphrender");
const label_mod = @import("label.zig");
const Label = label_mod.Label;
const gui = @import("gui.zig");
const SquircleRenderer = @import("SquircleRenderer.zig");
const util = @import("util.zig");
const InputState = gui.InputState;
const Color = gui.Color;
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const Widget = gui.Widget;
const SharedLabelState = label_mod.SharedLabelState;

// FIXME: Button is not button. This happens to be exactly what we need for
// drag value... unsure if that means copy paste or not...
pub const SharedButtonState = struct {
    squircle_renderer: *const SquircleRenderer,
    label_state: *const SharedLabelState,
    style: ButtonStyle,

    pub fn render(self: SharedButtonState, color: Color, widget_bounds: PixelBBox, transform: sphmath.Transform) void {
        self.squircle_renderer.render(color, self.style.corner_radius, widget_bounds, transform);
    }
};

pub const ButtonStyle = struct {
    padding: u31,
    default_color: Color,
    hover_color: Color,
    click_color: Color,
    corner_radius: f32 = 20.0,
    desired_width: ?u31 = null,
    desired_height: ?u31 = null,
};

pub fn Button(comptime ActionType: type) type {
    return struct {
        size: PixelSize,
        label: Widget(ActionType),

        click_action: ActionType,

        default_color: Color,
        hover_color: Color,
        click_color: Color,

        shared: *const SharedButtonState,

        state: enum {
            none,
            hovered,
            clicked,
        } = .none,

        const Self = @This();

        const widget_vtable = Widget(ActionType).VTable{
            .deinit = Self.deinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .setInputState = Self.setInputState,
            .update = Self.update,
        };

        pub fn init(
            alloc: Allocator,
            text_retriever: anytype,
            shared: *const SharedButtonState,
            click_action: ActionType,
        ) !Widget(ActionType) {
            const label = try label_mod.makeLabel(ActionType, alloc, text_retriever, std.math.maxInt(u31), shared.label_state);
            errdefer label.deinit(alloc);

            const label_size = label.getSize();

            const min_width = label_size.width + shared.style.padding;
            const min_height = label_size.height + shared.style.padding;

            const width = if (shared.style.desired_width != null and shared.style.desired_width.? > min_width)
                shared.style.desired_width.?
            else
                min_width;

            const height = if (shared.style.desired_height != null and shared.style.desired_height.? > min_height)
                shared.style.desired_height.?
            else
                min_height;

            const size = PixelSize{
                .width = width,
                .height = height,
            };

            const button = try alloc.create(Self);
            button.* = .{
                .size = size,
                .label = label,
                .click_action = click_action,
                .click_color = shared.style.click_color,
                .default_color = shared.style.default_color,
                .hover_color = shared.style.hover_color,
                .shared = shared,
            };

            return .{
                .vtable = &Self.widget_vtable,
                .ctx = @ptrCast(button),
            };
        }

        fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.label.deinit(alloc);
            alloc.destroy(self);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.size;
        }

        fn update(ctx: ?*anyopaque, _: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.label.update(.{
                .width = std.math.maxInt(u31),
                .height = std.math.maxInt(u31),
            });
        }

        fn setInputState(ctx: ?*anyopaque, bounds: PixelBBox, input_state: InputState) ?ActionType {
            const self: *Self = @ptrCast(@alignCast(ctx));

            var ret: ?ActionType = null;

            const mouse_down_in_box = mouseDownInBox(input_state, bounds);
            const cursor_in_box = bounds.containsMousePos(input_state.mouse_pos);

            if (mouse_down_in_box and cursor_in_box) {
                self.state = .clicked;

                if (input_state.mouse_released) {
                    ret = self.click_action;
                }
            } else if (cursor_in_box) {
                self.state = .hovered;
            } else {
                self.state = .none;
            }

            return ret;
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const color = switch (self.state) {
                .none => self.default_color,
                .hovered => self.hover_color,
                .clicked => self.click_color,
            };

            const transform = util.widgetToClipTransform(bounds, window);
            self.shared.render(color, bounds, transform);

            const label_bounds = util.centerBoxInBounds(self.label.getSize(), bounds);

            self.label.render(label_bounds, window);
        }

        fn mouseDownInBox(input_state: InputState, bounds: PixelBBox) bool {
            const loc = input_state.mouse_down_location orelse return false;
            return bounds.containsMousePos(loc);
        }
    };
}

pub fn makeButton(
    comptime ActionType: type,
    alloc: Allocator,
    text_retriever: anytype,
    shared: *const SharedButtonState,
    click_action: anytype,
) !Widget(ActionType) {
    return Button(ActionType).init(alloc, text_retriever, shared, click_action);
}
