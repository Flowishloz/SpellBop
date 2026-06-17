// frosted_panel.gdshader — light "translucent acrylic" frosted glass with ROUNDED corners.
//
// Gen X Soft Club / PS2 Y2K: a panel that BLURS the 3D diorama already drawn behind it and lays a
// cool, AIRY silver-blue tint over it, so menu panels read like soft frosted plastic. Corners are
// rounded (SDF mask) for the light/futuristic look — set `rect_size` from code to the ColorRect's
// pixel size and tune `corner_radius`.
//
// USAGE: assign as a ShaderMaterial on a full-rect Control (a ColorRect) BEHIND the panel's contents,
// and `material.set_shader_parameter("rect_size", colorrect.size)`. It samples hint_screen_texture,
// so everything drawn before it (the 3D world + earlier UI) blurs through it. Keep it the backmost
// element of its cluster. Static menus only.
shader_type canvas_item;
render_mode blend_mix;

uniform float blur_radius : hint_range(0.0, 6.0) = 2.6;     // screen-pixels per tap step (frost strength)
uniform vec4 tint : source_color = vec4(0.84, 0.90, 0.99, 1.0);  // airy silver-blue acrylic
uniform float tint_amount : hint_range(0.0, 1.0) = 0.20;   // how much tint over the blurred backdrop
uniform float panel_alpha : hint_range(0.0, 1.0) = 0.72;   // overall opacity (lighter = more see-through)
uniform float brightness : hint_range(0.5, 2.0) = 1.12;    // lift so it reads as lit, light plastic

uniform vec2 rect_size = vec2(400.0, 200.0);               // SET FROM CODE = the ColorRect size in px
uniform float corner_radius : hint_range(0.0, 240.0) = 34.0;  // the soft ~0.3 corner curve
uniform float edge_softness : hint_range(0.5, 4.0) = 1.5;  // anti-aliased rounded edge

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;


// Signed distance to a rounded rectangle (p relative to centre, b = half-extents, r = corner radius).
float rounded_box_sdf(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + vec2(r);
	return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}


void fragment() {
	vec2 ps = SCREEN_PIXEL_SIZE * blur_radius;
	// 13-tap separable-ish gaussian (centre + two rings); weights sum to 1.0.
	vec3 acc = texture(screen_tex, SCREEN_UV).rgb * 0.20;
	acc += texture(screen_tex, SCREEN_UV + ps * vec2( 1.0,  0.0)).rgb * 0.10;
	acc += texture(screen_tex, SCREEN_UV + ps * vec2(-1.0,  0.0)).rgb * 0.10;
	acc += texture(screen_tex, SCREEN_UV + ps * vec2( 0.0,  1.0)).rgb * 0.10;
	acc += texture(screen_tex, SCREEN_UV + ps * vec2( 0.0, -1.0)).rgb * 0.10;
	acc += texture(screen_tex, SCREEN_UV + ps * vec2( 1.0,  1.0)).rgb * 0.075;
	acc += texture(screen_tex, SCREEN_UV + ps * vec2(-1.0,  1.0)).rgb * 0.075;
	acc += texture(screen_tex, SCREEN_UV + ps * vec2( 1.0, -1.0)).rgb * 0.075;
	acc += texture(screen_tex, SCREEN_UV + ps * vec2(-1.0, -1.0)).rgb * 0.075;
	acc += texture(screen_tex, SCREEN_UV + ps * vec2( 2.0,  0.0)).rgb * 0.025;
	acc += texture(screen_tex, SCREEN_UV + ps * vec2(-2.0,  0.0)).rgb * 0.025;
	acc += texture(screen_tex, SCREEN_UV + ps * vec2( 0.0,  2.0)).rgb * 0.025;
	acc += texture(screen_tex, SCREEN_UV + ps * vec2( 0.0, -2.0)).rgb * 0.025;

	vec3 frosted = mix(acc, tint.rgb, tint_amount) * brightness;

	// Rounded-rectangle alpha mask (soft corners + a clean anti-aliased edge).
	vec2 p = (UV - vec2(0.5)) * rect_size;
	float r = min(corner_radius, min(rect_size.x, rect_size.y) * 0.5);
	float d = rounded_box_sdf(p, rect_size * 0.5, r);
	float mask = 1.0 - smoothstep(0.0, edge_softness, d);

	// Respect the node's modulate (lets a Tween fade the whole frosted panel in/out).
	COLOR = vec4(frosted, panel_alpha * mask) * vec4(COLOR.rgb, COLOR.a);
}
