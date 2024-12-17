const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const gui_text = @import("gui_text.zig");
const util = @import("util.zig");
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const Widget = gui.Widget;
const SquircleRenderer = @import("SquircleRenderer.zig");

pub const Style = struct {
    active_color: gui.Color,
    highlight_color: gui.Color,
    hover_color: gui.Color,
    background_color: gui.Color,
    corner_radius: f32,
    item_pad: u31,
    // FIXME: remove
    width: u31,
    min_item_height: u31,
};

pub const SharedState = struct {
    gui_state: *const gui_text.SharedState,
    squircle_renderer: *const SquircleRenderer,
    style: Style,
};

pub fn selectableList(comptime ActionType: type, alloc: Allocator, retriever: anytype, generator: anytype, shared: *const SharedState) !Widget(ActionType) {
    const S = SelectableList(ActionType, @TypeOf(retriever), @TypeOf(generator));

    const ret = try alloc.create(S);
    errdefer alloc.destroy(ret);

    var item_labels = std.ArrayListUnmanaged(S.TextItem){};
    errdefer freeTextItems(S.TextItem, alloc, &item_labels);

    const num_items = retriever.numItems();
    for (0..num_items) |i| {
        const text = try gui_text.guiText(alloc, shared.gui_state, labelAdaptor(retriever, i), shared.style.width);
        errdefer text.deinit(alloc);

        try item_labels.append(alloc, text);
    }

    ret.* = .{
        .alloc = alloc,
        .retriever = retriever,
        .parent_width = shared.style.width,
        .action_generator = generator,
        .item_labels = item_labels,
        .shared = shared,
    };

    return .{
        .vtable = &S.widget_vtable,
        .ctx = ret,
    };
}

pub fn SelectableList(comptime ActionType: type, comptime Retriever: type, comptime GenerateSelect: type) type {
    return struct {
        alloc: Allocator,
        retriever: Retriever,
        action_generator: GenerateSelect,
        item_labels: std.ArrayListUnmanaged(TextItem),
        parent_width: u31,
        shared: *const SharedState,
        hover_idx: ?usize = null,
        click_idx: ?usize = null,

        debounce_state: enum {
            clicked,
            released,
        } = .released,


        const TextItem = gui_text.GuiText(LabelAdaptor(Retriever));
        const Self = @This();

        const widget_vtable = Widget(ActionType).VTable{
            .deinit = Self.deinit,
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
        };

        fn deinit(ctx: ?*anyopaque, alloc: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            freeTextItems(TextItem, alloc, &self.item_labels);
            alloc.destroy(self);
        }

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const selected = self.retriever.selectedId();

            const squircle_renderer = ListSquircleRenderer{ .shared = self.shared, .window_bounds = window_bounds };
            squircle_renderer.render(widget_bounds, self.shared.style.background_color);

            var label_bounds_it = LabelBoundsIt.init(widget_bounds, &self.shared.style, self.item_labels.items);
            while (label_bounds_it.next()) |item| {
                if (item.idx == self.click_idx) {
                    squircle_renderer.render(item.full_bounds, self.shared.style.active_color);
                } else if (item.idx == self.hover_idx) {
                    squircle_renderer.render(item.full_bounds, self.shared.style.hover_color);
                } else if (item.idx == selected) {
                    squircle_renderer.render(item.full_bounds, self.shared.style.highlight_color);
                }

                const transform = util.widgetToClipTransform(item.label_bounds, window_bounds);
                item.item.render(transform);
            }
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const widget_bounds = PixelBBox{
                .left = 0,
                .top = 0,
                .bottom = std.math.maxInt(i32),
                .right = self.parent_width,
            };

            var it = LabelBoundsIt.init(widget_bounds, &self.shared.style, self.item_labels.items);

            while (it.next()) |_| {}

            return .{
                .width = self.parent_width,
                .height = @intCast(@max(it.y_offs, self.shared.style.min_item_height)),
            };
        }

        fn update(ctx: ?*anyopaque, available_space: PixelSize) !void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const num_items = self.retriever.numItems();

            self.parent_width = available_space.width;

            try appendMissingTextItems(TextItem, self.alloc, self.shared, self.retriever, &self.item_labels, num_items, self.parent_width);
            removeExtraTextItems(TextItem, self.alloc, &self.item_labels, num_items);

            for (self.item_labels.items) |*item| {
                try item.update(self.alloc, self.parent_width);
            }
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, container_bounds: PixelBBox, input_state: InputState) gui.InputResponse(ActionType) {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const no_action = gui.InputResponse(ActionType){
                .wants_focus = false,
                .action = null,
            };

            var ret = no_action;
            var click_idx: ?usize = null;
            var hover_idx: ?usize = null;

            var label_bounds_it = LabelBoundsIt.init(widget_bounds, &self.shared.style, self.item_labels.items);
            while (label_bounds_it.next()) |item| {
                const clickable_bounds = item.full_bounds.calcIntersection(container_bounds);
                if (self.debounce_state == .released and clickable_bounds.containsOptMousePos(input_state.mouse_down_location)) {
                    ret = .{
                        .wants_focus = false,
                        .action = generateAction(ActionType, &self.action_generator, item.idx),
                    };
                    self.debounce_state = .clicked;
                    click_idx = item.idx;
                } else if (clickable_bounds.containsMousePos(input_state.mouse_pos)) {
                    hover_idx = item.idx;
                }
            }

            if (input_state.mouse_released) {
                self.debounce_state = .released;
            }
            self.click_idx = click_idx;
            self.hover_idx = hover_idx;

            return ret;
        }

        const ListSquircleRenderer = struct {
            shared: *const SharedState,
            window_bounds: PixelBBox,

            fn render(self: ListSquircleRenderer, bounds: PixelBBox, color: gui.Color) void {
                const transform = util.widgetToClipTransform(bounds, self.window_bounds);
                self.shared.squircle_renderer.render(
                    color,
                    self.shared.style.corner_radius,
                    bounds,
                    transform,
                );
            }
        };

        // Iterate GuiText items with their bounds
        const LabelBoundsIt = struct {
            item_labels: []TextItem,
            y_offs: i32,
            widget_left: i32,
            widget_right: i32,
            style: *const Style,
            idx: usize = 0,

            fn init(widget_bounds: PixelBBox, style: *const Style, item_labels: []TextItem) LabelBoundsIt {
                return .{
                    .item_labels = item_labels,
                    .y_offs = widget_bounds.top,
                    .widget_left = widget_bounds.left,
                    .widget_right = widget_bounds.right,
                    .style = style,
                };
            }

            const Output = struct {
                idx: usize,
                item: TextItem,
                label_bounds: PixelBBox,
                full_bounds: PixelBBox,
            };

            fn next(self: *LabelBoundsIt) ?Output {
                if (self.idx >= self.item_labels.len) {
                    return null;
                }
                defer self.idx += 1;

                const item = self.item_labels[self.idx];
                const item_size = item.size();

                const effective_height = @max(item_size.height, self.style.min_item_height) + self.style.item_pad;
                const full_top = self.y_offs;
                const full_bounds = PixelBBox{
                    .top = full_top,
                    .bottom = full_top + effective_height,
                    .right = self.widget_right,
                    .left = self.widget_left,
                };

                const label_center_y: i32 = @intFromFloat(full_bounds.cy());
                const label_top = label_center_y - item_size.height / 2;
                const label_bottom = label_center_y + item_size.height / 2 + item_size.height % 2;
                const label_bounds = PixelBBox{
                    .left = self.widget_left,
                    .right = self.widget_left + item_size.width,
                    .top = label_top,
                    .bottom = label_bottom,
                };

                self.y_offs += effective_height;
                return .{
                    .idx = self.idx,
                    .item = self.item_labels[self.idx],
                    .label_bounds = label_bounds,
                    .full_bounds = full_bounds,
                };
            }
        };
    };
}

