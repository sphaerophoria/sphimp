const std = @import("std");
const sphimp = @import("sphimp");

pub const SelectedObjectWidth = struct {
    app: *sphimp.App,
    id: *sphimp.object.ObjectId,

    pub fn init(app: *sphimp.App, id: *sphimp.object.ObjectId) SelectedObjectWidth {
        return .{ .app = app, .id = id };
    }

    pub fn getVal(self: *SelectedObjectWidth) f32 {
        return @floatFromInt(self.app.objectDims(self.id.*)[0]);
    }
};

pub const SelectedObjectHeight = struct {
    app: *sphimp.App,
    id: *sphimp.object.ObjectId,

    pub fn init(app: *sphimp.App, id: *sphimp.object.ObjectId) SelectedObjectHeight {
        return .{ .app = app, .id = id };
    }

    pub fn getVal(self: *SelectedObjectHeight) f32 {
        return @floatFromInt(self.app.objectDims(self.id.*)[1]);
    }
};

pub const ShaderUniform = struct {
    app: *sphimp.App,
    uniform_idx: usize,
    float_idx: usize,

    pub fn getVal(self: *ShaderUniform) f32 {
        const bindings = self.app.selectedObject().shaderBindings() orelse return -std.math.inf(f32);
        switch (bindings[self.uniform_idx]) {
            .float => |f| {
                return f;
            },
            .float2 => |f| {
                return f[self.float_idx];
            },
            .float3 => |f| {
                return f[self.float_idx];
            },
            else => return -std.math.inf(f32),
        }
    }
};
