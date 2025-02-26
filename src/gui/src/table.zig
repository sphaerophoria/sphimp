const std = @import("std");
const Allocator = std.mem.Allocator;
const gui = @import("gui.zig");
const sphalloc = @import("sphalloc");
const Sphalloc = sphalloc.Sphalloc;
const sphutil = @import("sphutil");
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const InputResponse = gui.InputResponse;

// Please sort by column 2
//
// Who are we sorted by

pub const TableStyle = struct {
    item_pad: u31,
    seperator_width: u31,
    header_height: u31,
    header_background: gui.Color,
    seperator_color: gui.Color,
};

pub const TableShared = struct {
    style: TableStyle,
    gui_text_shared: *const gui.gui_text.SharedState,
    scrollbar_style: *const gui.scrollbar.Style,
    squircle_renderer: *const gui.SquircleRenderer,
};


pub fn makeTable(comptime Action: type, comptime HeaderRetriever: type, alloc: gui.GuiAlloc, headers: []const HeaderRetriever, expected_elems: usize, max_elems: usize,
    shared: *const TableShared,
) !*Table(Action, HeaderRetriever) {
    const Self = Table(Action, HeaderRetriever);

    const arena = alloc.heap.arena();
    const ret = try arena.create(Self);

    const table_content = gui.Widget(Action) {
        .ctx = ret,
        .name = "table content",
        .vtable = &Self.content_vtable,
    };

    const scroll_view = try gui.scroll_view.ScrollView(Action).init(
        arena,
        table_content,
        shared.scrollbar_style,
        shared.squircle_renderer,
    );

    const guitext_headers = try arena.alloc(gui.gui_text.GuiText(HeaderRetriever), headers.len);
    for (0..headers.len) |i| {
        guitext_headers[i] = try gui.gui_text.guiText(
            alloc,
            shared.gui_text_shared,
            headers[i],
        );
    }

    ret.* = .{
        .arena = arena,
        .headers = guitext_headers,
        .shared = shared,
        .rows = try sphutil.RuntimeSegmentedList([]gui.Widget(Action)).init(
            arena,
            alloc.heap.block_alloc.allocator(),
            expected_elems,
            max_elems,
        ),
        .scroll_view = scroll_view,
    };
    return ret;
}

