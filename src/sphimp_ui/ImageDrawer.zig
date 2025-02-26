const sphimp = @import("sphimp");
const App = sphimp.App;
const gui = @import("sphui");
const sphrender = @import("sphrender");
const RenderAlloc = sphrender.RenderAlloc;
const ObjectId = sphimp.object.ObjectId;
const xyt = sphrender.xyt_program;
const PixelBBox = gui.PixelBBox;
const PixelSize = gui.PixelSize;
const InputState = gui.InputState;
const InputResponse = gui.InputResponse;
const UiAction = @import("ui_action.zig").UiAction;

const ImageDrawer = @This();

refs: Refs,
style: Style,
height: u31 = 0,
layout: *gui.grid.Grid(UiAction),
thumbnail_widget_alloc: RenderAlloc,
thumbnail_cache: ThumbnailCache,
drawer_widget: gui.Widget(UiAction),
drawer_state: DrawerState = .closed,

const widget_vtable = gui.Widget(UiAction).VTable{
    .render = ImageDrawer.render,
    .getSize = ImageDrawer.getSize,
    .update = ImageDrawer.update,
    .setInputState = ImageDrawer.setInputState,
    .setFocused = null,
    .reset = null,
};

pub fn init(
    app: *App,
    alloc: sphrender.RenderAlloc,
    squircle_renderer: *gui.SquircleRenderer,
    background_color: gui.Color,
    highlight_color: gui.Color,
    drawer_width: u31,
    thumbnail_shared: *const gui.thumbnail.Shared,
    frame_shared: *const gui.frame.Shared,
    scroll_style: *const gui.scrollbar.Style,
    interactable_shared: *const gui.interactable.Shared(UiAction),
) !*ImageDrawer {
    // With the frames in the list, an item pad is not necessary
    //
    // While there is technically no limit on number of objects, we can pick a
    // fairly large upper bound that practically will not be hit.
    // log(100000/100) / log(2) < 10, so for 10 expansions we get 100,000
    // objects. If this is ever a problem I have no idea what's happening
    const layout = try gui.grid.Grid(UiAction).init(alloc.heap, &.{ 1.0, 1.0, 1.0 }, 0, 100, 100000);
    const thumbnail_widget_alloc = try alloc.makeSubAlloc("thumbnail layout");

    const frame = try gui.frame.makeFrame(UiAction, alloc.heap.arena(), .{
        .inner = layout.asWidget(),
        .shared = frame_shared,
    });

    const scroll = try gui.scroll_view.ScrollView(UiAction).init(
        alloc.heap.arena(),
        frame,
        scroll_style,
        squircle_renderer,
    );

    const ret = try alloc.heap.arena().create(ImageDrawer);
    ret.* = .{
        .refs = .{
            .app = app,
            .squircle_renderer = squircle_renderer,
            .frame_shared = frame_shared,
            .thumbnail_shared = thumbnail_shared,
            .interactable_shared = interactable_shared,
        },
        .style = .{
            .background_color = background_color,
            .highlight_color = highlight_color,
            .drawer_width = drawer_width,
        },
        .thumbnail_widget_alloc = thumbnail_widget_alloc,
        .layout = layout,
        .thumbnail_cache = .{
            .alloc = try alloc.makeSubAlloc("thumbnail cache"),
        },
        .drawer_widget = scroll,
    };
    return ret;
}

pub fn asWidget(self: *ImageDrawer) gui.Widget(UiAction) {
    return .{
        .ctx = self,
        .name = "image_list",
        .vtable = &widget_vtable,
    };
}

fn render(ctx: ?*anyopaque, widget_bounds: PixelBBox, window_bounds: PixelBBox) void {
    const self: *ImageDrawer = @ptrCast(@alignCast(ctx));

    if (self.drawerBounds(widget_bounds)) |drawer_bounds| {
        self.refs.squircle_renderer.render(
            self.style.background_color,
            0,
            drawer_bounds,
            gui.util.widgetToClipTransform(drawer_bounds, window_bounds),
        );

        const inner_size = self.drawer_widget.getSize();
        const inner_bounds = PixelBBox{
            .top = widget_bounds.top,
            .left = widget_bounds.left,
            .right = widget_bounds.left + inner_size.width,
            .bottom = widget_bounds.top + inner_size.height,
        };
        self.drawer_widget.render(inner_bounds, window_bounds);
    }
}

