shader_type canvas_item;
// Combined skycam menu shader: fisheye "little planet" warp + a gentle blur, in
// a single pass. Doing both here avoids the fragility of stacking two separate
// screen-reading shaders (where order and double-sampling get finicky).
//
//  - strength : globe bulge amount (0 = flat, ~0.55 = nice bow, 1.5 = full planet)
//  - zoom     : counters the edge pull so the field still fills the frame
//  - blur_amount : softness of the gentle skycam haze

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform float strength : hint_range(0.0, 1.5) = 0.55;
uniform float zoom : hint_range(0.5, 1.5) = 1.02;
uniform float blur_amount : hint_range(0.0, 4.0) = 1.4;

// sample the screen at a warped UV, returning a dark edge outside the frame
vec4 sample_warped(vec2 uv, float str, float zm) {
	vec2 centered = uv - vec2(0.5);
	float r = length(centered);
	float factor = 1.0 + str * (r * r);
	vec2 final_uv = (centered * factor / zm) + vec2(0.5);
	if (final_uv.x < 0.0 || final_uv.x > 1.0 || final_uv.y < 0.0 || final_uv.y > 1.0) {
		return vec4(0.04, 0.06, 0.10, 1.0);
	}
	return texture(SCREEN_TEXTURE, final_uv);
}

void fragment() {
	vec2 ps = SCREEN_PIXEL_SIZE * blur_amount;
	vec4 col = vec4(0.0);
	// gaussian-ish blur taps, each sampled through the fisheye warp
	col += sample_warped(SCREEN_UV, strength, zoom) * 0.25;
	col += sample_warped(SCREEN_UV + vec2( ps.x, 0.0), strength, zoom) * 0.125;
	col += sample_warped(SCREEN_UV + vec2(-ps.x, 0.0), strength, zoom) * 0.125;
	col += sample_warped(SCREEN_UV + vec2(0.0,  ps.y), strength, zoom) * 0.125;
	col += sample_warped(SCREEN_UV + vec2(0.0, -ps.y), strength, zoom) * 0.125;
	col += sample_warped(SCREEN_UV + vec2( ps.x,  ps.y), strength, zoom) * 0.0625;
	col += sample_warped(SCREEN_UV + vec2(-ps.x,  ps.y), strength, zoom) * 0.0625;
	col += sample_warped(SCREEN_UV + vec2( ps.x, -ps.y), strength, zoom) * 0.0625;
	col += sample_warped(SCREEN_UV + vec2(-ps.x, -ps.y), strength, zoom) * 0.0625;
	COLOR = col;
}
