shader_type spatial;
render_mode cull_disabled;
varying vec3 panel_position;
uniform mat4 body_inverse;
float grain(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}
float soft_noise(vec3 p) {
	vec3 cell = floor(p);
	vec3 f = fract(p);
	f = f*f*(3.0-2.0*f);
	return mix(mix(mix(grain(cell),grain(cell+vec3(1,0,0)),f.x),mix(grain(cell+vec3(0,1,0)),grain(cell+vec3(1,1,0)),f.x),f.y),mix(mix(grain(cell+vec3(0,0,1)),grain(cell+vec3(1,0,1)),f.x),mix(grain(cell+vec3(0,1,1)),grain(cell+vec3(1,1,1)),f.x),f.y),f.z);
}
void vertex() { panel_position = (body_inverse * MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	float mottling = soft_noise(panel_position * 18.0);
	float chips = grain(floor(panel_position * 160.0));
	float lower = 1.0 - smoothstep(0.6, 1.2, panel_position.y);
	vec3 paint = vec3(0.34, 0.39, 0.30) * (0.94 + mottling * 0.12);
	paint = mix(paint, vec3(0.26, 0.22, 0.16), lower * 0.28);
	paint = mix(paint, vec3(0.25, 0.125, 0.065), step(0.975, chips) * lower * 0.75);
	ALBEDO = paint;
	ROUGHNESS = 0.72 + mottling * 0.2;
	METALLIC = 0.18;
}
