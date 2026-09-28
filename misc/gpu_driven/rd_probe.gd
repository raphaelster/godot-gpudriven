extends SceneTree
## GPU-driven fork probe. Exercises, against the validation layer and by reading pixels back:
##  - two UNBOUNDED bindings in one set (texture2D[] and texture2DArray[]) indexed with nonuniformEXT,
##    filled partly at creation and partly through uniform_set_update_texture, rewritten after a draw;
##  - an unbounded image2D[] binding written by a compute pass, whose texture a later draw samples
##    through a texture2D[] slot (a TRACKED slot texture: the graph owes the layout transition);
##  - draw_list_draw_indirect_count with the count read from a buffer, raised on the GPU side;
##  - the immutability rule for an untracked slot texture, and freeing a slotted texture (the set
##    survives, its slots are emptied with a warning).
## Windowed only (RD needs a device): run under xvfb with --gpu-validation.

const W := 64
const H := 16
const COLUMNS := 8 # eight indirect commands, one quad each

var rd: RenderingDevice
var failures := 0


func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   ", what)
	else:
		failures += 1
		print("  FAIL ", what)


func solid_bytes(color: Color, texels: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	for i in texels:
		bytes.append_array(PackedByteArray([int(color.r * 255), int(color.g * 255), int(color.b * 255), 255]))
	return bytes


func solid_texture(color: Color) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.width = 4
	fmt.height = 4
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	return rd.texture_create(fmt, RDTextureView.new(), [solid_bytes(color, 16)])


func array_texture(layer0: Color, layer1: Color) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.width = 4
	fmt.height = 4
	fmt.array_layers = 2
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return rd.texture_create(fmt, RDTextureView.new(), [solid_bytes(layer0, 16), solid_bytes(layer1, 16)])


func storage_texture() -> RID:
	var fmt := RDTextureFormat.new()
	fmt.width = 4
	fmt.height = 4
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return rd.texture_create(fmt, RDTextureView.new())


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

	# --- graphics shader: procedural quads, one per instance; column 7 samples the array binding
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
layout(set = 0, binding = 2) uniform texture2DArray arrays[];
layout(location = 0) in flat uint v_index;
layout(location = 0) out vec4 o_color;
void main() {
	if (v_index == 7u) {
		o_color = texture(sampler2DArray(arrays[nonuniformEXT(0u)], s), vec3(0.5, 0.5, 1.0));
	} else {
		o_color = texture(sampler2D(textures[nonuniformEXT(v_index)], s), vec2(0.5));
	}
}
"""
	var spirv := rd.shader_compile_spirv_from_source(src)
	check(spirv.compile_error_vertex == "" and spirv.compile_error_fragment == "", "graphics shader compiles (two runtime arrays, nonuniformEXT)")
	if spirv.compile_error_vertex != "" or spirv.compile_error_fragment != "":
		print(spirv.compile_error_vertex, spirv.compile_error_fragment)
		quit(1)
		return
	var shader := rd.shader_create_from_spirv(spirv)
	check(shader.is_valid(), "shader with two unbounded bindings in one set is accepted")

	# --- compute shader: writes a colour into images[slot]
	var csrc := RDShaderSource.new()
	csrc.source_compute = """#version 450
#extension GL_EXT_nonuniform_qualifier : require
layout(local_size_x = 4, local_size_y = 4, local_size_z = 1) in;
layout(set = 0, binding = 0, rgba8) uniform writeonly image2D images[];
layout(push_constant) uniform P { uint slot; uint pad0; uint pad1; uint pad2; vec4 color; } pc;
void main() {
	imageStore(images[nonuniformEXT(pc.slot)], ivec2(gl_GlobalInvocationID.xy), pc.color);
}
"""
	var cspirv := rd.shader_compile_spirv_from_source(csrc)
	check(cspirv.compile_error_compute == "", "compute shader compiles (image2D runtime array)")
	if cspirv.compile_error_compute != "":
		print(cspirv.compile_error_compute)
		quit(1)
		return
	var cshader := rd.shader_create_from_spirv(cspirv)
	check(cshader.is_valid(), "compute shader with an unbounded image binding is accepted")
	var cpipeline := rd.compute_pipeline_create(cshader)

	# --- textures and the sets: slots 0 and 1 at creation, 2 and 3 through the partial update
	var red := solid_texture(Color.RED)
	var green := solid_texture(Color.GREEN)
	var blue := solid_texture(Color.BLUE)
	var white := solid_texture(Color.WHITE)
	var yellow := solid_texture(Color.YELLOW)
	var arr := array_texture(Color.BLACK, Color.CYAN)
	var st := storage_texture()

	var sampler := rd.sampler_create(RDSamplerState.new())
	var u_sampler := RDUniform.new()
	u_sampler.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER
	u_sampler.binding = 0
	u_sampler.add_id(sampler)
	var u_textures := RDUniform.new()
	u_textures.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE
	u_textures.binding = 1
	u_textures.add_id(red)
	u_textures.add_id(green)
	var u_arrays := RDUniform.new()
	u_arrays.uniform_type = RenderingDevice.UNIFORM_TYPE_TEXTURE
	u_arrays.binding = 2 # nothing at creation; written below
	var uset := rd.uniform_set_create([u_sampler, u_textures, u_arrays], shader, 0)
	check(uset.is_valid(), "uniform set with two unbounded bindings (2 slots + 0 slots filled) is created")
	rd.uniform_set_update_texture(uset, 1, 2, blue)
	rd.uniform_set_update_texture(uset, 1, 3, white)
	rd.uniform_set_update_texture(uset, 2, 0, arr)

	var u_images := RDUniform.new()
	u_images.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_images.binding = 0
	u_images.add_id(st)
	var cset := rd.uniform_set_create([u_images], cshader, 0)
	check(cset.is_valid(), "compute set with a storage texture in an unbounded image slot is created")

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
		commands.append_array(PackedInt32Array([6, 1, 0, i]).to_byte_array()) # vertexCount, instanceCount, firstVertex, firstInstance
	var indirect := rd.storage_buffer_create(commands.size(), commands, RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	var count_bytes := PackedInt32Array([4]).to_byte_array()
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
	for i in 4:
		var c := pixel(data, i * 8 + 4, H / 2)
		check(same(c, expect[i]), "column %d reads slot %d (%s), got %s" % [i, i, expect[i], c])
	for i in range(4, COLUMNS):
		var c := pixel(data, i * 8 + 4, H / 2)
		check(same(c, Color.BLACK), "column %d is NOT drawn (count buffer = 4), got %s" % [i, c])

	# --- pass 2: overwrite slot 1 after the set has been bound and drawn with (update-after-bind)
	rd.uniform_set_update_texture(uset, 1, 1, yellow)
	data = draw.call()
	check(same(pixel(data, 12, H / 2), Color.YELLOW), "slot 1 rewritten to yellow after a draw, got %s" % pixel(data, 12, H / 2))
	check(same(pixel(data, 4, H / 2), Color.RED), "slot 0 untouched by the rewrite")

	# --- pass 3: compute writes magenta into the storage texture through images[0]; the draw then
	#     samples it through textures[6] (a tracked slot) and the array's layer 1 through arrays[0]
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, cpipeline)
	rd.compute_list_bind_uniform_set(cl, cset, 0)
	var pc := PackedInt32Array([0, 0, 0, 0]).to_byte_array()
	pc.append_array(PackedFloat32Array([1.0, 0.0, 1.0, 1.0]).to_byte_array())
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_end()
	rd.uniform_set_update_texture(uset, 1, 4, red)
	rd.uniform_set_update_texture(uset, 1, 5, green)
	rd.uniform_set_update_texture(uset, 1, 6, st)
	rd.buffer_update(count_buffer, 0, 4, PackedInt32Array([COLUMNS]).to_byte_array())
	data = draw.call()
	check(same(pixel(data, 4 * 8 + 4, H / 2), Color.RED) and same(pixel(data, 5 * 8 + 4, H / 2), Color.GREEN), "count raised to 8: columns 4 and 5 appear")
	check(same(pixel(data, 6 * 8 + 4, H / 2), Color.MAGENTA), "column 6 samples the storage texture the compute pass wrote (tracked slot), got %s" % pixel(data, 6 * 8 + 4, H / 2))
	check(same(pixel(data, 7 * 8 + 4, H / 2), Color.CYAN), "column 7 samples layer 1 of a texture2DArray through the second unbounded binding, got %s" % pixel(data, 7 * 8 + 4, H / 2))

	# --- immutability: an UNTRACKED slotted texture refuses to become mutable (expect one ERROR line)
	print("  (expect one error line next: the untracked slotted texture is immutable)")
	var sixty_four := PackedByteArray()
	sixty_four.resize(64)
	rd.texture_update(red, 0, sixty_four)
	data = draw.call()
	check(same(pixel(data, 4, H / 2), Color.RED), "slot 0 (red) unchanged: the update to an untracked slotted texture was refused")

	# --- a TRACKED slotted texture may be written again (compute), and the draw sees it
	pc = PackedInt32Array([0, 0, 0, 0]).to_byte_array()
	pc.append_array(PackedFloat32Array([0.0, 1.0, 1.0, 1.0]).to_byte_array())
	cl = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, cpipeline)
	rd.compute_list_bind_uniform_set(cl, cset, 0)
	rd.compute_list_set_push_constant(cl, pc, pc.size())
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_end()
	data = draw.call()
	check(same(pixel(data, 6 * 8 + 4, H / 2), Color.CYAN), "the tracked slot texture rewritten by compute reads cyan on the next draw, got %s" % pixel(data, 6 * 8 + 4, H / 2))

	# --- freeing a slotted texture: the sets survive, the slots are emptied (expect one warning)
	print("  (expect one warning line next: a slotted texture was freed)")
	rd.free_rid(st)
	check(rd.uniform_set_is_valid(uset) and rd.uniform_set_is_valid(cset), "both sets survive the freeing of a texture they held only in slots")
	rd.buffer_update(count_buffer, 0, 4, PackedInt32Array([6]).to_byte_array())
	data = draw.call()
	check(same(pixel(data, 4, H / 2), Color.RED) and same(pixel(data, 5 * 8 + 4, H / 2), Color.GREEN), "the surviving set still draws its other slots")

	rd.free_rid(uset)
	rd.free_rid(cset)
	for t in [red, green, blue, white, yellow, arr]:
		rd.free_rid(t)
	rd.free_rid(pipeline)
	rd.free_rid(cpipeline)
	rd.free_rid(fb)
	rd.free_rid(rt)
	rd.free_rid(indirect)
	rd.free_rid(count_buffer)
	rd.free_rid(sampler)
	rd.free_rid(shader)
	rd.free_rid(cshader)

	print("RD PROBE ", "PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(0 if failures == 0 else 1)
