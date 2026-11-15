shader_type spatial;

// Vertex alpha is ice coverage, sampled from the same field as tire traction.
void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = mix(0.94, 0.10, COLOR.a);
	SPECULAR = mix(0.28, 0.80, COLOR.a);
}
