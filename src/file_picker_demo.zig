const std = @import("std");
const sphalloc = @import("sphalloc");
const sphmath = @import("sphmath");
const sphrender = @import("sphrender");
const sphwindow = @import("sphwindow");
const sphui = @import("sphui");
const sphtext = @import("sphtext");
const sphutil = @import("sphutil");
const StbImage = @import("sphimp/StbImage.zig");
const gl = sphrender.gl;

const UiAction = union(enum) {
    open: usize,
};

const StringSegmentedListFormatter = struct {
    list: *const sphutil.RuntimeSegmentedList(u8),

    pub fn init(list: *const sphutil.RuntimeSegmentedList(u8)) StringSegmentedListFormatter {
        return .{
            .list = list,
        };
    }

    pub fn format(self: StringSegmentedListFormatter, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        var it = self.list.sliceIter();
        while (it.next()) |slice| {
            try writer.writeAll(slice);
        }
    }

};


const FilePicker = struct {
    alloc: *sphalloc.Sphalloc,
    path: std.BoundedArray(u8, std.fs.max_path_bytes),
    contents: []Entry = &.{},

    fn init(alloc: *sphalloc.Sphalloc) !FilePicker {
        var path = std.BoundedArray(u8, std.fs.max_path_bytes){};
        try path.appendSlice(".");
        return .{
            .path = path,
            .alloc = try alloc.makeSubAlloc("file_picker"),
        };
    }

    fn makeWidget(self: *FilePicker, alloc: sphui.GuiAlloc, file_picker_shared: *const FilePickerShared) !sphui.Widget(UiAction) {
        const ctx = try alloc.heap.arena().create(FilePickerWidget(*FilePicker));
        ctx.* = .{
            .retriever = self,
            .text_alloc = try alloc.makeSubAlloc("file picker contents"),
            .shared = file_picker_shared,
        };

        return ctx.asWidget();
    }

    fn open(self: *FilePicker, idx: usize, scratch: *sphalloc.ScratchAlloc) !void {
        try self.path.append(std.fs.path.sep);
        try self.path.appendSlice(self.contents[idx].name);
        try self.updateContents(scratch);
    }

    fn numEntries(self: FilePicker) usize {
        return self.contents.len;
    }

    const Entry = struct {
        kind: std.fs.Dir.Entry.Kind,
        name: []const u8,
    };

    fn getEntry(self: FilePicker, idx: usize) Entry {
        return self.contents[idx];
    }

    fn updateContents(self: *FilePicker, scratch: *sphalloc.ScratchAlloc) !void {
        const checkpoint = scratch.checkpoint();
        defer scratch.restore(checkpoint);

        try self.alloc.reset();
        const arena = self.alloc.arena();
        self.contents = &.{};

        var scratch_entries = try std.ArrayList(Entry).initCapacity(scratch.allocator(), 100);

        const dir = try std.fs.cwd().openDir(self.path.slice(), .{.iterate = true });
        var it = dir.iterate();
        while (try it.next()) |entry| {
            try scratch_entries.append(.{
                .kind = entry.kind,
                .name = try arena.dupe(u8, entry.name),
            });
        }

        self.contents = try arena.alloc(Entry, scratch_entries.items.len);
        @memcpy(self.contents, scratch_entries.items);
    }
};

fn DirEntryToText(comptime ContentRetriever: type) type {
    return struct {
        idx: usize,
        retriever: ContentRetriever,

        const Self = @This();

        pub fn getText(self: Self) []const u8 {
            return self.retriever.getEntry(self.idx).name;
        }
    };
}

const FilePickerShared = struct {
    folder_icon: sphrender.Texture,
    file_icon: sphrender.Texture,
    unknown_icon: sphrender.Texture,
    icon_renderer: sphrender.xyuvt_program.Program(sphrender.xyuvt_program.ImageSamplerUniforms),
    icon_buffer: sphrender.xyuvt_program.Buffer,
    item_height: u31,
    gui_text_shared: *const sphui.gui_text.SharedState,

    pub fn init(
        alloc: *sphrender.GlAlloc,
        file_icon_rgba: []const u8,
        folder_icon_rgba: []const u8,
        unknown_icon_rgba: []const u8,
        item_height: u31,
        gui_text_shared: *const sphui.gui_text.SharedState,
    ) !FilePickerShared {
        const file_icon = try sphrender.makeTextureFromRgba(alloc, file_icon_rgba, 32);
        const folder_icon = try sphrender.makeTextureFromRgba(alloc, folder_icon_rgba, 32);
        const unknown_icon = try sphrender.makeTextureFromRgba(alloc, unknown_icon_rgba, 32);
        const icon_renderer = try sphrender.xyuvt_program.Program(sphrender.xyuvt_program.ImageSamplerUniforms).init(alloc, sphrender.xyuvt_program.image_sampler_frag);

        return .{
            .file_icon = file_icon,
            .folder_icon = folder_icon,
            .unknown_icon = unknown_icon,
            .icon_renderer = icon_renderer,
            .icon_buffer = try icon_renderer.makeFullScreenPlane(alloc),
            .item_height = item_height,
            .gui_text_shared = gui_text_shared,
        };

    }
};

