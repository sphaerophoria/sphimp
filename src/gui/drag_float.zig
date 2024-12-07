const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const util = @import("util.zig");
const label_mod = @import("label.zig");
const button = @import("button.zig");
const SquircleRenderer = @import("SquircleRenderer.zig");
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const Color = gui.Color;
const Widget = gui.Widget;
const InputState = gui.InputState;
const SharedLabelState = label_mod.SharedLabelState;

pub const DragFloatStyle = struct {
    size: PixelSize,
    default_color: Color,
    hover_color: Color,
    active_color: Color,
    corner_radius: f32 = 1.0,
};

pub fn DragFloat(comptime ValRetriever: type, comptime ActionGenerator: type) type {
    const ActionType = util.ReturnType(ActionGenerator.generate);
    return struct {
        val_retriever: ValRetriever,
        label: Widget(ActionType),
        drag_generator: ActionGenerator,
        style: DragFloatStyle,
        squircle_renderer: *const SquircleRenderer,
        state: union(enum) {
            default,
            hovered,
            dragging: f32,
        } = .default,

        const Self = @This();

        const widget_vtable = Widget(ActionType).VTable{
            .deinit = Self.deinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .setInputState = Self.setInputState,
            .update = Self.update,
        };

        const LabelAdapter = struct {
            val_retriever: ValRetriever,
            buf: [10]u8 = undefined,

            pub fn getText(self: *LabelAdapter) []const u8 {
                const text = std.fmt.bufPrint(&self.buf, "{d:.03}", .{self.val_retriever.getVal()}) catch return &.{};
                return text;
            }
        };

        pub fn init(alloc: Allocator, val_retriever: ValRetriever, on_drag: ActionGenerator, style: DragFloatStyle, label_state: *const SharedLabelState, squircle_renderer: *const SquircleRenderer) !Widget(ActionType) {
            const label = try gui.label.makeLabel(
                ActionType,
                alloc,
                LabelAdapter{ .val_retriever = val_retriever },
                std.math.maxInt(u31),
                label_state,
            );

            const drag_float = try alloc.create(Self);
            errdefer alloc.destroy(drag_float);

            drag_float.* = .{
                .val_retriever = val_retriever,
                .label = label,
                .drag_generator = on_drag,
                .style = style,
                .squircle_renderer = squircle_renderer,
            };

            errdefer label.deinit(alloc);

            drag_float.label = label;

            return .{
                .vtable = &widget_vtable,
                .ctx = @ptrCast(drag_float),
            };
        }

        pub fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.label.deinit(alloc);
            alloc.destroy(self);
        }

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const color = switch (self.state) {
                .dragging => self.style.active_color,
                .hovered => self.style.hover_color,
                .default => self.style.default_color,
            };

            const transform = util.widgetToClipTransform(widget_bounds, window_bounds);
            self.squircle_renderer.render(color, self.style.corner_radius, widget_bounds, transform);

            const label_bounds = util.centerBoxInBounds(self.label.getSize(), widget_bounds);
            self.label.render(label_bounds, window_bounds);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.style.size;
        }

        pub fn update(ctx: ?*anyopaque, _: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.label.update(.{
                .width = std.math.maxInt(u31),
                .height = std.math.maxInt(u31),
            });
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_state: InputState) ?ActionType {
            const self: *Self = @ptrCast(@alignCast(ctx));

            var ret: ?ActionType = null;

            if (input_state.mouse_down_location) |down_loc| {
                if (widget_bounds.containsMousePos(down_loc)) {
                    if (self.state != .dragging) {
                        self.state = .{ .dragging = self.val_retriever.getVal() };
                    }

                    const offs = input_state.mouse_pos.x - down_loc.x;

                    const start_val = self.state.dragging;
                    ret = self.drag_generator.generate(start_val + offs * 0.01);
                }
            } else if (widget_bounds.containsMousePos(input_state.mouse_pos)) {
                self.state = .hovered;
            } else {
                self.state = .default;
            }

            return ret;
        }
    };
}

pub fn makeWidget(
    alloc: Allocator,
    val_retriever: anytype,
    on_drag: anytype,
    style: DragFloatStyle,
    label_state: *const SharedLabelState,
    squircle_renderer: *const SquircleRenderer,
) !Widget(util.ReturnType(@TypeOf(on_drag).generate)) {
    return DragFloat(@TypeOf(val_retriever), @TypeOf(on_drag)).init(
        alloc,
        val_retriever,
        on_drag,
        style,
        label_state,
        squircle_renderer,
    );
}
