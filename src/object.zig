const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("gl.zig");
const lin = @import("lin.zig");
const Renderer = @import("Renderer.zig");
const StbImage = @import("StbImage.zig");
const ShaderStorage = @import("ShaderStorage.zig");
const coords = @import("coords.zig");

const Transform = lin.Transform;
const Vec3 = lin.Vec3;
const Vec2 = lin.Vec2;
pub const PixelDims = @Vector(2, usize);

pub const Object = struct {
    name: []u8,
    data: Data,

    pub const Data = union(enum) {
        filesystem: FilesystemObject,
        composition: CompositionObject,
        shader: ShaderObject,
        path: PathObject,
        generated_mask: GeneratedMaskObject,
    };

    pub fn deinit(self: *Object, alloc: Allocator) void {
        alloc.free(self.name);
        switch (self.data) {
            .filesystem => |*f| f.deinit(alloc),
            .composition => |*c| c.deinit(alloc),
            .shader => |*s| s.deinit(alloc),
            .path => |*p| p.deinit(alloc),
            .generated_mask => |*g| g.deinit(),
        }
    }

    pub fn save(self: Object) SaveObject {
        const data: SaveObject.Data = switch (self.data) {
            .filesystem => |s| .{ .filesystem = s.source },
            .composition => |c| .{ .composition = c.objects.items },
            .shader => |s| s.save(),
            .path => |p| .{ .path = .{
                .points = p.points.items,
                .display_object = p.display_object.value,
            } },
            .generated_mask => |g| .{
                .generated_mask = g.source.value,
            },
        };

        return .{
            .name = self.name,
            .data = data,
        };
    }

    pub fn load(alloc: Allocator, save_obj: SaveObject, path_vpos_loc: gl.GLint) !Object {
        const data: Data = switch (save_obj.data) {
            .filesystem => |s| blk: {
                break :blk .{
                    .filesystem = try FilesystemObject.load(alloc, s),
                };
            },
            .composition => |c| blk: {
                var objects = std.ArrayListUnmanaged(CompositionObject.ComposedObject){};
                errdefer objects.deinit(alloc);

                try objects.appendSlice(alloc, c);
                break :blk .{
                    .composition = .{
                        .objects = objects,
                    },
                };
            },
            .shader => |s| blk: {
                comptime {
                    std.debug.assert(@alignOf(ObjectId) == @alignOf(usize));
                    std.debug.assert(@sizeOf(ObjectId) == @sizeOf(usize));
                }

                var shader_object = try ShaderObject.init(alloc, s.input_images.len, .{ .value = s.shader_id }, s.primary_input_idx);
                errdefer shader_object.deinit(alloc);

                for (0..s.input_images.len) |idx| {
                    const input_id: ?ObjectId = if (s.input_images[idx]) |input_id| ObjectId{ .value = input_id } else null;
                    try shader_object.setInputImage(idx, input_id);
                }
                break :blk .{ .shader = shader_object };
            },
            .path => |p| blk: {
                break :blk .{
                    .path = try PathObject.init(alloc, p.points, .{ .value = p.display_object }, path_vpos_loc),
                };
            },
            .generated_mask => |source| .{
                .generated_mask = GeneratedMaskObject.initNullTexture(.{ .value = source }),
            },
        };

        return .{
            .name = try alloc.dupe(u8, save_obj.name),
            .data = data,
        };
    }

    pub fn dims(self: Object, object_list: *Objects) PixelDims {
        switch (self.data) {
            .filesystem => |*f| {
                return .{ f.width, f.height };
            },
            .path => |*p| {
                const display_object = object_list.get(p.display_object);
                return dims(display_object.*, object_list);
            },
            .generated_mask => |*m| {
                const source = object_list.get(m.source);
                return dims(source.*, object_list);
            },
            .shader => |s| {
                const dims_id = s.input_images[s.primary_input_idx] orelse return .{ 1024, 1024 };
                const source = object_list.get(dims_id);

                return dims(source.*, object_list);
            },
            .composition => {
                // FIXME: Customize composition size
                return .{ 1920, 1080 };
            },
        }
    }

    const DependencyIt = struct {
        idx: usize = 0,
        object: Object,

        pub fn next(self: *DependencyIt) ?ObjectId {
            switch (self.object.data) {
                .filesystem => return null,
                .path => |*p| {
                    if (self.idx >= 1) {
                        return null;
                    }
                    defer self.idx += 1;
                    return p.display_object;
                },
                .shader => |*s| {
                    while (self.idx < s.input_images.len) {
                        defer self.idx += 1;

                        return s.input_images[self.idx];
                    }

                    return null;
                },
                .composition => |*c| {
                    if (self.idx >= c.objects.items.len) {
                        return null;
                    }
                    defer self.idx += 1;
                    return c.objects.items[self.idx].id;
                },
                .generated_mask => |*m| {
                    if (self.idx > 0) {
                        return null;
                    }
                    defer self.idx += 1;
                    return m.source;
                },
            }
        }
    };

    pub fn dependencies(self: Object) DependencyIt {
        return .{
            .object = self,
        };
    }

    pub fn isComposable(self: Object) bool {
        return switch (self.data) {
            .filesystem => true,
            .path => false,
            .generated_mask => true,
            .shader => true,
            .composition => true,
        };
    }

    pub fn asPath(self: *Object) ?*PathObject {
        switch (self.data) {
            .path => |*p| return p,
            else => return null,
        }
    }

    pub fn asComposition(self: *Object) ?*CompositionObject {
        switch (self.data) {
            .composition => |*c| return c,
            else => return null,
        }
    }

    pub fn asShader(self: *Object) ?*ShaderObject {
        switch (self.data) {
            .shader => |*s| return s,
            else => return null,
        }
    }
};

