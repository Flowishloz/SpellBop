// palette_swap.gdshader — recolours an indexed pixel-art wizard Sprite3D for SKINS,
// and re-implements the Sprite3D FIXED_Y billboard.
//
// PRESENTATION ONLY — drives nothing in the deterministic SG2D sim.
//
// WHY the billboard code: a ShaderMaterial placed in Sprite3D.material_override REPLACES
// the node's built-in billboard (verified by tests/probe_billboard_override.gd — a 70-deg
// yaw foreshortened the quad to cos70). So we reconstruct Godot's own FIXED_Y keep-scale
// billboard in vertex(); the sprite then behaves IDENTICALLY to the native billboard it
// replaced (faces the camera around world-Y, stays upright; node SCALE survives as positive
// lengths so the squash/stretch + the death width-pulse still read; node ROTATION is
// overwritten — the running lean was already a no-op under the native billboard).
//
// COLOUR-MATCH swap (Creative Director pick): the artist paints with a small fixed reference
// palette (src_colors, == the base skin's colours); each skin supplies same-length, same-order
// dst_colors. Per pixel: a colour matching a src becomes its dst; off-palette colours (spell
// orbs, fx) pass through unchanged. Matching is done in sRGB (perceptually even — avoids dark
// shades colliding the way they would in linear), so distinct hand-picked hex codes never alias.
shader_type spatial;
render_mode unshaded, cull_disabled;

const int MAX_COLORS = 16;

uniform sampler2D pose_tex : source_color, filter_nearest;
uniform int color_count = 0;
uniform vec3 src_colors[MAX_COLORS];  // sRGB reference palette (base skin)
uniform vec3 dst_colors[MAX_COLORS];  // sRGB recolour (active skin)
uniform float match_eps : hint_range(0.0, 0.25) = 0.03;

vec3 lin_to_srgb(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, c * 12.92, vec3(lessThanEqual(c, vec3(0.0031308))));
}

vec3 srgb_to_lin(vec3 c) {
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, vec3(lessThanEqual(c, vec3(0.04045))));
}

void vertex() {
	// FIXED_Y billboard + keep-scale (Godot's generated snippet — identical to native).
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(normalize(cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz)), 0.0),
		vec4(0.0, 1.0, 0.0, 0.0),
		vec4(normalize(cross(INV_VIEW_MATRIX[0].xyz, vec3(0.0, 1.0, 0.0))), 0.0),
		MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec4 t = texture(pose_tex, UV);
	vec3 px = lin_to_srgb(t.rgb);    // sampled colour back in the artist's sRGB space
	vec3 outc = px;
	for (int i = 0; i < MAX_COLORS; i++) {
		if (i >= color_count) {
			break;
		}
		if (distance(px, src_colors[i]) <= match_eps) {
			outc = dst_colors[i];
			break;
		}
	}
	// srgb_to_lin so the output matches what the un-shadered Sprite3D showed; COLOR is the
	// sprite's modulate, so the existing damage flash / death fade still tint the wizard.
	ALBEDO = srgb_to_lin(outc) * COLOR.rgb;
	ALPHA = t.a * COLOR.a;
}
