const std = @import("std");
const Allocator = std.mem.Allocator;
const sphimp = @import("sphimp");
const ObjectId = sphimp.object.ObjectId;
const App = sphimp.App;
const shader_storage = sphimp.shader_storage;
const ShaderStorage = shader_storage.ShaderStorage;
const ShaderId = shader_storage.ShaderId;
const FontStorage = sphimp.FontStorage;
const BrushId = shader_storage.BrushId;
const Renderer = sphimp.Renderer;
const sphrender = @import("sphrender");
const object_properties = @import("object_properties.zig");
const label_adaptors = @import("label_adaptors.zig");
const float_adaptors = @import("float_adaptors.zig");
const color_adaptors = @import("color_adaptors.zig");
const gui = @import("sphui");
const ui_action = @import("ui_action.zig");
const UiAction = ui_action.UiAction;
const list_io = @import("list_io.zig");
const WidgetFactory = gui.widget_factory.WidgetFactory(UiAction);
const sphalloc = @import("sphalloc");
const Sphalloc = sphalloc.Sphalloc;
const GlAlloc = sphrender.GlAlloc;
const ScratchAlloc = sphalloc.ScratchAlloc;
const TreeView = @import("TreeView.zig");

fn wrapFrameScrollView(widget_factory: WidgetFactory, inner: gui.Widget(UiAction)) !gui.Widget(UiAction) {
    const frame = try widget_factory.makeFrame(inner);
    return try widget_factory.makeScrollView(frame);
}

fn addShaderParamsToPropertyList(app: *App, selected_object: ObjectId, property_list: anytype, widget_factory: gui.widget_factory.WidgetFactory(UiAction), uniforms: sphrender.shader_program.UnknownUniforms) !void {
    const property_widget_gen = object_properties.PropertyWidgetGenerator{
        .app = app,
        .selected_object = selected_object,
        .widget_factory = widget_factory,
        .property_list = property_list,
    };

    for (0..uniforms.items.len) |i| {
        const uniform = uniforms.items[i];

        switch (uniform.default) {
            .image => {
                try property_widget_gen.addImageToPropertyList(i, uniforms.items[i].name);
            },
            .float => {
                try property_widget_gen.addFloatToPropertyList(i, uniforms.items[i].name);
            },
            .float2 => {
                try property_widget_gen.addFloat2ToPropertyList(i, uniforms.items[i].name);
            },
            .float3 => {
                try property_widget_gen.addFloat3ToPropertyList(i, uniforms.items[i].name);
            },
            else => {
                const uniform_label = try widget_factory.makeLabel(uniform.name);
                const value_widget = try widget_factory.makeLabel("unimplemented");
                try property_list.pushWidget(uniform_label);
                try property_list.pushWidget(value_widget);
            },
        }
    }
}

const ObjectProperties = struct {
    widget: gui.Widget(UiAction),
    specific_properties: *gui.layout.Layout(UiAction),
};

fn makeObjectProperties(app: *App, selected_object: *ObjectId, widget_factory: gui.widget_factory.WidgetFactory(UiAction)) !ObjectProperties {
    const layout = blk: {
        const layout = try widget_factory.makeLayout();

        const layout_name = try widget_factory.makeLabel("Object properties");
        try layout.pushWidget(layout_name);

        const property_list = try widget_factory.makePropertyList(8);
        try layout.pushWidget(property_list.asWidget());

        {
            const name_label = try widget_factory.makeLabel("Name");
            const name_box = try widget_factory.makeTextbox(
                label_adaptors.SelectedObjectName.init(app, selected_object),
                ui_action.TextEditRequestGenerator(.edit_object_name){ .id = selected_object },
            );
            try property_list.pushWidget(name_label);
            try property_list.pushWidget(name_box);
        }

        {
            const delete_button = try widget_factory.makeButton(
                "Delete",
                ui_action.DeleteObjectGenerator{ .id = selected_object },
            );
            try property_list.pushWidget(gui.null_widget.makeNull(UiAction));
            try property_list.pushWidget(delete_button);
        }

        {
            const label = try widget_factory.makeLabel("Width");
            const value = try widget_factory.makeLabel(label_adaptors.SelectedObjectWidth.init(app, selected_object));
            try property_list.pushWidget(label);
            try property_list.pushWidget(value);
        }

        {
            const label = try widget_factory.makeLabel("Height");
            const value = try widget_factory.makeLabel(label_adaptors.SelectedObjectHeight.init(app, selected_object));
            try property_list.pushWidget(label);
            try property_list.pushWidget(value);
        }

        break :blk layout;
    };

    const specific_layout = try widget_factory.makeLayout();
    try layout.pushWidget(specific_layout.asWidget());
    const widget = try wrapFrameScrollView(widget_factory, layout.asWidget());

    return .{
        .widget = widget,
        .specific_properties = specific_layout,
    };
}