pub const CompositionIdx = struct {
    value: usize,
};

pub const CompositionObject = struct {
    const ComposedObject = struct {
        id: ObjectId,
        // Identity represents an aspect ratio corrected object that would fill
        // the composition if it were square. E.g. if the object is wide, it
        // scales until it fits horizontally in a 1:1 square, if it is tall it
        // scales to fit vertically. The actual composition will ensure that
        // this 1:1 square is fully visible, but may contain extra stuff
        // outside depending on the aspect ratio of the composition
        transform: Transform,

        pub fn composedToCompositionTransform(self: ComposedObject, objects: *Objects, composition_aspect: f32) Transform {
            const object = objects.get(self.id);
            const object_dims = object.dims(objects);

            // Put it in a square
            const obj_aspect_transform = coords.aspectRatioCorrectedFill(object_dims[0], object_dims[1], 1, 1);

            const composition_aspect_transform = if (composition_aspect > 1.0)
                Transform.scale(1.0 / composition_aspect, 1.0)
            else
                Transform.scale(1.0, composition_aspect);

            return obj_aspect_transform
                .then(self.transform)
                .then(composition_aspect_transform);
        }
    };

    objects: std.ArrayListUnmanaged(ComposedObject) = .{},

    pub fn setTransform(self: *CompositionObject, idx: CompositionIdx, transform: Transform) void {
        const obj = &self.objects.items[idx.value];
        obj.transform = transform;
    }

    pub fn addObj(self: *CompositionObject, alloc: Allocator, id: ObjectId) !CompositionIdx {
        const ret = self.objects.items.len;
        try self.objects.append(alloc, .{
            .id = id,
            .transform = Transform.identity,
        });
        return .{ .value = ret };
    }

    pub fn removeObj(self: *CompositionObject, id: CompositionIdx) void {
        _ = self.objects.swapRemove(id.value);
    }

    pub fn deinit(self: *CompositionObject, alloc: Allocator) void {
        self.objects.deinit(alloc);
    }
};

pub const ShaderObject = struct {
    input_images: []?ObjectId,
    primary_input_idx: usize,

    program: ShaderStorage.ShaderId,

    pub fn init(alloc: Allocator, num_input_images: usize, shader_id: ShaderStorage.ShaderId, primary_input_idx: usize) !ShaderObject {
        const input_images = try alloc.alloc(?ObjectId, num_input_images);
        errdefer alloc.free(input_images);
        @memset(input_images, null);

        return .{
            .input_images = input_images,
            .program = shader_id,
            .primary_input_idx = primary_input_idx,
        };
    }

    pub fn deinit(self: *ShaderObject, alloc: Allocator) void {
        alloc.free(self.input_images);
    }

    // FIXME: strong type
    pub fn setInputImage(self: *ShaderObject, idx: usize, val: ?ObjectId) !void {
        if (idx >= self.input_images.len) {
            return error.InvalidShaderIndex;
        }

        self.input_images[idx] = val;
    }

    pub fn save(self: ShaderObject) SaveObject.Data {
        comptime {
            std.debug.assert(@alignOf(ObjectId) == @alignOf(usize));
            std.debug.assert(@sizeOf(ObjectId) == @sizeOf(usize));
        }

        return .{
            .shader = .{
                .input_images = @ptrCast(self.input_images),
                .shader_id = self.program.value,
                .primary_input_idx = self.primary_input_idx,
            },
        };
    }
};

