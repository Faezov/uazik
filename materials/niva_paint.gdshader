shader_type spatial;
render_mode cull_disabled;
uniform mat4 body_inverse;
varying vec3 panel;
void vertex() { panel = (body_inverse * MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	float grain = fract(sin(dot(floor(panel * 180.0), vec3(127.1,311.7,74.7))) * 43758.5453);
	float grime = (1.0-smoothstep(0.45,0.95,panel.y)) * (0.12+0.025*(grain-0.5));
	vec3 enamel = vec3(0.88,0.875,0.83);
	ALBEDO = mix(enamel,vec3(0.27,0.23,0.17),grime);
	ALBEDO = mix(ALBEDO,vec3(0.28,0.17,0.10),step(0.994,grain)*grime*2.0);
	ROUGHNESS = 0.58+grime;
	METALLIC = 0.12;
}