pub const Handle = struct {
    removable_content_alloc: gui.GuiAlloc,
    // Note that these widgets are owned by the sidebar, not by us
    object_properties: gui.Widget(UiAction),
    specific_object_properties: *gui.layout.Layout(UiAction),
    tree_view: gui.Widget(UiAction),

    brush_icon: TextureRetriever,
    eraser_icon: TextureRetriever,

    app: *App,
    removable_content_widget_factory: WidgetFactory,
    property_object_id: *sphimp.object.ObjectId,

    pub fn notifyObjectChanged(self: Handle) void {
        // When objects change, we re-use the same widgets, but users expect
        // widgets to behave as if they were new (textbox cursor position as if
        // new, etc.)
        self.object_properties.reset();
    }

    /// Items in the property list don't use the typical widget update() path
    /// to re-generate the widget list. We need to tell the object list that
    /// the items in the property list may have changed, and we have to
    /// re-generate
    pub fn updateObjectProperties(self: Handle) !void {
        self.specific_object_properties.clear();

        try self.removable_content_alloc.reset();

        const property_list = try self.removable_content_widget_factory.makePropertyList(50);
        try self.specific_object_properties.pushWidget(property_list.asWidget());

        const selected_obj = self.app.objects.get(self.property_object_id.*);

        {
            const type_label_key = try self.removable_content_widget_factory.makeLabel("Object type");
            const type_label_value = try self.removable_content_widget_factory.makeLabel(@tagName(selected_obj.data));
            try property_list.pushWidget(type_label_key);
            try property_list.pushWidget(type_label_value);
        }

        switch (selected_obj.data) {
            .filesystem => |fs_obj| {
                {
                    const source_key = try self.removable_content_widget_factory.makeLabel("Source");
                    const source_value = try self.removable_content_widget_factory.makeLabel(fs_obj.source);
                    try property_list.pushWidget(source_key);
                    try property_list.pushWidget(source_value);
                }
            },
            .generated_mask => {},
            .composition => |comp| {
                {
                    const width_label = try self.removable_content_widget_factory.makeLabel("Width");
                    const width_dragger = try self.removable_content_widget_factory.makeDragFloat(
                        float_adaptors.SelectedObjectWidth.init(self.app, self.property_object_id),
                        ui_action.bundledFloatParam(.update_composition_width, "width", .{ .object = self.property_object_id.* }),
                        1.0,
                    );
                    try property_list.pushWidget(width_label);
                    try property_list.pushWidget(width_dragger);
                }

                {
                    const height_label = try self.removable_content_widget_factory.makeLabel("Height");
                    const height_dragger = try self.removable_content_widget_factory.makeDragFloat(
                        float_adaptors.SelectedObjectHeight.init(self.app, self.property_object_id),
                        ui_action.bundledFloatParam(.update_composition_height, "height", .{ .object = self.property_object_id.* }),
                        1.0,
                    );
                    try property_list.pushWidget(height_label);
                    try property_list.pushWidget(height_dragger);
                }

                {
                    const debug_label = try self.removable_content_widget_factory.makeLabel("Debug");

                    const CheckedRetriever = struct {
                        app: *App,

                        pub fn checked(r: @This()) bool {
                            return r.app.tool_params.composition_debug;
                        }
                    };

                    const debug_checkbox = try self.removable_content_widget_factory.makeCheckbox(
                        CheckedRetriever{ .app = self.app },
                        UiAction.toggle_composition_debug,
                    );
                    try property_list.pushWidget(debug_label);
                    try property_list.pushWidget(debug_checkbox);
                }

                for (0..comp.objects.items.len) |comp_idx| {
                    const name_label = try self.removable_content_widget_factory.makeLabel(label_adaptors.CompositionObjName.init(self.app, self.property_object_id.*, comp_idx));
                    const delete_button = try self.removable_content_widget_factory.makeButton(
                        "Delete",
                        UiAction{
                            .delete_from_composition = .{
                                .composition = self.property_object_id.*,
                                .idx = .{ .value = comp_idx },
                            },
                        },
                    );
                    try property_list.pushWidget(name_label);
                    try property_list.pushWidget(delete_button);
                }
            },
            .shader => |s| {
                const shader = self.app.shaders.get(s.program);
                try addShaderParamsToPropertyList(self.app, self.property_object_id.*, property_list, self.removable_content_widget_factory, shader.uniforms);
            },
            .drawing => |d| {
                {
                    const source_label = try self.removable_content_widget_factory.makeLabel("Source object");

                    const preview = try self.removable_content_widget_factory.makeLabel(
                        label_adaptors.DrawingDisplayObjectName{ .app = self.app, .id = self.property_object_id.* },
                    );

                    const combobox = try self.removable_content_widget_factory.makeComboBox(
                        preview,
                        UpdateDrawingSourceListGenerator{
                            .widget_state = self.removable_content_widget_factory.state,
                            .app = self.app,
                            .drawing = self.property_object_id.*,
                        },
                    );
                    try property_list.pushWidget(source_label);
                    try property_list.pushWidget(combobox);
                }

                try self.specific_object_properties.pushWidget(try self.removable_content_widget_factory.makeLabel("Tools"));

                const tools = try self.removable_content_widget_factory.makeLayout();
                tools.cursor.direction = .left_to_right;
                try self.specific_object_properties.pushWidget(tools.asWidget());

                try tools.pushWidget(try makeDrawingToolOption(
                    self.removable_content_widget_factory,
                    self.brush_icon,
                    .brush,
                    self.app,
                ));
                try tools.pushWidget(try makeDrawingToolOption(
                    self.removable_content_widget_factory,
                    self.eraser_icon,
                    .eraser,
                    self.app,
                ));

                const brush_params = blk: {
                    const layout = try self.removable_content_widget_factory.makeLayout();
                    try layout.pushWidget(
                        try self.removable_content_widget_factory.makeLabel("Brush parameters"),
                    );

                    const params_list = try self.removable_content_widget_factory.makePropertyList(50);
                    try layout.pushWidget(params_list.asWidget());

                    const source_label = try self.removable_content_widget_factory.makeLabel("Brush");

                    const value_widget = try self.removable_content_widget_factory.makeComboBox(
                        try self.removable_content_widget_factory.makeLabel(
                            label_adaptors.SelectedBrushName{ .app = self.app, .id = self.property_object_id.* },
                        ),
                        BrushListGenerator{
                            .app = self.app,
                            .id = self.property_object_id.*,
                            .state = self.removable_content_widget_factory.state,
                        },
                    );
                    try params_list.pushWidget(source_label);
                    try params_list.pushWidget(value_widget);

                    const brush = self.app.brushes.get(d.brush);
                    try addShaderParamsToPropertyList(
                        self.app,
                        self.property_object_id.*,
                        params_list,
                        self.removable_content_widget_factory,
                        brush.uniforms,
                    );
                    break :blk layout.asWidget();
                };

                const eraser_params = blk: {
                    const layout = try self.removable_content_widget_factory.makeLayout();
                    try layout.pushWidget(
                        try self.removable_content_widget_factory.makeLabel("Eraser parameters"),
                    );

                    const params_list = try self.removable_content_widget_factory.makePropertyList(2);
                    try layout.pushWidget(params_list.asWidget());

                    const size_label = try self.removable_content_widget_factory.makeLabel("Size");

                    const value_widget = try self.removable_content_widget_factory.makeDragFloat(
                        EraserSizeRetriever{ .app = self.app },
                        &UiAction.makeChangeEraserSize,
                        0.001,
                    );

                    try params_list.pushWidget(size_label);
                    try params_list.pushWidget(value_widget);

                    break :blk layout.asWidget();
                };

                const selected_tool_retriever = SelectedToolIdx{
                    .app = self.app,
                };

                const params = try self.removable_content_widget_factory.makeOneOf(selected_tool_retriever, &.{ brush_params, eraser_params });
                try self.specific_object_properties.pushWidget(params);
            },
            .path => {
                const source_label = try self.removable_content_widget_factory.makeLabel("Source object");

                const value_widget = try self.removable_content_widget_factory.makeComboBox(
                    try self.removable_content_widget_factory.makeLabel(
                        label_adaptors.PathDisplayObjectName{ .app = self.app, .id = self.property_object_id.* },
                    ),
                    UpdatePathSourceListGenerator{
                        .widget_state = self.removable_content_widget_factory.state,
                        .app = self.app,
                        .path = self.property_object_id.*,
                    },
                );

                try property_list.pushWidget(source_label);
                try property_list.pushWidget(value_widget);
            },
            .text => |*t| {
                {
                    const key = try self.removable_content_widget_factory.makeLabel("Text");
                    const value_widget = try self.removable_content_widget_factory.makeTextbox(
                        label_adaptors.TextObjectContent.init(self.app, self.property_object_id.*),
                        ui_action.TextEditRequestGenerator(.edit_text_obj_content){ .id = self.property_object_id },
                    );
                    try property_list.pushWidget(key);
                    try property_list.pushWidget(value_widget);
                }

                {
                    const key = try self.removable_content_widget_factory.makeLabel("Font");
                    const value_widget = try self.removable_content_widget_factory.makeComboBox(
                        try self.removable_content_widget_factory.makeLabel(
                            label_adaptors.TextObjectFont{ .app = self.app, .id = self.property_object_id.* },
                        ),
                        FontListGenerator{
                            .widget_state = self.removable_content_widget_factory.state,
                            .app = self.app,
                            .id = self.property_object_id.*,
                        },
                    );
                    try property_list.pushWidget(key);
                    try property_list.pushWidget(value_widget);
                }

                {
                    const key = try self.removable_content_widget_factory.makeLabel("Font size");
                    const value_widget = try self.removable_content_widget_factory.makeDragFloat(
                        &t.renderer.point_size,
                        ui_action.UpdateTextSizeGenerator{ .id = self.property_object_id.* },
                        0.05,
                    );
                    try property_list.pushWidget(key);
                    try property_list.pushWidget(value_widget);
                }
            },
        }
    }
};

