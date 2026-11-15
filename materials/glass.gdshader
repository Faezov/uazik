shader_type spatial;
render_mode cull_disabled, depth_draw_never;
void fragment() {
	float edge = 1.0 - smoothstep(0.0, 0.14, min(min(UV.x, 1.0-UV.x), min(UV.y, 1.0-UV.y)));
	float dirt = (sin(UV.x * 157.0 + sin(UV.y * 19.0)) * 0.5 + 0.5) * edge;
	ALBEDO = mix(vec3(0.38, 0.48, 0.5), vec3(0.4, 0.36, 0.27), dirt * 0.5);
	ALPHA = 0.08 + edge * 0.16 + dirt * 0.09;
	ROUGHNESS = 0.19 + edge * 0.4;
	METALLIC = 0.1;
}
