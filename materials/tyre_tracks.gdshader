shader_type spatial;
render_mode cull_disabled, depth_draw_never;

uniform float trail_time = 0.0;
uniform vec3 trail_origin = vec3(0.0);
varying vec4 mark;
varying vec3 world_point;

void vertex() {
	mark = INSTANCE_CUSTOM;
	world_point = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 edge = smoothstep(vec2(0.0), vec2(0.12, 0.08), UV);
	edge *= smoothstep(vec2(0.0), vec2(0.12, 0.08), vec2(1.0) - UV);
	float tread = smoothstep(0.15, 0.50, abs(sin((UV.y * mark.z + mark.w) * 48.0 + abs(UV.x - 0.5) * 4.0)));
	float smear = fract(mark.y) * 4.0;
	float fade = 1.0 - smoothstep(55.0, 75.0, trail_time - mark.x);
	fade *= 1.0 - smoothstep(90.0, 125.0, distance(world_point, trail_origin));
	float kind = floor(mark.y);
	ALBEDO = COLOR.rgb;
	ROUGHNESS = kind == 1.0 ? 0.20 : (kind == 3.0 ? 0.38 : 0.95);
	SPECULAR = kind == 1.0 || kind == 3.0 ? 0.65 : 0.25;
	ALPHA = COLOR.a * edge.x * edge.y * mix(0.48 + tread * 0.52, 1.0, smear) * fade;
	if (ALPHA < 0.005) { discard; }
}
