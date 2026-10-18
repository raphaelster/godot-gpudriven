/**************************************************************************/
/*  render_data_rd.cpp                                                    */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including   */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "render_data_rd.h"

#include "servers/rendering/renderer_rd/renderer_scene_render_rd.h"

RID RenderDataRD::get_sky_radiance_texture() const {
	RendererSceneRenderRD *scene_render = RendererSceneRenderRD::get_singleton();
	if (scene_render == nullptr || environment.is_null()) {
		return RID();
	}
	const RID sky = scene_render->environment_get_sky(environment);
	if (sky.is_null()) {
		return RID();
	}
	return scene_render->get_sky()->sky_get_radiance_texture_rd(sky);
}

RID RenderDataRD::get_dfg_lut_texture() const {
	RendererSceneRenderRD *scene_render = RendererSceneRenderRD::get_singleton();
	return scene_render != nullptr ? scene_render->get_dfg_lut_texture() : RID();
}