pub const FilesystemObject = struct {
    source: [:0]const u8,
    width: usize,
    height: usize,

    texture: Renderer.Texture,

    pub fn load(alloc: Allocator, path: [:0]const u8) !FilesystemObject {
        const image = try StbImage.init(path);
        defer image.deinit();

        const texture = Renderer.makeTextureFromRgba(image.data, image.width);
        errdefer texture.deinit();

        const source = try alloc.dupeZ(u8, path);
        errdefer alloc.free(source);

        return .{
            .texture = texture,
            .width = image.width,
            .height = image.calcHeight(),
            .source = source,
        };
    }

    pub fn deinit(self: FilesystemObject, alloc: Allocator) void {
        self.texture.deinit();
        alloc.free(self.source);
    }
};

pub const PathIdx = struct { value: usize };

pub const PathObject = struct {
    points: std.ArrayListUnmanaged(Vec2) = .{},
    display_object: ObjectId,

    selected_point: ?usize = null,
    vertex_array: gl.GLuint,
    vertex_buffer: gl.GLuint,

    pub fn init(alloc: Allocator, initial_points: []const Vec2, display_object: ObjectId, vpos_location: gl.GLint) !PathObject {
        var points = try std.ArrayListUnmanaged(Vec2).initCapacity(alloc, initial_points.len);
        errdefer points.deinit(alloc);

        try points.appendSlice(alloc, initial_points);

        var vertex_buffer: gl.GLuint = 0;
        gl.glGenBuffers(1, &vertex_buffer);
        errdefer gl.glDeleteBuffers(1, &vertex_buffer);

        setBufferData(vertex_buffer, points.items);

        var vertex_array: gl.GLuint = 0;
        gl.glGenVertexArrays(1, &vertex_array);
        errdefer gl.glDeleteVertexArrays(1, &vertex_array);

        gl.glBindVertexArray(vertex_array);

        gl.glEnableVertexAttribArray(@intCast(vpos_location));
        gl.glVertexAttribPointer(@intCast(vpos_location), 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * 2, null);
        return .{
            .points = points,
            .display_object = display_object,
            .vertex_array = vertex_array,
            .vertex_buffer = vertex_buffer,
        };
    }

    fn setBufferData(vertex_buffer: gl.GLuint, points: []const Vec2) void {
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vertex_buffer);
        gl.glBufferData(gl.GL_ARRAY_BUFFER, @intCast(points.len * 8), points.ptr, gl.GL_DYNAMIC_DRAW);
    }

    pub fn addPoint(self: *PathObject, alloc: Allocator, pos: Vec2) !void {
        try self.points.append(alloc, pos);
        setBufferData(self.vertex_buffer, self.points.items);
    }

    pub fn movePoint(self: *PathObject, idx: PathIdx, movement: Vec2) void {
        self.points.items[idx.value] += movement;
        gl.glNamedBufferSubData(self.vertex_buffer, @intCast(idx.value * 8), 8, &self.points.items[idx.value]);
    }

    pub fn deinit(self: *PathObject, alloc: Allocator) void {
        self.points.deinit(alloc);
        gl.glDeleteBuffers(1, &self.vertex_buffer);
        gl.glDeleteVertexArrays(1, &self.vertex_array);
    }
};

