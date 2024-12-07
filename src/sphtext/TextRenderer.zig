const std = @import("std");
const Allocator = std.mem.Allocator;
const GlyphAtlas = @import("GlyphAtlas.zig");
const sphmath = @import("sphmath");
const ttf_mod = @import("ttf.zig");
const sphrender = @import("sphrender");

pub const Buffer = sphrender.PlaneRenderProgram.Buffer;

program: sphrender.PlaneRenderProgram,
glyph_atlas: GlyphAtlas,
point_size: f32,
multiplier: f32 = 0.25,
offset: f32 = 0.0,

const TextRenderer = @This();

pub const TextLayout = struct {
    const GlyphLoc = struct {
        char: u8,
        pixel_x1: i32,
        pixel_x2: i32,
        pixel_y1: i32,
        pixel_y2: i32,
    };

    pub fn deinit(self: TextLayout, alloc: Allocator) void {
        alloc.free(self.glyphs);
    }

    pub fn width(self: TextLayout) u32 {
        return @intCast(self.max_x - self.min_x);
    }

    pub fn height(self: TextLayout) u32 {
        return @intCast(self.max_y - self.min_y);
    }

    glyphs: []GlyphLoc,
    min_x: i32,
    max_x: i32,
    min_y: i32,
    max_y: i32,
};


pub fn init(alloc: Allocator, point_size: f32) !TextRenderer {
    const program = try sphrender.PlaneRenderProgram.init(alloc, sphrender.plane_vertex_shader, text_fragment_shader, TextReservedIndex);
    errdefer program.deinit(alloc);

    const glyph_atlas = try GlyphAtlas.init(alloc);
    errdefer glyph_atlas.deinit(alloc);

    return .{
        .program = program,
        .glyph_atlas = glyph_atlas,
        .point_size = point_size,
    };
}

pub fn deinit(self: *TextRenderer, alloc: Allocator) void {
    self.program.deinit(alloc);
    self.glyph_atlas.deinit(alloc);
}

const LayoutState = enum {
    in_word,
    between_word,
};


const LayoutBox = struct {
    min_x: i32 = 0,
    max_x: i32 = 0,
    min_y: i32 = 0,
    max_y: i32 = 0,
};

pub fn layoutText(self: *TextRenderer, alloc: Allocator, text: []const u8, ttf: ttf_mod.Ttf) !TextLayout {
    var funit_cursor_x: i64 = 0;
    var funit_cursor_y: i64 = 0;
    var layout_box = LayoutBox {};

    const available_width = 400;

    var glyphs = std.ArrayList(TextLayout.GlyphLoc).init(alloc);
    defer glyphs.deinit();

    var word_start: usize = 0;
    var word_start_glyphs_len: usize = 0;
    var layout_word_start: LayoutBox = layout_box;
    var layout_state: LayoutState = .between_word;

    const line_height = ttf_mod.lineHeight(ttf);

    const funit_converter = ttf_mod.FunitToPixelConverter.init(self.point_size, @floatFromInt(ttf.head.units_per_em));
    var c_idx: usize = 0;
    while (c_idx < text.len) {
        const c = text[c_idx];

        if (layout_state == .in_word and std.ascii.isWhitespace(c)) {
            layout_state = .between_word;
        } else if (layout_state == .between_word and !std.ascii.isWhitespace(c)) {
            layout_state = .in_word;
            word_start = c_idx;
            word_start_glyphs_len = glyphs.items.len;
            layout_word_start = layout_box;
        }

        if (c == '\n') {
            c_idx += 1;
            funit_cursor_y -= line_height;
            funit_cursor_x = 0;
            continue;
        }

        const metrics = ttf_mod.metricsForChar(ttf, c);

        const header = ttf_mod.glyphHeaderForChar(ttf, c) orelse {
            c_idx += 1;
            funit_cursor_x += metrics.advance_width;
            continue;
        };
        const x1 = funit_cursor_x + metrics.left_side_bearing;
        const x2 = x1 + header.x_max - header.x_min;

        const y1 = funit_cursor_y + header.y_min;
        const y2 = y1 + header.y_max - header.y_min;

        const x1_px = funit_converter.pixelFromFunit(x1);
        const y1_px = funit_converter.pixelFromFunit(y1);
        // Why not just use x2 or header.y_max? We want to make sure no matter
        // how much the cursor has advanced in funits, we always render the
        // glyph aligned to the same number of pixels.
        const x2_px = x1_px + funit_converter.pixelFromFunit(x2 - x1);
        const y2_px = y1_px + funit_converter.pixelFromFunit(y2 - y1);

        if (x2_px > available_width and funit_cursor_x != 0) {
            std.debug.print("Word starting at {d} is too large\n", .{word_start});
            try glyphs.resize(word_start_glyphs_len);
            c_idx = word_start;
            layout_box = layout_word_start;

            funit_cursor_y -= line_height;
            funit_cursor_x = 0;

            continue;
        }

        funit_cursor_x += metrics.advance_width;

        try glyphs.append(.{
            .char = c,
            .pixel_x1 = x1_px,
            .pixel_x2 = x2_px,
            .pixel_y1 = y1_px,
            .pixel_y2 = y2_px,
        });

        layout_box.min_x = @min(layout_box.min_x, x1_px);
        layout_box.max_x = @max(layout_box.max_x, x2_px);
        layout_box.min_y = @min(layout_box.min_y, y1_px);
        layout_box.max_y = @max(layout_box.max_y, y2_px);
        c_idx += 1;
    }

    return .{
        .glyphs = try glyphs.toOwnedSlice(),
        .min_x = layout_box.min_x,
        .max_x = layout_box.max_x,
        .min_y = layout_box.min_y,
        .max_y = layout_box.max_y,
    };
}