fn getSize(ctx: ?*anyopaque) PixelSize {
    const self: *ImageDrawer = @ptrCast(@alignCast(ctx));
    const open_amount = switch (self.drawer_state) {
        .closed => 0.0,
        .opening, .closing => |amount| amount,
        .opened => 1.0,
    };
    return self.openSize(open_amount);
}

fn openSize(self: *ImageDrawer, open_amount: f32) PixelSize {
    return .{
        .width = @intFromFloat(open_amount * @as(f32, @floatFromInt(self.style.drawer_width))),
        .height = self.height,
    };
}

fn update(ctx: ?*anyopaque, available_size: PixelSize, delta_s: f32) anyerror!void {
    const self: *ImageDrawer = @ptrCast(@alignCast(ctx));
    self.height = available_size.height;

    self.animateOpenClose(delta_s);
    try self.thumbnail_cache.update(self.refs.app);
    try self.updateWidgets();

    switch (self.drawer_state) {
        .opening, .closing, .opened => {
            try self.drawer_widget.update(self.openSize(1.0), delta_s);
        },
        .closed => {},
    }
}

fn setInputState(ctx: ?*anyopaque, widget_bounds: PixelBBox, input_bounds: PixelBBox, input_state: InputState) InputResponse(UiAction) {
    const self: *ImageDrawer = @ptrCast(@alignCast(ctx));
    if (self.drawerBounds(widget_bounds)) |drawer_bounds| {
        const adjusted_input_bounds = input_bounds.calcIntersection(widget_bounds);
        return self.drawer_widget.setInputState(drawer_bounds, adjusted_input_bounds, input_state);
    }

    return InputResponse(UiAction){};
}

pub fn toggleOpenState(self: *ImageDrawer) void {
    switch (self.drawer_state) {
        .closed => {
            self.drawer_state = .{ .opening = 0.0 };
        },
        .opening => |open_amount| {
            self.drawer_state = .{ .closing = open_amount };
        },
        .closing => |open_amount| {
            self.drawer_state = .{ .opening = open_amount };
        },
        .opened => {
            self.drawer_state = .{ .closing = 1.0 };
        },
    }
}

fn drawerBounds(self: *ImageDrawer, widget_bounds: PixelBBox) ?PixelBBox {
    const open_amount = switch (self.drawer_state) {
        .closed => return null,
        .opened => 1.0,
        .opening, .closing => |amount| amount,
    };

    const drawer_width: u31 = @intFromFloat(open_amount * @as(f32, @floatFromInt(self.style.drawer_width)));
    return .{
        .left = widget_bounds.right - drawer_width,
        .right = widget_bounds.right,
        .top = widget_bounds.top,
        .bottom = widget_bounds.bottom,
    };
}

fn animateOpenClose(self: *ImageDrawer, delta_s: f32) void {
    const frame_step = 0.1;
    switch (self.drawer_state) {
        .opening => |*amount| {
            amount.* += delta_s / frame_step;
            if (amount.* >= 1.0) {
                self.drawer_state = .opened;
            }
        },
        .closing => |*amount| {
            amount.* -= delta_s / frame_step;
            if (amount.* <= 0.0) {
                self.drawer_state = .closed;
            }
        },
        .opened, .closed => {},
    }
}

fn updateWidgets(self: *ImageDrawer) !void {
    const num_items = self.refs.app.objects.numItems();
    if (self.layout.items.len != num_items) {
        self.layout.clear();
        try self.thumbnail_widget_alloc.reset();

        var thumbnail_factory = ThumbnailFactory{
            .alloc = self.thumbnail_widget_alloc,
            .parent = self,
            .objects = &self.refs.app.objects,
            .thumbnail_cache = &self.thumbnail_cache,
            .frame_renderer = self.refs.app.makeFrameRenderer(self.thumbnail_widget_alloc),
            .thumbnail_shared = self.refs.thumbnail_shared,
            .frame_shared = self.refs.frame_shared,
            .interactable_shared = self.refs.interactable_shared,
        };

        for (0..num_items) |idx| {
            try self.layout.pushWidget(
                try thumbnail_factory.makeThumbnail(idx),
            );
        }
    }
}