fn makeDrawingToolOption(factory: WidgetFactory, icon: TextureRetriever, tool: sphimp.tool.DrawingTool, app: *App) !gui.Widget(UiAction) {
    const thumbnail = try factory.makeThumbnail(icon);
    const box = try factory.makeBox(thumbnail, .{ .width = 24, .height = 24 }, .fill_none);
    const clickable = try factory.makeInteractable(
        box,
        .{ .set_drawing_tool = tool },
        null,
    );

    const background_color = ToolHighlightRetriever{
        .app = app,
        .desired = tool,
        .color = gui.widget_factory.StyleColors.default_color,
    };

    const rect = try factory.makeRect(background_color, factory.state.corner_radius);

    const stack = try factory.makeStack(2);
    try stack.pushWidget(rect, .{ .size_policy = .match_siblings });
    try stack.pushWidget(clickable, .{});
    return stack.asWidget();
}

const ToolHighlightRetriever = struct {
    app: *App,
    desired: sphimp.tool.DrawingTool,
    color: gui.Color,

    pub fn getColor(self: ToolHighlightRetriever) ?gui.Color {
        if (self.app.tool_params.active_drawing_tool == self.desired) {
            return self.color;
        } else {
            return null;
        }
    }
};

const SelectedToolIdx = struct {
    app: *App,

    pub fn get(self: @This()) usize {
        return switch (self.app.tool_params.active_drawing_tool) {
            .brush => 0,
            .eraser => 1,
        };
    }
};

