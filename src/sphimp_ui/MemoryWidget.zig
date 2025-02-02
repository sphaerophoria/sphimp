const std = @import("std");
const Allocator = std.mem.Allocator;
const sphimp = @import("sphimp");
const sphutil = @import("sphutil");
const MemoryTracker = sphimp.MemoryTracker;
const sphrender = @import("sphrender");
const gui = @import("sphui");
const sphmath = @import("sphmath");
const ui_action = @import("ui_action.zig");
const sphalloc = @import("sphalloc");
const Sphalloc = sphalloc.Sphalloc;
const UiAction = ui_action.UiAction;
const Program = sphrender.shader_program.Program;
const Buffer = sphrender.shader_program.Buffer(Vert);
const gl = sphrender.gl;
const GlAlloc = sphrender.GlAlloc;

const MemoryWidget = @This();

// Layout
//   close button
//   Scroll area
//     PropertyList
//       key: name
//       val: graph
//
//     [ name, graph ]

item_alloc: gui.GuiAlloc,
scratch_alloc: *sphalloc.ScratchAlloc,
memory_tracker: *const MemoryTracker,
snapshot_alloc: *Sphalloc,
memory_tracker_snapshot: []MemoryTracker.AllocSamples = &.{},
program: Program(Vert, Uniform),
inner_widget: gui.Widget(UiAction),
property_list: *gui.property_list.PropertyList(UiAction),
size: gui.PixelSize = .{ .width = 0, .height = 0 },
guitext_shared: *const gui.gui_text.SharedState,

const widget_vtable = gui.Widget(UiAction).VTable{
    .render = MemoryWidget.render,
    .getSize = MemoryWidget.getSize,
    .update = MemoryWidget.update,
    .setInputState = MemoryWidget.setInputState,
    .setFocused = null,
    .reset = null,
};

pub fn init(
    alloc: gui.GuiAlloc,
    scratch_alloc: *sphalloc.ScratchAlloc,
    memory_tracker: *const MemoryTracker,
    prop_style: *const gui.property_list.Style,
    guitext_shared: *const gui.gui_text.SharedState,
    scrollbar_style: *const gui.scrollbar.Style,
    squircle_renderer: *const gui.SquircleRenderer,
) !MemoryWidget {
    const program = try Program(Vert, Uniform).init(alloc.gl, vertex_shader, fragment_shader);

    const property_list = try gui.property_list.PropertyList(UiAction).init(
        alloc.heap.arena(),
        prop_style,
        100,
    );

    const scroll = try gui.scroll_view.ScrollView(UiAction).init(
        alloc.heap.arena(),
        property_list.asWidget(),
        scrollbar_style,
        squircle_renderer,
    );

    const item_alloc = try alloc.makeSubAlloc("memory_widget_items");

    return .{
        .item_alloc = item_alloc,
        .scratch_alloc = scratch_alloc,
        .memory_tracker = memory_tracker,
        .snapshot_alloc = try alloc.heap.makeSubAlloc("memory_tracker_snapshot"),
        .program = program,
        .property_list = property_list,
        .inner_widget = scroll,
        .guitext_shared = guitext_shared,
    };
}

pub fn asWidget(self: *MemoryWidget) gui.Widget(UiAction) {
    return .{
        .ctx = self,
        .vtable = &widget_vtable,
    };
}

fn render(ctx: ?*anyopaque, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
    const self: *MemoryWidget = @ptrCast(@alignCast(ctx));

    var scissor = sphrender.TemporaryScissor.init();
    defer scissor.reset();

    scissor.set(
        widget_bounds.left,
        window_bounds.calcHeight() - widget_bounds.bottom,
        widget_bounds.calcWidth(),
        widget_bounds.calcHeight(),
    );

    gl.glClearColor(0.0, 0.0, 0.0, 1.0);
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);

    self.inner_widget.render(widget_bounds, window_bounds);
}