const ThumbnailFactory = struct {
    alloc: RenderAlloc,
    parent: *ImageDrawer,
    objects: *sphimp.object.Objects,
    thumbnail_cache: *ThumbnailCache,
    frame_renderer: sphimp.Renderer.FrameRenderer,
    thumbnail_shared: *const gui.thumbnail.Shared,
    interactable_shared: *const gui.interactable.Shared(UiAction),
    frame_shared: *const gui.frame.Shared,

    fn makeThumbnail(self: *ThumbnailFactory, idx: usize) !gui.Widget(UiAction) {
        const obj_id = self.thumbnail_cache.ids[idx];
        const thumbnail = try gui.thumbnail.makeThumbnail(
            UiAction,
            self.alloc.heap.arena(),
            ThumbnailRetriever{
                .cache = self.thumbnail_cache,
                .idx = idx,
            },
            self.thumbnail_shared,
        );

        const highlight = try gui.frame.makeColorableFrame(
            UiAction,
            self.alloc.heap.arena(),
            thumbnail,
            HighlightRetriever{
                .parent = self.parent,
                .id = obj_id,
            },
            self.frame_shared,
        );

        const box = try gui.box.box(
            UiAction,
            self.alloc.heap.arena(),
            highlight,
            .{
                .width = self.parent.style.drawer_width / 2,
                .height = self.parent.style.drawer_width / 2,
            },
            .fill_width,
        );

        return try gui.interactable.interactable(
            UiAction,
            self.alloc.heap.arena(),
            box,
            .{ .update_selected_object = obj_id },
            .{ .set_drag_source = obj_id },
            self.interactable_shared,
        );
    }
};

const ThumbnailRetriever = struct {
    cache: *ThumbnailCache,
    idx: usize,

    pub fn getSize(self: ThumbnailRetriever) PixelSize {
        return self.cache.sizes[self.idx];
    }

    pub fn getTexture(self: ThumbnailRetriever) sphrender.Texture {
        return self.cache.textures[self.idx];
    }
};

const HighlightRetriever = struct {
    parent: *const ImageDrawer,
    id: ObjectId,

    pub fn getColor(self: HighlightRetriever) ?gui.Color {
        if (self.parent.refs.app.selectedObjectId().value == self.id.value) {
            return self.parent.style.highlight_color;
        } else {
            return null;
        }
    }
};

const Style = struct {
    background_color: gui.Color,
    highlight_color: gui.Color,
    drawer_width: u31,
};

const Refs = struct {
    app: *App,
    squircle_renderer: *gui.SquircleRenderer,
    thumbnail_shared: *const gui.thumbnail.Shared,
    frame_shared: *const gui.frame.Shared,
    interactable_shared: *const gui.interactable.Shared(UiAction),
};

const DrawerState = union(enum) {
    closed,
    closing: f32,
    opening: f32,
    opened,

    pub fn actionIsOpen(self: @This()) bool {
        return switch (self) {
            .closed, .closing => true,
            .opened, .opening => false,
        };
    }
};

const ThumbnailCache = struct {
    alloc: RenderAlloc,
    ids: []ObjectId = &.{},
    textures: []sphrender.Texture = &.{},
    sizes: []PixelSize = &.{},

    fn update(self: *ThumbnailCache, app: *App) !void {
        self.ids = &.{};
        self.textures = &.{};
        self.sizes = &.{};
        try self.alloc.reset();

        const num_items = app.objects.numItems();
        const new_ids = try self.alloc.heap.arena().alloc(ObjectId, num_items);
        const new_textures = try self.alloc.heap.arena().alloc(sphrender.Texture, num_items);
        const new_sizes = try self.alloc.heap.arena().alloc(PixelSize, num_items);

        var fr = app.makeFrameRenderer(self.alloc);

        var it = app.objects.idIter();
        var idx: usize = 0;
        while (it.next()) |obj_id| {
            defer idx += 1;
            const obj = app.objects.get(obj_id);
            const dims = obj.dims(&app.objects);

            new_ids[idx] = obj_id;
            new_textures[idx] = try fr.renderObjectToTexture(obj.*);
            new_sizes[idx] = .{
                .width = @intCast(dims[0]),
                .height = @intCast(dims[1]),
            };
        }

        self.ids = new_ids;
        self.textures = new_textures;
        self.sizes = new_sizes;
    }
};