pub fn Table(comptime Action: type, comptime HeaderRetriever: type) type {
    return struct {
        arena: Allocator,
        headers: []gui.gui_text.GuiText(HeaderRetriever),
        // Hold these to resize
        rows: sphutil.RuntimeSegmentedList([]gui.Widget(Action)),
        size: PixelSize = .{ .width = 0, .height = 0 },
        content_height: u31 = 0,
        shared: *const TableShared,

        // FIXME: Can we just call a function to do the scroll view stuff?
        scroll_view: gui.Widget(Action),

        const Self = @This();

        const full_vtable = gui.Widget(Action).VTable {
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = null,
            .reset = null,
        };

        const content_vtable = gui.Widget(Action).VTable {
            .render = Self.renderContent,
            .getSize = Self.getContentSize,
            .update = null,
            .setInputState = null,
            .setFocused = null,
            .reset = null,
        };

        // Header content needs to live for lifetime of widget

        // Row content needs to live for lifetime of table, but row does not
        pub fn pushRow(self: *Self, row: []const gui.Widget(Action)) !void {
            if (row.len != self.headers.len) {
                return error.InvalidRow;
            }

            try self.rows.append(try self.arena.dupe(gui.Widget(Action), row));
        }

        pub fn asWidget(self: *Self) gui.Widget(Action) {
            return .{
                .ctx = self,
                .name = "table",
                .vtable = &full_vtable,
            };
        }

        fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const header_bounds = PixelBBox {
                .top = widget_bounds.top,
                .bottom = widget_bounds.top + self.shared.style.header_height,
                .left = widget_bounds.left,
                .right = widget_bounds.right,
            };
            self.shared.squircle_renderer.render(
                self.shared.style.header_background,
                0,
                header_bounds,
                gui.util.widgetToClipTransform(header_bounds, window_bounds),
            );

            const header_width = headerWidth(self.headers.len, widget_bounds.calcWidth(), self.shared.style.item_pad);

            {
                var left: u31 = 0;

                for (self.headers) |elem| {
                    const right = left + header_width;

                    const section_bounds = PixelBBox {
                        .top = widget_bounds.top,
                        .bottom = widget_bounds.top + self.shared.style.header_height,
                        .left = left,
                        .right = right,
                    };

                    const bounds = gui.util.centerBoxInBounds(elem.size(), section_bounds);
                    const txfm = gui.util.widgetToClipTransform(bounds, window_bounds);

                    elem.render(txfm);
                    left += header_width + self.shared.style.item_pad;
                }
            }

            var header_end = header_width;
            const width_diff = self.shared.style.item_pad - self.shared.style.seperator_width;
            for (1..self.headers.len) |_| {
                const left = header_end + width_diff / 2;
                const right = left + self.shared.style.seperator_width;

                const seperator_bounds = PixelBBox {
                    .top = widget_bounds.top,
                    .bottom = widget_bounds.bottom,
                    .left = left,
                    .right = right,

                };

                self.shared.squircle_renderer.render(
                    self.shared.style.seperator_color,
                    0,
                    seperator_bounds,
                    gui.util.widgetToClipTransform(seperator_bounds, window_bounds),
                );

                header_end += self.shared.style.item_pad + header_width;
            }


            // FIXME: Duplicated with update
            const adjusted_bounds: PixelBBox = .{
                .top = self.shared.style.item_pad + self.shared.style.header_height,
                .bottom = widget_bounds.bottom,
                .left = widget_bounds.left,
                .right = widget_bounds.right,
            };
            self.scroll_view.render(adjusted_bounds, window_bounds);
        }

        fn getSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.size;
        }

        fn update(ctx: ?*anyopaque, available_size: PixelSize, delta_s: f32) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const header_width = headerWidth(self.headers.len, available_size.width, self.shared.style.item_pad);
            self.size = available_size;

            for (self.headers) |*elem| {
                try elem.update(header_width);
            }

            var row_it = self.rows.iter();
            var content_height: u31 = 0;
            while (row_it.next()) |row| {
                var row_max_height: u31 = 0;
                for (row.*) |widget| {
                    try widget.update(
                        .{
                            .width = header_width,
                            .height = std.math.maxInt(u31),
                        },
                        delta_s,
                    );
                    row_max_height = @max(row_max_height, widget.getSize().height);
                }

                content_height += row_max_height;
            }

            self.content_height = content_height;

            const adjusted_space: PixelSize = .{
                .width = available_size.width,
                .height = available_size.height - self.shared.style.item_pad - self.shared.style.header_height,
            };
            try self.scroll_view.update(adjusted_space, delta_s);
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(Action) {
            const self: *Self = @ptrCast(@alignCast(ctx));
            // FIXME: Duplicated with update
            const adjusted_bounds: PixelBBox = .{
                .top = self.shared.style.item_pad + self.shared.style.header_height,
                .bottom = widget_bounds.bottom,
                .left = widget_bounds.left,
                .right = widget_bounds.right,
            };
            return self.scroll_view.setInputState(adjusted_bounds, input_bounds, input_state);
        }

        fn renderContent(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            var row_it = self.rows.iter();
            var y_start = widget_bounds.top;

            // FIXME: Clearly not header anymore
            const header_width = headerWidth(self.headers.len, widget_bounds.calcWidth(), self.shared.style.item_pad);

            while (row_it.next()) |row| {
                var row_max_height: u31 = 0;
                var x_start: u31 = 0;
                for (row.*) |widget| {
                    const widget_size = widget.getSize();
                    const bounds = PixelBBox {
                        .left = x_start,
                        .right = x_start + widget_size.width,
                        .top = y_start,
                        .bottom = y_start + widget_size.height,

                    };
                    widget.render(bounds, window_bounds);
                    row_max_height = @max(row_max_height, widget_size.height);
                    x_start += header_width + self.shared.style.item_pad;
                }
                y_start += row_max_height;
            }
        }

        fn getContentSize(ctx: ?*anyopaque) PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return .{ .width = self.size.width, .height = self.content_height };
        }
    };
}

fn headerWidth(num_items: usize, available_width: u31, padding: u31) u31 {
    const num_items_u31: u31 = @intCast(num_items);
    const actual_available = available_width -| padding * (num_items_u31 - 1);
    return actual_available / num_items_u31;
}
