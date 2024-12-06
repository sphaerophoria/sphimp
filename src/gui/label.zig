const std = @import("std");
const Allocator = std.mem.Allocator;
const sphrender = @import("sphrender");
const sphtext = @import("sphtext");
const TextRenderer = sphtext.TextRenderer;
const ttf_mod = sphtext.ttf;
const gui = @import("gui.zig");
const util = @import("util.zig");
const PixelSize = gui.PixelSize;
const PixelBBox = gui.PixelBBox;
const Widget = gui.Widget;

pub const SharedLabelState = struct {
    text_renderer: *TextRenderer,
    ttf: *const ttf_mod.Ttf,
    distance_field_generator: *const sphrender.DistanceFieldGenerator,
};

pub fn Label(comptime TextRetriever: type) type {
    return struct {
        alloc: Allocator,
        shared: *const SharedLabelState,
        text_retriever: TextRetriever,
        text_hash: u64,
        data: LabelData,

        const LabelData = struct {
            size: PixelSize,
            buffer: TextRenderer.Buffer,
        };

        const Self = @This();

        fn init(
            comptime ActionType: type,
            alloc: Allocator,
            text_retreiver_const: TextRetriever,
            label_state: *const SharedLabelState,
        ) !Widget(ActionType) {
            var text_retreiver = text_retreiver_const;
            const widget_vtable = Widget(ActionType).VTable{
                .render = Self.render,
                .getSize = Self.getSize,
                .deinit = Self.deinit,
                .update = Self.update,
            };

            const label = try alloc.create(Self);
            errdefer alloc.destroy(label);

            const text = text_retreiver.getText();

            const label_data = try makeTextBufferFromText(alloc, label_state, text);
            errdefer label_data.buffer.deinit();

            const text_hash = std.hash_map.hashString(text);

            label.* = .{
                .alloc = alloc,
                .shared = label_state,
                .data = label_data,
                .text_retriever = text_retreiver,
                .text_hash = text_hash,
            };

            return .{
                .vtable = &widget_vtable,
                .ctx = @ptrCast(label),
            };
        }

        fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (comptime util.shouldDeinit(TextRetriever)) {
                self.text_retriever.deinit();
            }
            self.data.buffer.deinit();
            alloc.destroy(self);
        }

        fn update(ctx: ?*anyopaque) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const current_text = self.text_retriever.getText();
            const current_hash = std.hash_map.hashString(current_text);
            if (current_hash == self.text_hash) {
                return;
            }

            const new_data = try makeTextBufferFromText(self.alloc, self.shared, current_text);

            self.data.buffer.deinit();
            self.data = new_data;
            self.text_hash = current_hash;
        }

        fn makeTextBufferFromText(alloc: Allocator, shared_label_state: *const SharedLabelState, text: []const u8) !LabelData {
            const text_layout = try shared_label_state.text_renderer.layoutText(alloc, text, shared_label_state.ttf.*);
            defer text_layout.deinit(alloc);

            const text_buffer = try shared_label_state.text_renderer.makeTextBuffer(alloc, text_layout, shared_label_state.ttf.*, shared_label_state.distance_field_generator.*);
            errdefer text_buffer.deinit();

            return .{
                .size = .{
                    .width = @intCast(text_layout.width()),
                    .height = @intCast(text_layout.height()),
                },
                .buffer = text_buffer,
            };
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.data.size;
        }

        fn render(ctx: ?*anyopaque, bounds: PixelBBox, window: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const transform = util.widgetToClipTransform(bounds, window);

            self.shared.text_renderer.render(self.data.buffer, transform) catch |e| {
                std.log.debug("Failed to render: {any}", .{e});
            };
        }
    };
}

pub fn makeLabel(comptime ActionType: type, alloc: Allocator, text_retreiver: anytype, label_state: *const SharedLabelState) !Widget(ActionType) {
    return Label(@TypeOf(text_retreiver)).init(ActionType, alloc, text_retreiver, label_state);
}
