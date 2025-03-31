const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("gl");
const sphrender = @import("sphrender.zig");
const sphmath = @import("sphmath");
const Uniform = sphrender.Uniform;
const ResolvedUniformValue = sphrender.ResolvedUniformValue;
const ReservedUniformValue = sphrender.ReservedUniformValue;
const GlAlloc = @import("GlAlloc.zig");
const sphutil = @import("sphutil");
const sphalloc = @import("sphalloc");
const ScratchAlloc = sphalloc.ScratchAlloc;

pub fn Program(comptime Vertex: type, comptime KnownUniforms: type) type {
    const num_known_uniforms = std.meta.fields(KnownUniforms).len;

    return struct {
        program: gl.GLuint,
        known_uniform_locations: UniformLocations,

        const UniformLocations = [num_known_uniforms]?gl.GLint;

        const Self = @This();

        pub fn init(gl_alloc: *GlAlloc, vs: [:0]const u8, fs: [:0]const u8) !Self {
            const program = try sphrender.compileLinkProgram(gl_alloc, vs, fs);

            var uniform_it = try sphrender.ProgramUniformIt.init(program);
            var known_uniform_locations: UniformLocations = .{null} ** num_known_uniforms;

            while (uniform_it.next()) |uniform| {
                if (knownUniformIdx(KnownUniforms, uniform.name)) |idx| {
                    if (num_known_uniforms > 0) {
                        known_uniform_locations[idx] = uniform.loc;
                    }
                }
            }

            return .{
                .program = program,
                .known_uniform_locations = known_uniform_locations,
            };
        }

        pub fn makeBuffer(self: Self, gl_alloc: *GlAlloc, initial_data: []const Vertex) !Buffer(Vertex) {
            return try Buffer(Vertex).init(gl_alloc, self.program, initial_data);
        }

        pub fn unknownUniforms(self: Self, scratch: *ScratchAlloc) !UnknownUniforms {
            var uniform_it = try sphrender.ProgramUniformIt.init(self.program);

            var ret = try sphutil.RuntimeBoundedArray(UnknownUniforms.Item).init(
                scratch.allocator(),
                uniform_it.num_uniforms,
            );

            while (uniform_it.next()) |uniform| {
                if (knownUniformIdx(KnownUniforms, uniform.name)) |_| {
                    continue;
                }

                const duped_name = try scratch.allocator().dupe(u8, uniform.name);
                try ret.append(.{
                    .loc = uniform.loc,
                    .default = uniform.default,
                    .name = duped_name,
                });
            }

            return .{
                .items = ret.items,
            };
        }

        pub fn render(self: Self, buffer: Buffer(Vertex), options: KnownUniforms) void {
            return self.renderWithExtra(buffer, options, UnknownUniforms.empty, &.{});
        }

        pub fn renderLines(self: Self, buffer: Buffer(Vertex), options: KnownUniforms) void {
            return self.renderInner(buffer, options, UnknownUniforms.empty, &.{}, gl.GL_LINES);
        }

        pub fn renderWithExtra(self: Self, buffer: Buffer(Vertex), options: KnownUniforms, defs: UnknownUniforms, values: []const ResolvedUniformValue) void {
            self.renderInner(buffer, options, defs, values, gl.GL_TRIANGLES);
        }

        fn renderInner(self: Self, buffer: Buffer(Vertex), options: KnownUniforms, defs: UnknownUniforms, values: []const ResolvedUniformValue, mode: gl.GLenum) void {
            gl.glUseProgram(self.program);
            gl.glBindVertexArray(buffer.vertex_array);

            var texture_unit_alloc = sphrender.TextureUnitAlloc{};

            const option_fiels = std.meta.fields(KnownUniforms);
            inline for (option_fiels, 0..) |option, idx| {
                const loc_opt = self.known_uniform_locations[idx];
                if (loc_opt) |loc| {
                    const val = resolvedUniformType(option.type, &@field(options, option.name));
                    const uniform_type = std.meta.stringToEnum(sphrender.UniformType, @tagName(val)).?;
                    sphrender.applyUniformAtLocation(loc, uniform_type, val, &texture_unit_alloc);
                }
            }

            for (values, defs.items) |val, uniform| {
                sphrender.applyUniformAtLocation(uniform.loc, uniform.default, val, &texture_unit_alloc);
            }

            gl.glDrawArrays(mode, 0, @intCast(buffer.len));
        }
    };
}

