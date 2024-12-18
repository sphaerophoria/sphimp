const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const sphtext = @import("sphtext");
const TextRenderer = sphtext.TextRenderer;
const ttf_mod = sphtext.ttf;
const gui = @import("gui.zig");
const gui_text = @import("gui_text.zig");
const util = @import("util.zig");
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const Widget = gui.Widget;

pub fn Label(comptime TextRetriever: type) type {
    return struct {
        alloc: Allocator,
        text: gui_text.GuiText(TextRetriever),

        const Self = @This();

        fn init(
            comptime Action: type,
            alloc: Allocator,
            text_retreiver: TextRetriever,
            wrap_width: u31,
            shared: *const gui_text.SharedState,
        ) !Widget(Action) {
            const widget_vtable = Widget(Action).VTable{
                .render = Self.render,
                .getSize = Self.getSize,
                .deinit = Self.deinit,
                .update = Self.update,
            };

            const label = try alloc.create(Self);
            errdefer alloc.destroy(label);

            const inner = try gui_text.guiText(alloc, shared, text_retreiver, wrap_width);

            label.* = .{
                .alloc = alloc,
                .text = inner,
            };

            return .{
                .vtable = &widget_vtable,
                .ctx = @ptrCast(label),
            };
        }

        fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            self.text.deinit(alloc);
            alloc.destroy(self);
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try self.text.update(self.alloc, available_size.width);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.text.size();
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const transform = util.widgetToClipTransform(bounds, window);
            self.text.render(transform);
        }
    };
}

pub fn makeLabel(comptime Action: type, alloc: Allocator, text_retreiver: anytype, wrap_width: u31, shared: *const gui_text.SharedState) !Widget(Action) {
    return Label(@TypeOf(text_retreiver)).init(Action, alloc, text_retreiver, wrap_width, shared);
}