pub const GeneratedMaskObject = struct {
    source: ObjectId,

    texture: Renderer.Texture,

    pub fn initNullTexture(source: ObjectId) GeneratedMaskObject {
        return .{
            .source = source,
            .texture = Renderer.Texture.invalid,
        };
    }

    pub fn generate(alloc: Allocator, source: ObjectId, width: usize, height: usize, path_points: []const Vec2) !GeneratedMaskObject {
        const mask = try alloc.alloc(u8, width * height);
        defer alloc.free(mask);

        @memset(mask, 0);

        const bb = findBoundingBox(path_points, width, height);
        const width_i64: i64 = @intCast(width);

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();

        for (bb.y_start..bb.y_end) |y| {
            _ = arena.reset(.retain_capacity);
            const arena_alloc = arena.allocator();

            const intersection_points = try findIntersectionPoints(arena_alloc, path_points, y, width, height);
            defer arena_alloc.free(intersection_points);

            // Assume we start outside the polygon
            const row_start = width * y;
            const row_end = row_start + width;

            const row = mask[row_start..row_end];
            for (0..intersection_points.len / 2) |i| {
                const a = intersection_points[i * 2];
                const b = intersection_points[i * 2 + 1];
                const a_u: usize = @intCast(std.math.clamp(a, 0, width_i64));
                const b_u: usize = @intCast(std.math.clamp(b, 0, width_i64));
                @memset(row[a_u..b_u], 0xff);
            }
        }

        const texture = Renderer.makeTextureFromR(mask, width);
        return .{
            .texture = texture,
            .source = source,
        };
    }

    const BoundingBox = struct {
        y_start: usize,
        y_end: usize,
        x_start: usize,
        x_end: usize,
    };

    fn findBoundingBox(points: []const Vec2, width: usize, height: usize) BoundingBox {
        // Points are in [-1, 1]
        var min_x: f32 = std.math.inf(f32);
        var min_y: f32 = std.math.inf(f32);

        var max_x: f32 = -std.math.inf(f32);
        var max_y: f32 = -std.math.inf(f32);

        for (points) |point| {
            if (point[0] < min_x) min_x = point[0];
            if (point[1] < min_y) min_y = point[1];
            if (point[0] > max_x) max_x = point[0];
            if (point[1] > max_y) max_y = point[1];
        }

        const min_x_pixel = objectToPixelCoord(min_x, width);
        const min_y_pixel = objectToPixelCoord(min_y, height);
        const max_x_pixel = objectToPixelCoord(max_x, width);
        const max_y_pixel = objectToPixelCoord(max_y, height);

        const w_i64: i64 = @intCast(width);
        const h_i64: i64 = @intCast(height);
        return .{
            .x_start = @intCast(std.math.clamp(min_x_pixel, 0, w_i64)),
            .y_start = @intCast(std.math.clamp(min_y_pixel, 0, h_i64)),
            .x_end = @intCast(std.math.clamp(max_x_pixel, 0, w_i64)),
            .y_end = @intCast(std.math.clamp(max_y_pixel, 0, h_i64)),
        };
    }

    fn findIntersectionPoints(alloc: Allocator, points: []const Vec2, y_px: usize, width: usize, height: usize) ![]i64 {
        var intersection_points = std.ArrayList(i64).init(alloc);
        defer intersection_points.deinit();

        const y_clip = pixelToObjectCoord(y_px, height);

        for (0..points.len) |i| {
            const a = points[i];
            const b = points[(i + 1) % points.len];

            const t = (y_clip - b[1]) / (a[1] - b[1]);
            if (t > 1.0 or t < 0.0) {
                continue;
            }

            const x_clip = std.math.lerp(b[0], a[0], t);
            const x_px = objectToPixelCoord(x_clip, width);
            try intersection_points.append(@intCast(x_px));
        }

        const lessThan = struct {
            fn f(_: void, lhs: i64, rhs: i64) bool {
                return lhs < rhs;
            }
        }.f;

        std.mem.sort(i64, intersection_points.items, {}, lessThan);
        return try intersection_points.toOwnedSlice();
    }

    pub fn deinit(self: GeneratedMaskObject) void {
        self.texture.deinit();
    }
};

pub const SaveObject = struct {
    name: []const u8,
    data: Data,

    const Data = union(enum) {
        filesystem: [:0]const u8,
        composition: []CompositionObject.ComposedObject,
        shader: struct {
            input_images: []?usize,
            shader_id: usize,
            primary_input_idx: usize,
        },
        path: struct {
            points: []Vec2,
            display_object: usize,
        },
        generated_mask: usize,
    };
};

pub const ObjectId = struct {
    value: usize,
};

pub const Objects = struct {
    inner: std.ArrayListUnmanaged(Object) = .{},

    pub fn initCapacity(alloc: Allocator, capacity: usize) !Objects {
        return Objects{
            .inner = try std.ArrayListUnmanaged(Object).initCapacity(alloc, capacity),
        };
    }

    pub fn deinit(self: *Objects, alloc: Allocator) void {
        for (self.inner.items) |*object| {
            object.deinit(alloc);
        }
        self.inner.deinit(alloc);
    }

    pub fn get(self: *Objects, id: ObjectId) *Object {
        return &self.inner.items[id.value];
    }

    pub fn nextId(self: Objects) ObjectId {
        return .{ .value = self.inner.items.len };
    }

    pub const IdIter = struct {
        val: usize = 0,
        max: usize,

        pub fn next(self: *IdIter) ?ObjectId {
            if (self.val >= self.max) return null;
            defer self.val += 1;
            return .{ .value = self.val };
        }
    };

    pub fn idIter(self: Objects) IdIter {
        return .{ .max = self.inner.items.len };
    }

    pub fn save(self: Objects, alloc: Allocator) ![]SaveObject {
        const object_saves = try alloc.alloc(SaveObject, self.inner.items.len);
        errdefer alloc.free(object_saves);

        for (0..self.inner.items.len) |i| {
            object_saves[i] = self.inner.items[i].save();
        }

        return object_saves;
    }

    pub fn append(self: *Objects, alloc: Allocator, object: Object) !void {
        try self.inner.append(alloc, object);
    }
};

fn objectToPixelCoord(val: f32, max: usize) i64 {
    const max_f: f32 = @floatFromInt(max);
    return @intFromFloat(((val + 1) / 2) * max_f);
}

fn pixelToObjectCoord(val: usize, max: usize) f32 {
    const val_f: f32 = @floatFromInt(val);
    const max_f: f32 = @floatFromInt(max);
    return ((val_f / max_f) - 0.5) * 2;
}