pub fn IndexBuffer(comptime T: type) type {
    return struct {
        value: gl.GLuint,
        len: usize,

        const Self = @This();
        pub fn init(gl_alloc: *GlAlloc) !Self {
            return .{
                .value = try gl_alloc.createBuffer(),
                .len = 0,
            };
        }

        pub fn bindData(self: *Self, data: []const T) void {
            gl.glNamedBufferData(self.value, @intCast(data.len * @sizeOf(T)), data.ptr, gl.GL_STATIC_DRAW);
            self.len = data.len;
        }
    };
}

pub const RenderSource = struct {
    vao: gl.GLuint,
    index_type: ?gl.GLenum = null,
    len: usize,

    const Self = @This();

    pub fn init(gl_alloc: *GlAlloc) !Self {
        return .{
            .vao = try gl_alloc.createArray(),
            .len = 0,
        };
    }

    pub fn bindData(self: *RenderSource, comptime VertElem: type, program: ProgramHandle, data: Buffer2(VertElem)) void {
        const fields = std.meta.fields(VertElem);
        var field_locs: [fields.len]gl.GLint = undefined;

        inline for (fields, 0..) |elem, i| {
            field_locs[i] = gl.glGetAttribLocation(program.value, elem.name);
        }

        const binding_index = 0;

        gl.glVertexArrayVertexBuffer(self.vao, binding_index, data.vertex_buffer, 0, @sizeOf(VertElem));

        inline for (fields, field_locs) |field, loc| {
            if (loc >= 0) {
                const offs = @offsetOf(VertElem, field.name);

                gl.glEnableVertexArrayAttrib(self.vao, @intCast(loc));
                const num_elems = switch (field.type) {
                    sphmath.Vec2 => 2,
                    sphmath.Vec3 => 3,
                    sphmath.Vec4 => 4,
                    f32 => 1,
                    u32 => 1,
                    [4]u8 => 4,
                    else => @compileError("Unknown type"),
                };
                const elem_type = switch (field.type) {
                    sphmath.Vec4, sphmath.Vec3, sphmath.Vec2, f32 => gl.GL_FLOAT,
                    u32 => gl.GL_UNSIGNED_INT,
                    [4]u8 => gl.GL_UNSIGNED_BYTE,
                    else => @compileError("Unknown type"),
                };
                switch (field.type) {
                    sphmath.Vec4, sphmath.Vec3, sphmath.Vec2, f32 => {
                        gl.glVertexArrayAttribFormat(self.vao, @intCast(loc), num_elems, elem_type, gl.GL_FALSE, offs);
                    },
                    u32, [4]u8 => {
                        gl.glVertexArrayAttribIFormat(self.vao, @intCast(loc), num_elems, elem_type, offs);
                    },
                    else => @compileError("Unknown type"),
                }
                gl.glVertexArrayAttribBinding(self.vao, @intCast(loc), binding_index);
            }
        }

        self.len = data.len;
    }

    pub fn setIndexBuffer(self: *RenderSource, comptime T: type, buf: IndexBuffer(T)) void {
        gl.glVertexArrayElementBuffer(self.vao, buf.value);
        self.index_type = switch (T) {
            u16 => gl.GL_UNSIGNED_SHORT,
            else => @compileError("Unimplemented index buffer type"),
        };
        std.debug.print("len: {d}\n", .{buf.len});
        self.len = buf.len;
    }

    pub fn bindDataSplit(self: *RenderSource, comptime VertElem: type, program: ProgramHandle, data: SplitBuffers(VertElem)) void {
        _ = self;
        _ = program;
        _ = data;
        unreachable;
    }
};


pub const ProgramHandle = struct {
    value: gl.GLuint,
};

