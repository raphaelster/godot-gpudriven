# GPU-driven rendering fork

Three additions to `RenderingDevice`, Vulkan only (this fork targets desktop Vulkan 1.2+ and
refuses anything less at device creation):

- **Unbounded texture binding.** A shader binding declared `uniform texture2D textures[];` is a
  runtime array: reflected with length 0, laid out at `uniform_set_unbounded_capacity()` slots
  (65536, or the device's update-after-bind limit if lower) with partially-bound, variable-count
  and update-after-bind flags, in a descriptor pool of its own. At most one per set, and it must
  carry the set's highest binding number. Index it with `nonuniformEXT(...)`.
- **`uniform_set_update_texture(set, binding, index, texture)`** writes one slot after the set
  exists, while it is bound. A slotted texture is IMMUTABLE for as long as any slot holds it
  (update, copy, clear, resolve, readback and driver callbacks are refused); overwrite the slot
  with a fallback texture before freeing it, and never touch a slot an in-flight frame reads.
- **`draw_list_draw_indirect_count(list, use_indices, buffer, offset, count_buffer, count_offset,
  max_draw_count, stride)`**: the draw count is a uint32 read from a second buffer on the GPU.

`rd_probe.gd` exercises all three against the validation layer and reads pixels back:

    source ~/vksdk/<ver>/setup-env.sh
    xvfb-run -a -s "-screen 0 640x480x24" bin/godot.linuxbsd.editor.x86_64 \
        --display-driver x11 --gpu-validation --path <any project> --script misc/gpu_driven/rd_probe.gd

It must print `RD PROBE PASS` and no VUID beyond the two the unpatched engine already emits
(`VkShaderModuleCreateInfo-pCode-08737`, `vkCmdCopyBufferToImage-imageOffset-07738`).
