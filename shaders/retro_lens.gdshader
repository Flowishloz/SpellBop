// retro_lens.gdshader — GameCube-era retro post-process + curvilinear lens.
//
// ROLE (Graphics Pipeline / Creative Director): a single full-screen pass on
// a CanvasLayer ColorRect that reads the rendered 3D frame (screen texture)
// and re-presents it like a 2000s console on a slightly curved display —
// Balatro-style. Helps the 2D billboard wizards melt into the 3D court by
// crushing everything through the same color/pixel grid.
//
// CHAIN (in order):
//   1. CURVILINEAR LENS — barrel distortion, normalized so corners stay
//      glued to the screen edge (only the interior bows outward).
//   2. PIXELATION — samples on a virtual low-res grid (GameCube ~480p).
//   3. CHROMATIC ABERRATION — R/B split that grows toward the edges.
//   4. COLOR QUANTIZATION + BAYER DITHER — banded color with ordered
//      dithering, the signature of low-bit framebuffers.
//   5. SCANLINES + VIGNETTE — subtle CRT character.
//
// All knobs are uniforms — tune live on the PostFX ColorRect's material.
// PURE PRESENTATION: this pass never touches the sim. The HUD lives on
// higher CanvasLayers and stays crisp above this pass by design.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest;

// 1. Lens curvature. 0 = flat. ~0.12 = the "slight curvilinear" ask.
uniform float distortion_strength : hint_range(0.0, 0.6) = 0.12;

// 2. Virtual vertical resolution. 0 = pixelation off. 480 = GameCube-ish.
uniform float pixel_rows : hint_range(0.0, 1080.0) = 480.0;

// 3. Chromatic aberration in virtual pixels at the screen edge.
uniform float aberration_strength : hint_range(0.0, 4.0) = 0.8;

// 4. Color steps per channel + dither blend.
uniform float color_levels : hint_range(2.0, 64.0) = 22.0;
uniform float dither_strength : hint_range(0.0, 1.0) = 0.6;

// 5. CRT character.
uniform float scanline_strength : hint_range(0.0, 0.4) = 0.07;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.22;

// 6. DEATH RIPPLE (Sprint 20): a screen-space shockwave that expands from the
// point of contact on a knockout — a Screen-Space Distortion ring that displaces
// the sampled image radially. MatchController drives ripple_progress (0..1, < 0 =
// off) on SCALED time so the ring expands slowly during the death slow-mo, like
// the rest of the 3D.
uniform vec2 ripple_center = vec2(0.5, 0.5); // impact point, screen UV
uniform float ripple_progress = -1.0;        // 0..1 expansion, < 0 = inactive
uniform float ripple_strength = 0.0;         // peak UV displacement

const mat4 BAYER = mat4(
		vec4( 0.0,  8.0,  2.0, 10.0),
		vec4(12.0,  4.0, 14.0,  6.0),
		vec4( 3.0, 11.0,  1.0,  9.0),
		vec4(15.0,  7.0, 13.0,  5.0));

void fragment() {
	// --- 0. Death ripple (screen-space shockwave) ----------------------
	// Displace the sample UV radially along an expanding ring centred on the
	// impact point, fading as it grows — a Screen-Space Distortion shockwave.
	vec2 suv = SCREEN_UV;
	if (ripple_progress >= 0.0) {
		float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x; // res.x / res.y
		vec2 d = suv - ripple_center;
		float dist = length(vec2(d.x * aspect, d.y));
		float radius = ripple_progress * 1.4;
		float ring = smoothstep(0.12, 0.0, abs(dist - radius));
		float fade = 1.0 - clamp(ripple_progress, 0.0, 1.0);
		vec2 dir = normalize(d + vec2(1e-6));
		suv += dir * ring * ripple_strength * fade;
	}

	// --- 1. Curvilinear lens -------------------------------------------
	vec2 centered = suv - vec2(0.5);
	float r2 = dot(centered, centered) * 2.0; // 0 center, 1.0 at corners
	vec2 uv = vec2(0.5) + centered * (1.0 + distortion_strength * r2)
			/ (1.0 + distortion_strength);

	// --- 2. Pixelation to the virtual grid ----------------------------
	vec2 screen_res = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 virtual_res = screen_res;
	if (pixel_rows > 0.5) {
		virtual_res = vec2(pixel_rows * screen_res.x / screen_res.y, pixel_rows);
		uv = (floor(uv * virtual_res) + vec2(0.5)) / virtual_res;
	}

	// --- 3. Chromatic aberration (radial, edge-weighted) ---------------
	vec2 shift = normalize(centered + vec2(1e-6))
			* (aberration_strength * r2) / virtual_res;
	vec3 color = vec3(
			texture(screen_tex, clamp(uv + shift, vec2(0.0), vec2(1.0))).r,
			texture(screen_tex, uv).g,
			texture(screen_tex, clamp(uv - shift, vec2(0.0), vec2(1.0))).b);

	// --- 4. Quantize + ordered dither ----------------------------------
	int bx = int(mod(FRAGCOORD.x, 4.0));
	int by = int(mod(FRAGCOORD.y, 4.0));
	float threshold = (BAYER[bx][by] / 16.0 - 0.5) * dither_strength;
	color = floor(color * color_levels + 0.5 + threshold) / color_levels;

	// --- 5. Scanlines + vignette ----------------------------------------
	float band = sin(uv.y * pixel_rows * 3.14159265);
	color *= 1.0 - scanline_strength * band * band;
	color *= 1.0 - vignette_strength * smoothstep(0.35, 1.0, r2);

	COLOR = vec4(color, 1.0);
}