pub fn Program2(comptime KnownUniforms: type) type {
    const num_known_uniforms = std.meta.fields(KnownUniforms).len;

    return struct {
        handle: ProgramHandle,
        known_uniform_locations: UniformLocations,

        const UniformLocations = [num_known_uniforms]?gl.GLint;

        const Self = @This();

        pub fn init(gl_alloc: *GlAlloc, vs: [:0]const u8, fs: [:0]const u8) !Self {
            const program = try sphrender.compileLinkProgram(gl_alloc, vs, fs);

            var uniform_it = try sphrender.ProgramUniformIt.init(program);
            var known_uniform_locations: UniformLocations = .{null} ** num_known_uniforms;

            while (uniform_it.next()) |uniform| {
                if (knownUniformIdx(KnownUniforms, uniform.name)) |idx| {
                    if (num_known_uniforms > 0) {
                        known_uniform_locations[idx] = uniform.loc;
                    }
                }
            }

            return .{
                .handle = .{ .value = program },
                .known_uniform_locations = known_uniform_locations,
            };
        }

        pub fn unknownUniforms(self: Self, scratch: *ScratchAlloc) !UnknownUniforms {
            var uniform_it = try sphrender.ProgramUniformIt.init(self.handle.value);

            var ret = try sphutil.RuntimeBoundedArray(UnknownUniforms.Item).init(
                scratch.allocator(),
                uniform_it.num_uniforms,
            );

            while (uniform_it.next()) |uniform| {
                if (knownUniformIdx(KnownUniforms, uniform.name)) |_| {
                    continue;
                }

                const duped_name = try scratch.allocator().dupe(u8, uniform.name);
                try ret.append(.{
                    .loc = uniform.loc,
                    .default = uniform.default,
                    .name = duped_name,
                });
            }

            return .{
                .items = ret.items,
            };
        }

        pub fn render(self: Self, array: RenderSource, options: KnownUniforms) void {
            return self.renderWithExtra(array, options, UnknownUniforms.empty, &.{});
        }

        pub fn renderLines(self: Self, array: RenderSource, options: KnownUniforms) void {
            return self.renderInner(array, options, UnknownUniforms.empty, &.{}, gl.GL_LINES);
        }

        pub fn renderWithExtra(self: Self, array: RenderSource, options: KnownUniforms, defs: UnknownUniforms, values: []const ResolvedUniformValue) void {
            self.renderInner(array, options, defs, values, gl.GL_TRIANGLES);
        }

        fn renderInner(self: Self, array: RenderSource, options: KnownUniforms, defs: UnknownUniforms, values: []const ResolvedUniformValue, mode: gl.GLenum) void {
            gl.glUseProgram(self.handle.value);
            gl.glBindVertexArray(array.vao);

            var texture_unit_alloc = sphrender.TextureUnitAlloc{};

            const option_fiels = std.meta.fields(KnownUniforms);
            inline for (option_fiels, 0..) |option, idx| {
                const loc_opt = self.known_uniform_locations[idx];
                if (loc_opt) |loc| {
                    const val = resolvedUniformType(option.type, &@field(options, option.name));
                    const uniform_type = std.meta.stringToEnum(sphrender.UniformType, @tagName(val)).?;
                    sphrender.applyUniformAtLocation(loc, uniform_type, val, &texture_unit_alloc);
                }
            }

            for (values, defs.items) |val, uniform| {
                sphrender.applyUniformAtLocation(uniform.loc, uniform.default, val, &texture_unit_alloc);
            }

            if (array.index_type) |t| {
                gl.glDrawElements(mode, @intCast(array.len), t, null);
            } else {
                gl.glDrawArrays(mode, 0, @intCast(array.len));
            }
        }
    };
}

fn resolvedUniformType(comptime T: type, val: anytype) sphrender.ResolvedUniformValue {
    switch (T) {
        sphrender.Texture => return .{
            .image = val.inner,
        },
        else => blk: {
            const uniform_type = switch (T) {
                sphmath.Vec3 => .float3,
                sphmath.Vec2 => .float2,
                f32 => .float,
                sphmath.Mat3x3 => .mat3x3,
                sphmath.Mat4x4 => .mat4x4,
                sphrender.Texture => .image,
                u32 => .uint,
                else => break :blk,
            };
            return @unionInit(ResolvedUniformValue, @tagName(uniform_type), val.*);
        },
    }

    const info = @typeInfo(T);
    switch (info) {
        .array => |a| {
            switch (a.child) {
                sphmath.Mat4x4 => {
                    return .{
                        .mat4x4_arr = val,
                    };
                },
                else => {},
            }
        },
        else => {},
    }
    @compileError("Unsupported uniform type " ++ @typeName(T));
}