fn LabelAdaptor(comptime Retriever: type) type {
    return struct {
        retriever: Retriever,
        idx: usize,

        pub fn getText(self: @This()) []const u8 {
            return self.retriever.getText(self.idx);
        }
    };
}

fn labelAdaptor(retriever: anytype, idx: usize) LabelAdaptor(@TypeOf(retriever)) {
    return .{
        .retriever = retriever,
        .idx = idx,
    };
}

fn freeTextItems(comptime T: type, alloc: Allocator, items: *std.ArrayListUnmanaged(T)) void {
    for (items.items) |item| {
        item.deinit(alloc);
    }
    items.deinit(alloc);
}

fn appendMissingTextItems(
    comptime TextItem: type,
    alloc: Allocator,
    shared: *const SharedState,
    retriever: anytype,
    item_labels: *std.ArrayListUnmanaged(TextItem),
    num_items: usize,
    parent_width: u31,
) !void {
    if (item_labels.items.len >= num_items) {
        return;
    }

    for (item_labels.items.len..num_items) |i| {
        const text = try gui_text.guiText(
            alloc,
            shared.gui_state,
            labelAdaptor(retriever, i),
            parent_width,
        );
        errdefer text.deinit(alloc);

        try item_labels.append(alloc, text);
    }
}

fn removeExtraTextItems(comptime TextItem: type, alloc: Allocator, item_labels: *std.ArrayListUnmanaged(TextItem), num_items: usize) void {
    while (item_labels.items.len > num_items) {
        const item = item_labels.pop();
        item.deinit(alloc);
    }
}

fn generateAction(comptime ActionType: type, action_generator: anytype, idx: usize) ActionType {
    const Ptr = @TypeOf(action_generator);
    const T = @typeInfo(Ptr).Pointer.child;

    switch (@typeInfo(T)) {
        .Struct => {
            if (@hasDecl(T, "generate")) {
                return action_generator.generate(idx);
            }
        },
        .Pointer => |p| {
            switch (@typeInfo(p.child)) {
                .Fn => {
                    return action_generator.*(idx);
                },
                else => {},
            }
        },
        else => {},
    }
}
