extends SceneTree
## GPU-driven fork probe: an UNBOUNDED texture binding indexed with nonuniformEXT, filled partly at
## creation and partly through uniform_set_update_texture, drawn through draw_list_draw_indirect_count
## with the count read from a buffer, and read back pixel by pixel. Windowed only (RD needs a device).

const W := 64
const H := 16
const COLUMNS := 8 # eight indirect commands, one quad each
const COUNT := 4 # the count buffer admits only the first four

var rd: RenderingDevice
var failures := 0


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		failures += 1
		print("  FAIL ", what)


func solid_texture(color: Color) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.width = 4
	fmt.height = 4
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var bytes := PackedByteArray()
	for i in 16:
		bytes.append_array(PackedByteArray([int(color.r * 255), int(color.g * 255), int(color.b * 255), 255]))
	return rd.texture_create(fmt, RDTextureView.new(), [bytes])


func pixel(data: PackedByteArray, x: int, y: int) -> Color:
	var o := (y * W + x) * 4
	return Color8(data[o], data[o + 1], data[o + 2], data[o + 3])


func same(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.02 and absf(a.g - b.g) < 0.02 and absf(a.b - b.b) < 0.02


func _initialize() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null:
		print("FAIL: no RenderingDevice (headless?)")
		quit(1)
		return
	print("capacity = ", rd.uniform_set_unbounded_capacity())
	check(rd.uniform_set_unbounded_capacity() > 0, "driver reports an unbounded capacity")

	# --- shader: procedural quads, one per instance, colour from textures[nonuniformEXT(instance)]
	var src := RDShaderSource.new()
	src.source_vertex = """#version 450
layout(location = 0) out flat uint v_index;
void main() {
	const vec2 corners[6] = vec2[](vec2(0,0), vec2(1,0), vec2(1,1), vec2(0,0), vec2(1,1), vec2(0,1));
	float column = float(gl_InstanceIndex);
	vec2 c = corners[gl_VertexIndex];
	float x0 = -1.0 + column * 0.25;
	gl_Position = vec4(x0 + c.x * 0.25, -1.0 + c.y * 2.0, 0.0, 1.0);
	v_index = uint(gl_InstanceIndex);
}
"""
	src.source_fragment = """#version 450
#extension GL_EXT_nonuniform_qualifier : require
layout(set = 0, binding = 0) uniform sampler s;
layout(set = 0, binding = 1) uniform texture2D textures[];
layout(location = 0) in flat uint v_index;
layout(location = 0) out vec4 o_color;
void main() {
	o_color = texture(sampler2D(textures[nonuniformEXT(v_index)], s), vec2(0.5));
}
"""
	var spirv := rd.shader_compile_spirv_from_source(src)
	check(spirv.compile_error_vertex == "" and spirv.compile_error_fragment == "", "shader compiles (nonuniformEXT + runtime array)")
	if spirv.compile_error_vertex != "" or spirv.compile_error_fragment != "":
		print(spirv.compile_error_vertex, spirv.compile_error_fragment)
		quit(1)
		return
	var shader := rd.shader_create_from_spirv(spirv)
	check(shader.is_valid(), "shader with an unbounded binding is accepted")

	# --- textures and the set: slots 0 and 1 at creation, 2 and 3 through the partial update
	var red := solid_texture(Color.RED)
	var green := solid_texture(Color.GREEN)
	var blue := solid_texture(Color.BLUE)
	var white := solid_texture(Color.WHITE)
	var yellow := solid_texture(Color.YELLOW)

	var sampler_state := RDSamplerState.new()
	var sampler := rd.sampler_create(sampler_state)
	var u_sampler := RDUniform.new()
	u_sampler.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER
	u_sampler.binding = 0
	u_sampler.add_id(sampler)
	var u_textures := RDUniform.new()
	u_textures.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE
	u_textures.binding = 1
	u_textures.add_id(red)
	u_textures.add_id(green)
	var uset := rd.uniform_set_create([u_sampler, u_textures], shader, 0)
	check(uset.is_valid(), "uniform set with 2 of N slots filled is created")
	rd.uniform_set_update_texture(uset, 1, 2, blue)
	rd.uniform_set_update_texture(uset, 1, 3, white)

	# --- render target, pipeline, indirect + count buffers
	var rt_fmt := RDTextureFormat.new()
	rt_fmt.width = W
	rt_fmt.height = H
	rt_fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	rt_fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var rt := rd.texture_create(rt_fmt, RDTextureView.new())
	var fb := rd.framebuffer_create([rt])
	var blend := RDPipelineColorBlendState.new()
	blend.attachments = [RDPipelineColorBlendStateAttachment.new()]
	var pipeline := rd.render_pipeline_create(shader, rd.framebuffer_get_format(fb), -1, RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, RDPipelineRasterizationState.new(), RDPipelineMultisampleState.new(), RDPipelineDepthStencilState.new(), blend)
	check(pipeline.is_valid(), "render pipeline is created")

	var commands := PackedByteArray()
	for i in COLUMNS:
		# VkDrawIndirectCommand: vertexCount, instanceCount, firstVertex, firstInstance
		commands.append_array(PackedInt32Array([6, 1, 0, i]).to_byte_array())
	var indirect := rd.storage_buffer_create(commands.size(), commands, RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	var count_bytes := PackedInt32Array([COUNT]).to_byte_array()
	var count_buffer := rd.storage_buffer_create(count_bytes.size(), count_bytes, RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)

	var draw := func() -> PackedByteArray:
		var dl := rd.draw_list_begin(fb, RenderingDevice.DRAW_CLEAR_ALL, [Color.BLACK])
		rd.draw_list_bind_render_pipeline(dl, pipeline)
		rd.draw_list_bind_uniform_set(dl, uset, 0)
		rd.draw_list_draw_indirect_count(dl, false, indirect, 0, count_buffer, 0, COLUMNS, 16)
		rd.draw_list_end()
		return rd.texture_get_data(rt, 0)

	# --- pass 1: four quads, each the colour of its slot; the count buffer stops the rest
	var data: PackedByteArray = draw.call()
	var expect := [Color.RED, Color.GREEN, Color.BLUE, Color.WHITE]
	for i in COUNT:
		var c := pixel(data, i * 8 + 4, H / 2)
		check(same(c, expect[i]), "column %d reads slot %d (%s), got %s" % [i, i, expect[i], c])
	for i in range(COUNT, COLUMNS):
		var c := pixel(data, i * 8 + 4, H / 2)
		check(same(c, Color.BLACK), "column %d is NOT drawn (count buffer = %d), got %s" % [i, COUNT, c])

	# --- pass 2: overwrite slot 1 after the set has been bound and drawn with (update-after-bind)
	rd.uniform_set_update_texture(uset, 1, 1, yellow)
	data = draw.call()
	check(same(pixel(data, 12, H / 2), Color.YELLOW), "slot 1 rewritten to yellow after a draw, got %s" % pixel(data, 12, H / 2))
	check(same(pixel(data, 4, H / 2), Color.RED), "slot 0 untouched by the rewrite")

	# --- pass 3: raise the count on the GPU side of the API (buffer update) and see six columns
	rd.buffer_update(count_buffer, 0, 4, PackedInt32Array([6]).to_byte_array())
	rd.uniform_set_update_texture(uset, 1, 4, red)
	rd.uniform_set_update_texture(uset, 1, 5, green)
	data = draw.call()
	check(same(pixel(data, 4 * 8 + 4, H / 2), Color.RED) and same(pixel(data, 5 * 8 + 4, H / 2), Color.GREEN), "count raised to 6: columns 4 and 5 appear")
	check(same(pixel(data, 6 * 8 + 4, H / 2), Color.BLACK), "column 6 still not drawn")

	# --- immutability: a slotted texture refuses to become mutable (expect one ERROR line, no crash)
	print("  (expect one error line next: the slotted texture is immutable)")
	var sixty_four := PackedByteArray()
	sixty_four.resize(64)
	rd.texture_update(red, 0, sixty_four)
	data = draw.call()
	check(same(pixel(data, 4, H / 2), Color.RED), "slot 0 (red) unchanged: the update to a slotted texture was refused")

	rd.free_rid(uset)
	for t in [red, green, blue, white, yellow]:
		rd.free_rid(t)
	rd.free_rid(pipeline)
	rd.free_rid(fb)
	rd.free_rid(rt)
	rd.free_rid(indirect)
	rd.free_rid(count_buffer)
	rd.free_rid(sampler)
	rd.free_rid(shader)

	print("RD PROBE ", "PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(0 if failures == 0 else 1)
