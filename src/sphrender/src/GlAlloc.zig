const std = @import("std");
const gl = @import("gl.zig");
const sphalloc = @import("sphalloc");
const Sphalloc = sphalloc.Sphalloc;

// FIXME: SegmentedList leaks the memory for tracking list starts. We might
// want to use something else...
arena: std.mem.Allocator,
vbos: std.SegmentedList(gl.GLuint, 8) = .{},
vaos: std.SegmentedList(gl.GLuint, 8) = .{},
programs: std.SegmentedList(gl.GLuint, 8) = .{},
textures: std.SegmentedList(gl.GLuint, 8) = .{},
children: std.SegmentedList(GlAlloc, 0) = .{},

const GlAlloc = @This();

pub fn init(alloc: *Sphalloc) !GlAlloc {
    return .{
        .arena = alloc.arena(),
    };
}

pub fn reset(self: *GlAlloc) void {
    self.restore(.{
        .program_idx = 0,
        .vbo_idx = 0,
        .vao_idx = 0,
        .texture_idx = 0,
    });

    var child_it = self.children.iterator(0);
    while (child_it.next()) |child| {
        child.reset();
    }

    self.vaos = .{};
    self.vbos = .{};
    self.programs = .{};
    self.textures = .{};
    self.children = .{};
}

pub fn createBuffer(self: *GlAlloc) !gl.GLuint {
    var vertex_buffer: gl.GLuint = 0;
    gl.glCreateBuffers(1, &vertex_buffer);
    try self.registerVbo(vertex_buffer);
    return vertex_buffer;
}

pub fn createArray(self: *GlAlloc) !gl.GLuint {
    var vao: gl.GLuint = 0;
    gl.glCreateVertexArrays(1, &vao);
    try self.registerVao(vao);
    return vao;
}

pub fn createProgram(self: *GlAlloc) !gl.GLuint {
    const program = gl.glCreateProgram();
    try self.programs.append(self.arena, program);
    return program;
}

pub fn genTexture(self: *GlAlloc) !gl.GLuint {
    var texture: gl.GLuint = undefined;
    gl.glGenTextures(1, &texture);
    try self.textures.append(self.arena, texture);
    return texture;
}

pub const Checkpoint = struct {
    vbo_idx: usize,
    vao_idx: usize,
    program_idx: usize,
    texture_idx: usize,
};

pub fn checkpoint(self: *GlAlloc) Checkpoint {
    return .{
        .vbo_idx = self.vbos.len,
        .vao_idx = self.vaos.len,
        .program_idx = self.programs.len,
        .texture_idx = self.textures.len,
    };
}

pub fn restore(self: *GlAlloc, restore_point: Checkpoint) void {
    var vbo_it = self.vbos.iterator(restore_point.vbo_idx);
    // FIXME: Could definitely free in chunks
    while (vbo_it.next()) |elem| {
        gl.glDeleteBuffers(1, elem);
    }

    var vao_it = self.vaos.iterator(restore_point.vao_idx);
    // FIXME: Could definitely free in chunks
    while (vao_it.next()) |elem| {
        gl.glDeleteVertexArrays(1, elem);
    }

    var program_it = self.programs.iterator(restore_point.program_idx);
    // FIXME: Could definitely free in chunks
    while (program_it.next()) |elem| {
        gl.glDeleteProgram(elem.*);
    }

    var texture_it = self.textures.iterator(restore_point.texture_idx);
    // FIXME: Could definitely free in chunks
    while (texture_it.next()) |elem| {
        gl.glDeleteTextures(1, elem);
    }

    self.vbos.shrinkRetainingCapacity(restore_point.vbo_idx);
    self.vaos.shrinkRetainingCapacity(restore_point.vao_idx);
    self.textures.shrinkRetainingCapacity(restore_point.texture_idx);
    self.programs.shrinkRetainingCapacity(restore_point.program_idx);
}

pub fn registerVbo(self: *GlAlloc, vbo: gl.GLuint) !void {
    try self.vbos.append(self.arena, vbo);
}

pub fn registerVao(self: *GlAlloc, vao: gl.GLuint) !void {
    try self.vaos.append(self.arena, vao);
}

pub fn makeSubAlloc(self: *GlAlloc, alloc: *Sphalloc) !*GlAlloc {
    const child = try GlAlloc.init(alloc);
    try self.children.append(self.arena, child);
    return self.children.at(self.children.count() - 1);
}