const EraserSizeRetriever = struct {
    app: *App,

    pub fn getVal(r: @This()) f32 {
        return r.app.tool_params.eraser_width;
    }
};

pub const Sidebar = struct {
    widget: gui.Widget(UiAction),
    handle: Handle,
};

pub fn makeSidebar(sidebar_alloc: gui.GuiAlloc, scratch: *ScratchAlloc, app: *App, tree_view_object: *ObjectId, sidebar_width: u31, widget_state: *gui.widget_factory.WidgetState(UiAction)) !Sidebar {
    const removable_content_alloc = try sidebar_alloc.makeSubAlloc("sidebar_content");

    const selected_object = try sidebar_alloc.heap.arena().create(sphimp.object.ObjectId);
    selected_object.* = tree_view_object.*;

    const full_factory = widget_state.factory(sidebar_alloc);
    const removable_factory = widget_state.factory(removable_content_alloc);

    const sidebar_stack = try full_factory.makeStack(2);

    const sidebar_box = try full_factory.makeBox(
        sidebar_stack.asWidget(),
        .{ .width = sidebar_width, .height = 0 },
        .fill_height,
    );

    const sidebar_background = try full_factory.makeRect(
        gui.widget_factory.StyleColors.background_color,
        1.0,
    );

    try sidebar_stack.pushWidget(
        sidebar_background,
        .{},
    );

    const layout = try full_factory.makeLayout();
    try sidebar_stack.pushWidget(layout.asWidget(), .{});

    const tree_view = try TreeView.init(
        sidebar_alloc,
        scratch,
        app,
        &widget_state.thumbnail_shared,
        tree_view_object,
        &widget_state.frame_shared,
    );
    try layout.pushWidget(tree_view);

    const properties = try makeObjectProperties(app, selected_object, full_factory);
    try layout.pushWidget(properties.widget);

    const brush_icon = try loadTexture(sidebar_alloc.gl, @embedFile("res/brush.png"));
    const eraser_icon = try loadTexture(sidebar_alloc.gl, @embedFile("res/eraser.png"));

    var handle = Handle{
        .removable_content_alloc = removable_content_alloc,
        .object_properties = properties.widget,
        .specific_object_properties = properties.specific_properties,

        .brush_icon = brush_icon,
        .eraser_icon = eraser_icon,

        .app = app,
        .removable_content_widget_factory = removable_factory,
        .property_object_id = selected_object,
        .tree_view = tree_view,
    };

    try handle.updateObjectProperties();

    return .{
        .widget = sidebar_box,
        .handle = handle,
    };
}