pub fn FilePickerWidget(comptime ContentRetriever: type) type {
    return struct {
        size: sphui.PixelSize = .{ .width = 0, .height = 0 },
        retriever: ContentRetriever,
        text_alloc: sphui.GuiAlloc,
        gui_texts: []sphui.gui_text.GuiText(DirEntryToText(ContentRetriever)) = &.{},
        shared: *const FilePickerShared,

        const widget_vtable = sphui.Widget(UiAction).VTable {
            .render = Self.render,
            .getSize = Self.getSize,
            .update = Self.update,
            .setInputState = Self.setInputState,
            .setFocused = null,
            .reset = null,
        };

        const Self = @This();

        fn asWidget(self: *Self) sphui.Widget(UiAction) {
            return .{
                .ctx = self,
                .name = "file picker",
                .vtable = &widget_vtable,
            };
        }

        fn render(ctx: ?*anyopaque, widget_bounds: sphui.PixelBBox, window_bounds: sphui.PixelBBox) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            for (self.gui_texts, 0..) |text, i| {
                const size = text.size();
                const text_area = getTextArea(@intCast(i), widget_bounds, self.shared.item_height, size.width);
                const text_bounds = sphui.util.centerBoxInBounds(size, text_area);

                const icon_bounds = getIconArea(@intCast(i), widget_bounds, self.shared.item_height);

                std.debug.print("Rendering item {d} {s} {any}\n", .{
                    i, StringSegmentedListFormatter.init(&text.text), text_bounds,
                });
                text.render(sphui.util.widgetToClipTransform(text_bounds, window_bounds));

                const kind = self.retriever.getEntry(i).kind;
                const icon = switch(kind) {
                    .directory => self.shared.folder_icon,
                    .file => self.shared.file_icon,
                    else => self.shared.unknown_icon,
                };

                self.shared.icon_renderer.render(self.shared.icon_buffer, .{
                    .input_image = icon,
                    .transform = sphui.util.widgetToClipTransform(icon_bounds, window_bounds).inner,
                });
            }
        }

        fn getTextArea(idx: u31, widget_bounds: sphui.PixelBBox, item_height: u31, text_width: u31) sphui.PixelBBox {
            return sphui.PixelBBox{
                .left = widget_bounds.left + item_height,
                .right = widget_bounds.left + text_width + item_height,
                .top = idx * item_height,
                .bottom = (idx + 1) * item_height,
            };
        }

        fn getIconArea(idx: u31, widget_bounds: sphui.PixelBBox, item_height: u31) sphui.PixelBBox {
            return sphui.PixelBBox{
                .left = widget_bounds.left,
                .right = widget_bounds.left + item_height,
                .top = idx * item_height,
                .bottom = (idx + 1) * item_height,
            };
        }

        fn getSize(ctx: ?*anyopaque) sphui.PixelSize {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return self.size;
        }

        fn update(ctx: ?*anyopaque, available_size: sphui.PixelSize) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.size = available_size;

            const num_entries = self.retriever.numEntries();
            if (self.gui_texts.len != num_entries) {
                try self.text_alloc.reset();
                self.gui_texts = &.{};

                const new_texts = try self.text_alloc.heap.arena().alloc(sphui.gui_text.GuiText(DirEntryToText(ContentRetriever)), num_entries);

                for (0..num_entries) |i| {
                    const text_retriever = DirEntryToText(ContentRetriever) {
                        .idx = i,
                        .retriever = self.retriever,
                    };

                    new_texts[i] = try sphui.gui_text.guiText(
                        self.text_alloc,
                        self.shared.gui_text_shared,
                        text_retriever
                    );
                }

                self.gui_texts = new_texts;
            }

            for (self.gui_texts) |*text| {
                try text.update(available_size.width);
            }
        }

        fn setInputState(ctx: ?*anyopaque, widget_bounds: sphui.PixelBBox, input_bounds: sphui.PixelBBox, input_state: sphui.InputState) sphui.InputResponse(UiAction) {
            const self: *Self = @ptrCast(@alignCast(ctx));

            const null_action = sphui.InputResponse(UiAction){
                    .wants_focus = false,
                    .action = null,
                };
            if (!input_state.mouse_pressed) {
                return  null_action;
            }

            for (0..self.gui_texts.len) |i| {
                const text_bounds = getTextArea(@intCast(i), widget_bounds, self.shared.item_height, self.gui_texts[i].size().width);
                const icon_bounds = getIconArea(@intCast(i), widget_bounds, self.shared.item_height);
                const item_bounds = text_bounds.calcUnion(icon_bounds).calcIntersection(input_bounds);

                if (item_bounds.containsOptMousePos(input_state.mouse_down_location)) {
                    return .{
                        .wants_focus = false,
                        .action = .{ .open = i },
                    };
                }
            }

            return null_action;
        }
    };
}

