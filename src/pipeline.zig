// pipeline.zig
const std = @import("std");
const vk = @import("vulkan");
const Vertex = @import("mesh.zig").Vertex;
const GraphicsContext = @import("core.zig").GraphicsContext;

const Self = @This();

layout: vk.PipelineLayout,
handle: vk.Pipeline,
dsl: vk.DescriptorSetLayout,

pub const Config = struct {
    vert_spv: []const u8,
    frag_spv: []const u8,
    color_format: vk.Format,
    depth_format: vk.Format = .d32_sfloat,
    bindings: []const vk.DescriptorSetLayoutBinding,
    push_constant_ranges: []const vk.PushConstantRange = &.{},

    // Vertex input
    vertex_input: enum { mesh, none } = .mesh,

    // Rasterizer
    cull_mode: vk.CullModeFlags = .{ .back_bit = true },
    front_face: vk.FrontFace = .counter_clockwise,

    // Depth
    depth_test: bool = true,
    depth_write: bool = true,
    depth_compare_op: vk.CompareOp = .less,
};

pub fn init(gc: *GraphicsContext, cfg: Config) !Self {
    const dsl = try gc.dev.createDescriptorSetLayout(&.{
        .flags = .{ .push_descriptor_bit = true },
        .binding_count = @intCast(cfg.bindings.len),
        .p_bindings = cfg.bindings.ptr,
    }, null);
    errdefer gc.dev.destroyDescriptorSetLayout(dsl, null);

    const layout = try gc.dev.createPipelineLayout(&.{
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&dsl),
        .push_constant_range_count = @intCast(cfg.push_constant_ranges.len),
        .p_push_constant_ranges = cfg.push_constant_ranges.ptr,
    }, null);
    errdefer gc.dev.destroyPipelineLayout(layout, null);

    const handle = try createPipeline(gc, layout, cfg);
    return .{ .dsl = dsl, .layout = layout, .handle = handle };
}

pub fn deinit(self: Self, gc: *GraphicsContext) void {
    gc.dev.destroyPipeline(self.handle, null);
    gc.dev.destroyPipelineLayout(self.layout, null);
    gc.dev.destroyDescriptorSetLayout(self.dsl, null);
}

fn createPipeline(gc: *GraphicsContext, layout: vk.PipelineLayout, cfg: Config) !vk.Pipeline {
    const vert = try gc.dev.createShaderModule(&.{
        .code_size = cfg.vert_spv.len,
        .p_code = @ptrCast(@alignCast(cfg.vert_spv.ptr)),
    }, null);
    defer gc.dev.destroyShaderModule(vert, null);

    const frag = try gc.dev.createShaderModule(&.{
        .code_size = cfg.frag_spv.len,
        .p_code = @ptrCast(@alignCast(cfg.frag_spv.ptr)),
    }, null);
    defer gc.dev.destroyShaderModule(frag, null);

    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex_bit = true }, .module = vert, .p_name = "main" },
        .{ .stage = .{ .fragment_bit = true }, .module = frag, .p_name = "main" },
    };

    const pvisci: vk.PipelineVertexInputStateCreateInfo = switch (cfg.vertex_input) {
        .mesh => .{
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = @ptrCast(&Vertex.binding_description),
            .vertex_attribute_description_count = Vertex.attribute_description.len,
            .p_vertex_attribute_descriptions = &Vertex.attribute_description,
        },
        .none => .{
            .vertex_binding_description_count = 0,
            .p_vertex_binding_descriptions = undefined,
            .vertex_attribute_description_count = 0,
            .p_vertex_attribute_descriptions = undefined,
        },
    };

    const dynstate = [_]vk.DynamicState{ .viewport, .scissor };
    const pcbas = vk.PipelineColorBlendAttachmentState{
        .blend_enable = .false,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };

    const gpci = vk.GraphicsPipelineCreateInfo{
        .flags = .{},
        .p_next = &vk.PipelineRenderingCreateInfo{
            .color_attachment_count = 1,
            .p_color_attachment_formats = @ptrCast(&cfg.color_format),
            .depth_attachment_format = cfg.depth_format,
            .stencil_attachment_format = .undefined,
            .view_mask = 0,
        },
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &pvisci,
        .p_input_assembly_state = &.{ .topology = .triangle_list, .primitive_restart_enable = .false },
        .p_tessellation_state = null,
        .p_viewport_state = &.{
            .viewport_count = 1,
            .p_viewports = undefined,
            .scissor_count = 1,
            .p_scissors = undefined,
        },
        .p_rasterization_state = &.{
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = cfg.cull_mode,
            .front_face = cfg.front_face,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 1,
        },
        .p_multisample_state = &.{
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = .false,
            .min_sample_shading = 1,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        },
        .p_depth_stencil_state = &.{
            .depth_test_enable = if (cfg.depth_test) .true else .false,
            .depth_write_enable = if (cfg.depth_write) .true else .false,
            .depth_compare_op = cfg.depth_compare_op,
            .depth_bounds_test_enable = .false,
            .stencil_test_enable = .false,
            .front = undefined,
            .back = undefined,
            .min_depth_bounds = 0.0,
            .max_depth_bounds = 1.0,
        },
        .p_color_blend_state = &.{
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&pcbas),
            .blend_constants = [_]f32{ 0, 0, 0, 0 },
        },
        .p_dynamic_state = &.{
            .dynamic_state_count = dynstate.len,
            .p_dynamic_states = &dynstate,
        },
        .layout = layout,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var pipeline: vk.Pipeline = undefined;
    _ = try gc.dev.createGraphicsPipelines(.null_handle, 1, @ptrCast(&gpci), null, @ptrCast(&pipeline));
    return pipeline;
}