const TextureRetriever = struct {
    size: gui.PixelSize,
    texture: sphrender.Texture,

    pub fn getTexture(self: TextureRetriever) sphrender.Texture {
        return self.texture;
    }

    pub fn getSize(self: TextureRetriever) gui.PixelSize {
        return self.size;
    }
};

fn loadTexture(gl_alloc: *GlAlloc, data: []const u8) !TextureRetriever {
    const image = try sphimp.StbImage.initData(data);
    defer image.deinit();

    const texture = try sphrender.makeTextureFromRgba(gl_alloc, image.data, image.width);
    const size = gui.PixelSize{
        .width = @intCast(image.width),
        .height = @intCast(image.calcHeight()),
    };

    return .{
        .texture = texture,
        .size = size,
    };
}

const FontListGenerator = struct {
    widget_state: *gui.widget_factory.WidgetState(UiAction),
    app: *App,
    id: ObjectId,

    const ListCtx = struct {
        app: *App,
        id: ObjectId,

        pub fn makeIt(self: ListCtx) FontStorage.IdIter {
            return self.app.fonts.idIter();
        }

        pub fn makeAction(self: ListCtx, font_id: FontStorage.FontId) UiAction {
            return .{ .update_selected_font = .{
                .object = self.id,
                .font = font_id,
            } };
        }
    };

    pub fn makeWidget(self: FontListGenerator, alloc: gui.GuiAlloc) !gui.Widget(UiAction) {
        const factory = self.widget_state.factory(alloc);
        return try factory.makeSelectableList(
            list_io.FontRetriever{ .app = self.app, .id = self.id },
            list_io.itListAction(ListCtx{ .app = self.app, .id = self.id }),
        );
    }
};