fn makeTable(widget_factory: *const sphui.widget_factory.WidgetFactory(UiAction)) !*sphui.table.Table(UiAction, []const u8) {
    const table = try widget_factory.makeTable([]const u8, &.{"column 1", "column 2"}, 100, 10000);
    const arena = widget_factory.alloc.heap.arena();
    for (0..50) |i| {
        const label1 = try widget_factory.makeLabel(
            try std.fmt.allocPrint(
                arena,
                "Col 1 {d}",
                .{i}
            )
        );

        const label2 = try widget_factory.makeLabel(
            try std.fmt.allocPrint(
                arena,
                "Col 2 {d}",
                .{i}
            )
        );

        try table.pushRow(&.{label1, label2});
    }
    return table;
}

pub fn main() !void {
    var tpa = sphalloc.TinyPageAllocator(100){
        .page_allocator = std.heap.page_allocator,
    };

    var root_alloc: sphalloc.Sphalloc = undefined;
    try root_alloc.initPinned(tpa.allocator(), "root");

    var gl_alloc = try sphrender.GlAlloc.init(&root_alloc);
    const scratch_gl = try gl_alloc.makeSubAlloc(&root_alloc);
    const gui_alloc = sphui.GuiAlloc.init(&root_alloc, &gl_alloc);

    const scratch_buf = try root_alloc.arena().alloc(u8, 10 * 1024 * 1024);
    var scratch = sphalloc.ScratchAlloc.init(scratch_buf);

    var window: sphwindow.Window = undefined;
    try window.initPinned("file picker", 800, 600);

    sphrender.gl.glEnable(sphrender.gl.GL_MULTISAMPLE);
    sphrender.gl.glEnable(sphrender.gl.GL_SCISSOR_TEST);
    sphrender.gl.glBlendFunc(sphrender.gl.GL_SRC_ALPHA, sphrender.gl.GL_ONE_MINUS_SRC_ALPHA);
    sphrender.gl.glEnable(sphrender.gl.GL_BLEND);

    const widget_state = try sphui.widget_factory.widgetState(
        UiAction,
        gui_alloc,
        &scratch,
        scratch_gl,
    );

    const widget_factory = widget_state.factory(gui_alloc);

    const table = try makeTable(&widget_factory);

    var file_picker = try FilePicker.init(&root_alloc);
    try file_picker.updateContents(&scratch);

    const file_icon_image = try StbImage.init("src/file.png");
    defer file_icon_image.deinit();

    const folder_icon_image = try StbImage.init("src/folder.png");
    defer folder_icon_image.deinit();

    const unknown_icon_image = try StbImage.init("src/unknown.png");
    defer unknown_icon_image.deinit();

    const file_picker_shared = try FilePickerShared.init(
        gui_alloc.gl,
        file_icon_image.data,
        folder_icon_image.data,
        unknown_icon_image.data,
        // FIXME: Get from somewhere more reasonable
        @intFromFloat(1.5 * @as(f32, @floatFromInt(sphtext.ttf.lineHeightPx(widget_state.ttf, widget_state.text_renderer.point_size)))),
        &widget_state.guitext_state,
    );

    _ = file_picker_shared;

    var gui_runner = try widget_factory.makeRunner(
        table.asWidget(),
    );

    var last = try std.time.Instant.now();
    while (!window.closed()) {
        scratch.reset();
        scratch_gl.reset();

        const now = try std.time.Instant.now();
        defer last = now;

        var delta_s: f32 = @floatFromInt(now.since(last));
        delta_s /= std.time.ns_per_s;

        const window_width, const window_height = window.getWindowSize();

        gl.glClearColor(0.1, 0.1, 0.1, 1.0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        gl.glViewport(0, 0, @intCast(window_width), @intCast(window_height));
        gl.glScissor(0, 0, @intCast(window_width), @intCast(window_height));


        const action = try gui_runner.step(
            delta_s,
            .{
                .width = @intCast(window_width),
                .height = @intCast(window_height),
            },
            &window.queue,
        );

        if (action) |a| {
            switch (a) {
                .open => |idx| {
                    try file_picker.open(idx, &scratch);

                }
            }
        }
        window.swapBuffers();
    }
}
