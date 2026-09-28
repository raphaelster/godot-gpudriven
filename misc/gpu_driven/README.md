# GPU-driven rendering fork

Three additions to `RenderingDevice`, Vulkan only (this fork targets desktop Vulkan 1.2+ and
refuses anything less at device creation):

- **Unbounded bindings.** A shader binding declared as a runtime array of sampled textures
  (`uniform texture2D textures[];`, any dimensionality: `texture2DArray`, `textureCube`, ...) or of
  storage images (`layout(rgba8) uniform image2D images[];`) is UNBOUNDED: reflected with length 0,
  laid out at `uniform_set_unbounded_capacity()` slots (65536, or the device's update-after-bind
  limit if lower) with partially-bound and update-after-bind flags, in a descriptor pool of its
  own. Any number per set. Index it with `nonuniformEXT(...)`.
- **`uniform_set_update_texture(set, binding, index, texture)`** writes one slot after the set
  exists, while it is bound. A slot texture is either TRACKED (it had a tracker when slotted: any
  texture created with STORAGE or attachment usage, or made mutable before) and rides the set's
  trackers so the render graph transitions it like any bound texture — an atlas rendered by one
  pass and sampled by the next, a page pool written by compute — or UNTRACKED (a plain uploaded
  texture), in which case it is IMMUTABLE for as long as any slot holds it: update, copy, clear,
  resolve, readback and driver callbacks are refused. Freeing a slotted texture empties its slots
  with a warning instead of freeing the set; the descriptors dangle until rewritten. Never touch a
  slot an in-flight frame reads. Textures with an owner (views, slices) and shared fallbacks are
  refused.
- **`draw_list_draw_indirect_count(list, use_indices, buffer, offset, count_buffer, count_offset,
  max_draw_count, stride)`**: the draw count is a uint32 read from a second buffer on the GPU.

`rd_probe.gd` exercises all of it against the validation layer and reads pixels back — two
unbounded bindings in one set, a texture2DArray slot, a storage image written by compute and
sampled by the next draw through a tracked slot, the count draw, the immutability refusal, and a
slotted texture freed under the set:

    source ~/vksdk/<ver>/setup-env.sh
    xvfb-run -a -s "-screen 0 640x480x24" bin/godot.linuxbsd.editor.x86_64 \
        --display-driver x11 --gpu-validation --path <any project> --script misc/gpu_driven/rd_probe.gd

It must print `RD PROBE PASS` and no VUID beyond the two the unpatched engine already emits
(`VkShaderModuleCreateInfo-pCode-08737`, `vkCmdCopyBufferToImage-imageOffset-07738`).