fn setInputState(ctx: ?*anyopaque, widget_bounds: gui.PixelBBox, input_bounds: gui.PixelBBox, input_state: gui.InputState) gui.InputResponse(UiAction) {
    const self: *MemoryWidget = @ptrCast(@alignCast(ctx));
    return self.inner_widget.setInputState(widget_bounds, input_bounds, input_state);
}

fn getSize(ctx: ?*anyopaque) gui.PixelSize {
    const self: *MemoryWidget = @ptrCast(@alignCast(ctx));
    return self.inner_widget.getSize();
}

fn update(ctx: ?*anyopaque, available_size: gui.PixelSize) anyerror!void {
    const self: *MemoryWidget = @ptrCast(@alignCast(ctx));

    self.size = available_size;

    const checkpoint = self.scratch_alloc.checkpoint();
    defer self.scratch_alloc.restore(checkpoint);

    const memory_tracker_elems = try self.memory_tracker.collect(self.scratch_alloc);

    {
        // Just in case
        self.memory_tracker_snapshot = &.{};
        try self.snapshot_alloc.reset();

        const arena = self.snapshot_alloc.arena();
        const new_snapshot = try arena.alloc(MemoryTracker.AllocSamples, memory_tracker_elems.len);
        for (0..new_snapshot.len) |i| {
            new_snapshot[i] = try memory_tracker_elems[i].clone(arena);
        }
        sortSnapshot(new_snapshot);
        self.memory_tracker_snapshot = new_snapshot;
    }

    // FIXME: ugly
    if (self.property_list.items.items.len != memory_tracker_elems.len) {
        self.property_list.clear();

        try self.item_alloc.reset();

        for (0..memory_tracker_elems.len) |i| {
            const label = try gui.label.makeLabel(
                UiAction,
                self.item_alloc,
                NameRetriever{ .parent = self, .idx = i },
                self.guitext_shared,
            );
            const graph = try self.item_alloc.heap.arena().create(Graph);
            const buffer = try self.program.makeBuffer(self.item_alloc.gl, &.{});

            try self.item_alloc.gl.registerVbo(buffer.vertex_buffer);
            try self.item_alloc.gl.registerVao(buffer.vertex_array);

            graph.* = .{
                .parent = self,
                .memory_tracker_idx = i,
                .width = 0,
                .buffer = buffer,
                .last_update_idx = 0,
            };
            try self.property_list.pushWidgets(graph.asWidget(), label);
        }
    }

    try self.inner_widget.update(available_size);
}

const NameRetriever = struct {
    parent: *MemoryWidget,
    idx: usize,

    buf: [200]u8 = undefined,

    pub fn getText(self: *NameRetriever) []const u8 {
        const snapshot = self.parent.memory_tracker_snapshot[self.idx];
        return std.fmt.bufPrint(&self.buf, "{s} ({d})", .{
            snapshot.name,
            std.fmt.fmtIntSizeBin(snapshot.samples[snapshot.samples.len - 1]),
        }) catch &self.buf;
    }
};

const Uniform = struct {
    transform: sphmath.Mat3x3,
};

const Vert = struct {
    vPos: sphmath.Vec2,
};

pub const vertex_shader =
    \\#version 330
    \\in vec2 vPos;
    \\uniform mat3x3 transform = mat3x3(
    \\    1.0, 0.0, 0.0,
    \\    0.0, 1.0, 0.0,
    \\    0.0, 0.0, 1.0
    \\);
    \\void main()
    \\{
    \\    vec3 transformed = transform * vec3(vPos, 1.0);
    \\    gl_Position = vec4(transformed.x, transformed.y, 0.0, transformed.z);
    \\}
;

pub const fragment_shader =
    \\#version 330
    \\out vec4 fragment;
    \\void main()
    \\{
    \\    fragment = vec4(1.0, 1.0, 1.0, 1.0);
    \\}
;

const graph_vtable = gui.Widget(UiAction).VTable{
    .render = Graph.render,
    .getSize = Graph.getSize,
    .update = Graph.update,
    .setInputState = null,
    .setFocused = null,
    .reset = null,
};