pub fn makeTextBuffer(self: *TextRenderer, alloc: Allocator, text: TextLayout, ttf: ttf_mod.Ttf, distance_field_generator: sphrender.DistanceFieldGenerator) !Buffer {
    const num_points_per_plane = 6;
    const new_buffer_data = try alloc.alloc(sphrender.PlaneRenderProgram.Buffer.BufferPoint, text.glyphs.len * num_points_per_plane);
    defer alloc.free(new_buffer_data);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var buffer_idx: usize = 0;
    for (text.glyphs) |glyph| {
        _ = arena.reset(.retain_capacity);
        defer buffer_idx += num_points_per_plane;

        const uv_loc = try self.glyph_atlas.getGlyphLocation(alloc, arena.allocator(), glyph.char, self.point_size, ttf, distance_field_generator);

        // [0, width] -> [-1, 1]
        const clip_x_start = pixToClip(@intCast(glyph.pixel_x1 - text.min_x), text.width());
        const clip_x_end = pixToClip(@intCast(glyph.pixel_x2 - text.min_x), text.width());
        const clip_y_top = pixToClip(@intCast(glyph.pixel_y2 - text.min_y), text.height());
        const clip_y_bottom = pixToClip(@intCast(glyph.pixel_y1 - text.min_y), text.height());

        const BufferPoint = sphrender.PlaneRenderProgram.Buffer.BufferPoint;

        const bl = BufferPoint{
            .clip_x = clip_x_start,
            .clip_y = clip_y_bottom,
            .uv_x = uv_loc.left,
            .uv_y = uv_loc.bottom,
        };

        const br = BufferPoint{
            .clip_x = clip_x_end,
            .clip_y = clip_y_bottom,
            .uv_x = uv_loc.right,
            .uv_y = uv_loc.bottom,
        };

        const tl = BufferPoint{
            .clip_x = clip_x_start,
            .clip_y = clip_y_top,
            .uv_x = uv_loc.left,
            .uv_y = uv_loc.top,
        };

        const tr = BufferPoint{
            .clip_x = clip_x_end,
            .clip_y = clip_y_top,
            .uv_x = uv_loc.right,
            .uv_y = uv_loc.top,
        };

        new_buffer_data[buffer_idx + 0] = bl;
        new_buffer_data[buffer_idx + 1] = br;
        new_buffer_data[buffer_idx + 2] = tl;
        new_buffer_data[buffer_idx + 3] = br;
        new_buffer_data[buffer_idx + 4] = tl;
        new_buffer_data[buffer_idx + 5] = tr;
    }

    var buf = self.program.makeDefaultBuffer();
    buf.updateBuffer(new_buffer_data);

    return buf;
}

pub fn resetAtlas(self: *TextRenderer, alloc: Allocator) !void {
    const new_atlas = try GlyphAtlas.init(alloc);
    self.glyph_atlas.deinit(alloc);
    self.glyph_atlas = new_atlas;
}

pub fn render(self: TextRenderer, buf: Buffer, transform: sphmath.Transform) !void {
    self.program.render(buf, &.{}, &.{
        .{
            .idx = TextReservedIndex.input_df.asIndex(),
            .val = .{ .image = self.glyph_atlas.texture.inner },
        },
        .{
            .idx = TextReservedIndex.multiplier.asIndex(),
            .val = .{ .float = self.point_size * self.multiplier },
        },
        .{
            .idx = TextReservedIndex.offset.asIndex(),
            .val = .{ .float = self.offset },
        },
    }, transform);
}

pub const TextReservedIndex = enum {
    input_df,
    multiplier,
    offset,

    fn asIndex(self: TextReservedIndex) usize {
        return @intFromEnum(self);
    }
};

fn pixToClip(val: u32, max: u32) f32 {
    const val_f: f32 = @floatFromInt(val);
    const max_f: f32 = @floatFromInt(max);

    return val_f / max_f * 2.0 - 1.0;
}

pub const text_fragment_shader =
    \\#version 330
    \\in vec2 uv;
    \\out vec4 fragment;
    \\uniform sampler2D input_df;
    \\uniform float multiplier = 100.0;
    \\uniform float offset = 0.0;
    \\void main()
    \\{
    \\    float distance = texture(input_df, uv).r;
    \\    float N = 1.0 / multiplier;
    \\    float alpha = smoothstep(-N, N, distance);
    \\    fragment = vec4(1.0, 1.0, 1.0, alpha);
    \\}
;