const PathDisplayObjectCtx = struct {
    id: ObjectId,
    pub fn selectedObject(self: @This(), a: *App) ?ObjectId {
        var obj = a.objects.get(self.id);
        const path = obj.asPath() orelse return null;
        return path.display_object;
    }
};

const DrawingDisplayObjectCtx = struct {
    id: ObjectId,
    pub fn selectedObject(self: @This(), a: *App) ?ObjectId {
        var obj = a.objects.get(self.id);
        const path = obj.asDrawing() orelse return null;
        return path.display_object;
    }
};

const UpdatePathSourceListGenerator = struct {
    widget_state: *gui.widget_factory.WidgetState(UiAction),
    app: *App,
    path: ObjectId,

    const RetrieverCtx = struct {
        path: ObjectId,

        pub fn selectedObject(self: RetrieverCtx, app: *App) ?ObjectId {
            const path = app.objects.get(self.path).asPath() orelse return null;
            return path.display_object;
        }
    };

    const ListCtx = struct {
        app: *App,
        id: ObjectId,

        pub fn makeIt(self: ListCtx) sphimp.object.Objects.IdIter {
            return self.app.objects.idIter();
        }

        pub fn makeAction(self: ListCtx, source: ObjectId) UiAction {
            return .{
                .update_path_source = .{
                    .object = self.id,
                    .source = source,
                },
            };
        }
    };

    pub fn makeWidget(self: @This(), alloc: gui.GuiAlloc) !gui.Widget(UiAction) {
        const factory = self.widget_state.factory(alloc);
        return try factory.makeSelectableList(
            list_io.objectListRetriever(RetrieverCtx{ .path = self.path }, self.app),
            list_io.itListAction(ListCtx{ .app = self.app, .id = self.path }),
        );
    }
};

const UpdateDrawingSourceListGenerator = struct {
    widget_state: *gui.widget_factory.WidgetState(UiAction),
    app: *App,
    drawing: ObjectId,

    const RetrieverCtx = struct {
        drawing: ObjectId,

        pub fn selectedObject(self: RetrieverCtx, app: *App) ?ObjectId {
            const drawing = app.objects.get(self.drawing).asPath() orelse return null;
            return drawing.display_object;
        }
    };

    const ListCtx = struct {
        app: *App,
        id: ObjectId,

        pub fn makeIt(self: ListCtx) sphimp.object.Objects.IdIter {
            return self.app.objects.idIter();
        }

        pub fn makeAction(self: ListCtx, source: ObjectId) UiAction {
            return .{
                .update_drawing_source = .{
                    .drawing = self.id,
                    .source = source,
                },
            };
        }
    };

    pub fn makeWidget(self: @This(), alloc: gui.GuiAlloc) !gui.Widget(UiAction) {
        const factory = self.widget_state.factory(alloc);
        return try factory.makeSelectableList(
            list_io.objectListRetriever(RetrieverCtx{ .drawing = self.drawing }, self.app),
            list_io.itListAction(ListCtx{ .app = self.app, .id = self.drawing }),
        );
    }
};

const BrushListGenerator = struct {
    state: *gui.widget_factory.WidgetState(UiAction),
    app: *App,
    id: ObjectId,

    const ListCtx = struct {
        app: *App,
        id: ObjectId,

        pub fn makeIt(self: ListCtx) sphimp.shader_storage.ShaderStorage(sphimp.shader_storage.BrushId).ShaderIdIterator {
            return self.app.brushes.idIter();
        }

        pub fn makeAction(self: ListCtx, id: sphimp.shader_storage.BrushId) UiAction {
            return .{
                .update_brush = .{
                    .object = self.id,
                    .brush = id,
                },
            };
        }
    };

    pub fn makeWidget(self: BrushListGenerator, alloc: gui.GuiAlloc) !gui.Widget(UiAction) {
        const factory = self.state.factory(alloc);
        return try factory.makeSelectableList(
            list_io.BrushRetriever.init(self.app, self.id),
            list_io.itListAction(ListCtx{ .app = self.app, .id = self.id }),
        );
    }
};
