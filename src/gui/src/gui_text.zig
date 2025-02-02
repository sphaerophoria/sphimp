const std = @import("std");
const Allocator = std.mem.Allocator;
const sphmath = @import("sphmath");
const gui = @import("gui.zig");
const sphtext = @import("sphtext");
const sphrender = @import("sphrender");
const sphutil = @import("sphutil");
const TypicallySmallList = sphutil.TypicallySmallList;
const PixelSize = gui.PixelSize;
const TextRenderer = sphtext.TextRenderer;
const sphalloc = @import("sphalloc");
const ScratchAlloc = sphalloc.ScratchAlloc;
const GlAlloc = sphrender.GlAlloc;

pub const SharedState = struct {
    // Allocator that can be used for anything that needs to live for the
    // lifetime of all shared state
    alloc: Allocator,
    scratch_alloc: *ScratchAlloc,
    scratch_gl: *GlAlloc,
    text_renderer: *TextRenderer,
    ttf: *const sphtext.ttf.Ttf,
    distance_field_generator: *const sphrender.DistanceFieldGenerator,
};

pub fn guiText(alloc: gui.GuiAlloc, shared: *const SharedState, text_retriever_const: anytype) !GuiText(@TypeOf(text_retriever_const)) {
    // Ideally we don't layout now, because the layout is likely going to
    // change when we put whatever widget we are rendering in into whatever
    // container it belongs to.
    //
    // Its convenient for users of us to have a valid layout though, so we just
    // layout nothing for now
    const text_layout = TextRenderer.TextLayout.empty;

    const text_buffer = try shared.text_renderer.program.makeFullScreenPlane(alloc.gl);

    const text = try TypicallySmallList(u8).init(
        alloc.heap.arena(),
        alloc.heap.block_alloc.allocator(),
        150,
        1 << 20,
    );

    return .{
        .alloc = alloc,
        .layout = text_layout,
        .text = text,
        .buffer = text_buffer,
        .shared = shared,
        .text_retriever = text_retriever_const,
    };
}

pub fn GuiText(comptime TextRetriever: type) type {
    return struct {
        alloc: gui.GuiAlloc,
        // FIXME: LinkedArraysList with page freeing
        layout: TextRenderer.TextLayout,
        buffer: TextRenderer.Buffer,
        text: TypicallySmallList(u8),
        wrap_width: u31 = 0,
        shared: *const SharedState,

        text_retriever: TextRetriever,

        const Self = @This();

        pub fn update(self: *Self, wrap_width: u31) !void {
            if (self.wrap_width != wrap_width) {
                try self.regenerate(wrap_width);
                return;
            }

            const new_text = getText(&self.text_retriever);
            if (!self.text.contentMatches(new_text)) {
                try self.regenerate(wrap_width);
                return;
            }
        }

        pub fn size(self: Self) PixelSize {
            return .{
                .width = @intCast(self.layout.width()),
                .height = @intCast(self.layout.height()),
            };
        }

        pub fn render(self: Self, transform: sphmath.Transform) void {
            // FIXME: Render a baseline. We could probably adjust our size so
            // that it always reports the min/max height of a char to get
            // consistent layout, then find the baseline relative to that area
            //
            // Baseline location can use the max ascent/descent metrics
            self.shared.text_renderer.render(self.buffer, transform);
        }

        pub fn getNextText(self: *Self) []const u8 {
            return getText(&self.text_retriever);
        }

        fn regenerate(self: *Self, wrap_width: u31) !void {
            const text = getText(&self.text_retriever);
            const text_layout = try self.shared.text_renderer.layoutText(
                self.alloc.heap.general(),
                text,
                self.shared.ttf.*,
                wrap_width,
            );
            errdefer text_layout.deinit(self.alloc.heap.general());

            try self.shared.text_renderer.updateTextBuffer(
                // FIXME: As we render text, the glyph atlas needs to update
                // its internal storage for where individual glyphs are. This
                // is a shared resource between all gui texts, so we use the
                // shared allocator
                //
                // FIXME: Surely managing all of this externally is not worth
                // the 16 bytes we save in the text renderer
                self.shared.alloc,
                self.shared.scratch_alloc,
                self.shared.scratch_gl,
                text_layout,
                self.shared.ttf.*,
                self.shared.distance_field_generator.*,
                &self.buffer,
            );

            self.layout.deinit(self.alloc.heap.general());

            self.layout = text_layout;
            try self.text.setContents(text);
            self.wrap_width = wrap_width;
        }
    };
}

fn getText(text_retriever: anytype) []const u8 {
    const Ptr = @TypeOf(text_retriever);
    const T = @typeInfo(Ptr).Pointer.child;

    switch (@typeInfo(T)) {
        .Struct => {
            if (@hasDecl(T, "getText")) {
                return text_retriever.getText();
            }
        },
        .Pointer => |p| {
            if (p.child == u8 and p.size == .Slice) {
                return text_retriever.*;
            }

            const child_info = @typeInfo(p.child);
            if (child_info == .Array and child_info.Array.child == u8) {
                return text_retriever.*;
            }

            if (child_info == .Pointer and child_info.Pointer.child == u8 and child_info.Pointer.size == .Slice) {
                return text_retriever.*.*;
            }
        },
        else => {},
    }

    @compileError("text_retriever must be a string or have a getText() function, type is " ++ @typeName(T));
}