const Graph = struct {
    parent: *MemoryWidget,
    memory_tracker_idx: usize,
    width: u31,
    buffer: Buffer,
    last_update_idx: usize = 0,

    const graph_height = 100;

    fn asWidget(self: *Graph) gui.Widget(UiAction) {
        return .{
            .ctx = self,
            .vtable = &graph_vtable,
        };
    }

    fn render(ctx: ?*anyopaque, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
        const self: *Graph = @ptrCast(@alignCast(ctx));
        const transform = gui.util.widgetToClipTransform(widget_bounds, window_bounds);
        self.parent.program.render(self.buffer, .{ .transform = transform.inner });
    }

    fn getSize(ctx: ?*anyopaque) gui.PixelSize {
        const self: *Graph = @ptrCast(@alignCast(ctx));
        return .{
            .width = self.width,
            .height = graph_height,
        };
    }

    fn update(ctx: ?*anyopaque, available_size: gui.PixelSize) anyerror!void {
        const self: *Graph = @ptrCast(@alignCast(ctx));
        self.width = available_size.width;

        const graph_elem = self.parent.memory_tracker_snapshot[self.memory_tracker_idx];
        //if (self.last_update_idx == graph_elem.idx) {
        //    return;
        //}

        const max_sample_f: f32 = @floatFromInt(graph_elem.max);

        if (true) {
            const scratch = self.parent.scratch_alloc.allocator();

            const checkpoint = self.parent.scratch_alloc.checkpoint();
            defer self.parent.scratch_alloc.restore(checkpoint);

            var verts = try scratch.alloc(Vert, (graph_elem.samples.len - 1) * 6);
            @memset(verts, .{ .vPos = .{ 0, 0 } });
            var vert_idx: usize = 0;

            var last_elem = memorySampleToClip(graph_elem.samples[0], 0, max_sample_f, graph_elem.samples.len);

            for (graph_elem.samples[1..]) |sample| {
                const this_elem = memorySampleToClip(sample, vert_idx / 6, max_sample_f, graph_elem.samples.len);
                setLineSegment(last_elem, this_elem, verts[vert_idx .. vert_idx + 6]);
                last_elem = this_elem;
                vert_idx += 6;
            }

            self.buffer.updateBuffer(verts);
        } else {
            var verts: [6]Vert = undefined;
            setLineSegment(.{ -0.5, -0.5 }, .{ 0.5, 0.5 }, &verts);
            self.buffer.updateBuffer(&verts);
        }
    }
};

fn sortSnapshot(snapshot: []MemoryTracker.AllocSamples) void {
    const lessThan = struct {
        fn f(_: void, lhs: MemoryTracker.AllocSamples, rhs: MemoryTracker.AllocSamples) bool {
            return lhs.max > rhs.max;
        }
    }.f;
    std.sort.pdq(MemoryTracker.AllocSamples, snapshot, {}, lessThan);
}

fn setLineSegment(a: sphmath.Vec2, b: sphmath.Vec2, out: []Vert) void {
    const p1 = sphmath.Vec2{ a[0], -1.0 };
    const p2 = a;
    const p3 = b;
    const p4 = sphmath.Vec2{ b[0], -1.0 };

    out[0] = .{ .vPos = p1 };
    out[1] = .{ .vPos = p2 };
    out[2] = .{ .vPos = p3 };

    out[3] = .{ .vPos = p1 };
    out[4] = .{ .vPos = p3 };
    out[5] = .{ .vPos = p4 };
}

fn memorySampleToClip(sample: usize, vert_idx: usize, max_sample_f: f32, num_samples: usize) sphmath.Vec2 {
    const sample_f: f32 = @floatFromInt(sample);
    const x = 2.0 * @as(f32, @floatFromInt(vert_idx)) / @as(f32, @floatFromInt(num_samples -| 2)) - 1.0;
    const y = if (max_sample_f < 1e-7) -1 else 2.0 * sample_f / max_sample_f - 1.0;
    return .{ x, y };
}