pub fn SplitBuffers(comptime T: type) type {
    const fields = std.meta.fields(T);

    var new_fields: [fields.len]std.builtin.Type.StructField = undefined;
    inline for (fields, &new_fields) |in_field, *out_field| {
        out_field.* = .{
            .name = in_field.name,
            .type =  Buffer2(in_field.type),
            .is_comptime = false,
            .alignment = @alignOf(?*anyopaque),
            .default_value_ptr = null,
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &new_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}


pub fn Buffer2(comptime Elem: type) type {
    return struct {
        vertex_buffer: gl.GLuint,
        len: usize,

        const elem_stride = @sizeOf(Elem);

        const Self = @This();

        const binding_index = 0;

        pub fn init(gl_alloc: *GlAlloc, initial_data: []const Elem) !Self {
            const vertex_buffer = try gl_alloc.createBuffer();
            gl.glNamedBufferData(vertex_buffer, @intCast(initial_data.len * elem_stride), initial_data.ptr, gl.GL_STATIC_DRAW);

            return .{
                .vertex_buffer = vertex_buffer,
                .len = initial_data.len,
            };
        }

        pub fn updateBuffer(self: *Self, points: []const Elem) void {
            gl.glNamedBufferData(self.vertex_buffer, @intCast(points.len * elem_stride), points.ptr, gl.GL_STATIC_DRAW);
            self.len = points.len;
        }
    };
}
pub fn Buffer(comptime Elem: type) type {
    return struct {
        vertex_buffer: gl.GLuint,
        vertex_array: gl.GLuint,
        len: usize,

        const elem_stride = @sizeOf(Elem);

        const Self = @This();

        const binding_index = 0;

        pub fn init(gl_alloc: *GlAlloc, program: gl.GLuint, initial_data: []const Elem) !Self {
            const fields = std.meta.fields(Elem);
            var field_locs: [fields.len]gl.GLint = undefined;

            inline for (fields, 0..) |elem, i| {
                field_locs[i] = gl.glGetAttribLocation(program, elem.name);
            }

            const vertex_buffer = try gl_alloc.createBuffer();

            gl.glNamedBufferData(vertex_buffer, @intCast(initial_data.len * elem_stride), initial_data.ptr, gl.GL_STATIC_DRAW);

            const vertex_array = try gl_alloc.createArray();

            gl.glVertexArrayVertexBuffer(vertex_array, binding_index, vertex_buffer, 0, elem_stride);

            inline for (fields, field_locs) |field, loc| {
                if (loc >= 0) {
                    const offs = @offsetOf(Elem, field.name);

                    gl.glEnableVertexArrayAttrib(vertex_array, @intCast(loc));
                    const num_elems = switch (field.type) {
                        sphmath.Vec2 => 2,
                        sphmath.Vec3 => 3,
                        sphmath.Vec4 => 4,
                        f32 => 1,
                        u32 => 1,
                        else => @compileError("Unknown type"),
                    };
                    const elem_type = switch (field.type) {
                        sphmath.Vec4, sphmath.Vec3, sphmath.Vec2, f32 => gl.GL_FLOAT,
                        u32 => gl.GL_UNSIGNED_INT,
                        else => @compileError("Unknown type"),
                    };
                    switch (field.type) {
                        sphmath.Vec4, sphmath.Vec3, sphmath.Vec2, f32 => {
                            gl.glVertexArrayAttribFormat(vertex_array, @intCast(loc), num_elems, elem_type, gl.GL_FALSE, offs);
                        },
                        u32 => {
                            gl.glVertexArrayAttribIFormat(vertex_array, @intCast(loc), num_elems, elem_type, offs);
                        },
                        else => @compileError("Unknown type"),
                    }
                    gl.glVertexArrayAttribBinding(vertex_array, @intCast(loc), binding_index);
                }
            }

            return .{
                .vertex_array = vertex_array,
                .vertex_buffer = vertex_buffer,
                .len = initial_data.len,
            };
        }


        pub fn updateBuffer(self: *Self, points: []const Elem) void {
            gl.glNamedBufferData(self.vertex_buffer, @intCast(points.len * elem_stride), points.ptr, gl.GL_STATIC_DRAW);
            self.len = points.len;
        }
    };
}

fn knownUniformIdx(comptime KnownUniforms: type, name: []const u8) ?usize {
    const field_names = std.meta.fieldNames(KnownUniforms);
    inline for (field_names, 0..) |field_name, idx| {
        if (std.mem.eql(u8, name, field_name)) {
            return idx;
        }
    }

    return null;
}

pub const UnknownUniforms = struct {
    pub const Item = struct {
        loc: gl.GLint,
        default: sphrender.UniformDefault,
        name: []const u8,

        fn clone(self: Item, alloc: Allocator) !Item {
            return .{
                .loc = self.loc,
                .default = self.default,
                .name = try alloc.dupe(u8, self.name),
            };
        }
    };

    pub const empty: UnknownUniforms = .{ .items = &.{} };

    items: []Item,

    pub fn clone(self: UnknownUniforms, alloc: Allocator) !UnknownUniforms {
        const items = try alloc.alloc(Item, self.items.len);
        for (items, self.items) |*dst, *src| {
            dst.* = try src.clone(alloc);
        }
        return .{
            .items = items,
        };
    }
};
