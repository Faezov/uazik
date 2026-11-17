shader_type spatial;

void fragment() {
	// White enamel with a little road grime and chipped paint at the edges.
	float grain = fract(sin(dot(floor(UV * vec2(210.0, 55.0)), vec2(12.9898, 78.233))) * 43758.5453);
	float edge = 1.0 - smoothstep(0.0, 0.10, min(min(UV.x, 1.0 - UV.x), min(UV.y, 1.0 - UV.y)));
	float dirt = edge * (0.08 + grain * 0.18) + step(0.985, grain) * 0.12;
	ALBEDO = mix(vec3(0.95), vec3(0.26, 0.23, 0.18), dirt);
	ROUGHNESS = 0.85;
}
