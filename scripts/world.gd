extends Node3D

@export var world_seed := 452
var landscape: Node3D

var using_niva := false
var notice_text := "Stop before changing low range"
var car: VehicleBody3D
var camera: Camera3D
var inspection: Camera3D
var camera_anchor := Vector3.ZERO
var camera_heading := 0.0
var camera_reset := true
var speed := 0.0
var inside := false
var arrived := false
var label: Label
var debug_label: Label
var instructions: Label
var help_tween: Tween
var mode_notice := 0.0
var audio_settings: PanelContainer

func material(color: Color, glow := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.95
	if glow:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = 2.0
	return m

func box(parent: Node3D, pos: Vector3, size: Vector3, color: Color, glow := false) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var shape := BoxMesh.new()
	shape.size = size
	mesh.mesh = shape
	mesh.material_override = material(color, glow)
	parent.add_child(mesh)
	mesh.position = pos
	return mesh

func route(z: float) -> float:
	return landscape.road_point(z).x

func _ready() -> void:
	var ui := CanvasLayer.new()
	add_child(ui)
	audio_settings = preload("res://scripts/audio_settings.gd").new()
	ui.add_child(audio_settings)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("66768b")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color("9baeca")
	env.environment.ambient_light_energy = 0.65
	env.environment.fog_enabled = true
	env.environment.fog_light_color = Color("8e9eaf")
	env.environment.fog_density = 0.014
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-12, -35, 0)
	sun.light_color = Color("ffd4a2")
	sun.light_energy = 0.65
	add_child(sun)
	landscape = preload("res://scripts/landscape.gd").new()
	add_child(landscape)
	landscape.setup(world_seed)
	landscape.stream_at(Vector3.ZERO,true)
	make_car()
	landscape.follow = car
	make_snow()
	var wheel_effects := preload("res://scripts/wheel_effects.gd").new()
	wheel_effects.name = "WheelEffects"
	add_child(wheel_effects)
	wheel_effects.setup(car,landscape)
	label = Label.new()
	ui.add_child(label)
	label.position = Vector2(30,25)
	label.add_theme_font_size_override("font_size",22)
	debug_label = Label.new()
	ui.add_child(debug_label)
	debug_label.position = Vector2(30,245)
	debug_label.add_theme_font_size_override("font_size",16)
	debug_label.hide()
	instructions = Label.new()
	ui.add_child(instructions)
	instructions.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	instructions.anchor_left = 0.025
	instructions.anchor_right = 0.975
	instructions.anchor_top = 0.96
	instructions.anchor_bottom = 0.96
	instructions.grow_vertical = Control.GROW_DIRECTION_BEGIN
	instructions.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	instructions.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	instructions.mouse_filter = Control.MOUSE_FILTER_IGNORE
	instructions.text = "WASD / Arrows: drive     Space: brake     C: camera     V: inspect     R: return to road     F2: vehicle (stop)     F3: telemetry     Esc: pause"
	instructions.text += "\nM: radio on/off   N: next track     F1: controls on/off"
	help_tween = create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	help_tween.tween_interval(5.0)
	help_tween.tween_property(instructions,"modulate:a",0.0,0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	help_tween.tween_callback(instructions.hide)
	inspection = preload("res://scripts/inspection_camera.gd").new()
	inspection.name = "InspectionCamera"
	inspection.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(inspection)
	inspection.setup(car,camera,instructions)
	var radio := preload("res://scripts/radio.gd").new()
	radio.name = "Radio"
	add_child(radio)
	move_child(ui,get_child_count()-1)
	ui.move_child(audio_settings,ui.get_child_count()-1)

func toggle_controls() -> void:
	# Manual help stays visible until F1 is pressed again, including in inspection.
	if help_tween: help_tween.kill()
	instructions.visible = not instructions.visible
	instructions.modulate.a = 1.0

func make_car() -> void:
	car = VehicleBody3D.new()
	car.set_script(preload("res://scripts/vehicle.gd"))
	car.name = "Bukhanka"
	add_child(car)
	car.surface_at = landscape.surface_at
	# Start interpolation history before the initial teleport.
	car.get_global_transform_interpolated()
	recover_car(0.0)
	camera = Camera3D.new()
	camera.top_level = true
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(camera)
	camera.current = true
	camera.far = 220
	camera.near = 0.06
	camera.fov = 63
	camera.position = car.position+Vector3(4,3,7)

func switch_vehicle() -> bool:
	if inspection.active or car.linear_velocity.length()>0.1 or car.angular_velocity.length()>0.1:
		notice_text = "Stop before switching vehicles"
		mode_notice = 2.5
		return false
	var previous := car
	var next := VehicleBody3D.new()
	using_niva = not using_niva
	next.set_script(preload("res://scripts/niva.gd") if using_niva else preload("res://scripts/vehicle.gd"))
	next.name = "Niva" if using_niva else "Bukhanka"
	next.transform = previous.transform
	next.surface_at = landscape.surface_at
	# Remove the old physics body before adding its replacement.
	previous.get_node("Snow").reparent(self)
	remove_child(previous)
	previous.free()
	car = next
	add_child(car)
	var height := -INF
	for wheel in car.wheels:
		var connection: Vector3 = car.global_basis*wheel.get_meta("connection")
		var contact: Vector3 = car.position+connection-car.global_basis.y*(wheel.wheel_rest_length+wheel.wheel_radius)
		height = maxf(height,surface_height(contact.x,contact.z)-contact.y+car.position.y)
	car.position.y = height+0.01
	car.reset_physics_interpolation()
	get_node("Snow").reparent(car)
	landscape.follow = car
	inspection.car = car
	get_node("WheelEffects").set_vehicle(car)
	camera_reset = true
	return true

func elevation(z: float) -> float:
	return landscape.road_point(z).y

func surface_height(x: float, z: float) -> float:
	return landscape.collision_height(x,z)

func icy_road(z: float) -> bool:
	return landscape.icy_road(z)

func recover_car(z: float) -> void:
	landscape.stream_at(Vector3(route(z),0,z),true)
	var forward := Vector3(route(z-3)-route(z),0,-3).normalized()
	car.global_transform = Transform3D(Basis.looking_at(forward),Vector3(route(z),surface_height(route(z),z)+0.85,z))
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	car.reset_wheel_motion()
	car.reset_physics_interpolation()
	camera_reset = true

func make_snow() -> void:
	var snow := CPUParticles3D.new()
	snow.name = "Snow"
	car.add_child(snow)
	snow.position.y = 12
	snow.amount = 650
	snow.lifetime = 8
	snow.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	snow.emission_box_extents = Vector3(24,10,24)
	snow.direction = Vector3(-0.2,-1,0)
	snow.gravity = Vector3(0,-0.3,0)
	snow.initial_velocity_min = 1.5
	snow.initial_velocity_max = 3
	snow.scale_amount_min = 0.025
	snow.scale_amount_max = 0.065
	var flake := SphereMesh.new()
	flake.radial_segments = 4
	flake.rings = 2
	snow.mesh = flake

func _unhandled_key_input(event: InputEvent) -> void:
	if audio_settings.visible: return
	if event.is_pressed() and not event.is_echo():
		if event.keycode in [KEY_1,KEY_2,KEY_3]:
			var mode: String = (["4H","4H","4L"] if using_niva else ["2H","4H","4L"])[event.keycode-KEY_1]
			if not car.select_drive_mode(mode):
				notice_text = "Stop before changing low range"
				mode_notice = 2.5
		if event.keycode == KEY_F2: switch_vehicle()
		if event.keycode == KEY_L and using_niva:
			if not car.toggle_centre_lock():
				notice_text = "Stop before changing centre lock"
				mode_notice = 2.5
		if event.keycode == KEY_F3: debug_label.visible = not debug_label.visible
		if event.keycode == KEY_C:
			inside = not inside
			camera.fov = 77 if inside else 63
			camera_reset = true
		if event.keycode == KEY_R: recover_car(car.position.z)

func _physics_process(delta: float) -> void:
	if inspection.active: return
	mode_notice = maxf(0,mode_notice-delta)
	var driving := not audio_settings.visible
	var throttle := 0.0
	var steer := 0.0
	if driving:
		throttle = float(Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP))-float(Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN))
		steer = float(Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT))-float(Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT))
	car.drive(throttle,steer,driving and Input.is_physical_key_pressed(KEY_SPACE),delta)
	speed = car.speed
	if car.position.y<surface_height(car.position.x,car.position.z)-12:
		recover_car(car.position.z)
	if car.position.z < -485 and absf(car.position.x-route(car.position.z))<22: arrived = true
	label.text = ("You’re home. Take a moment." if arrived else "Drive home ·\n%d m remaining" % maxi(0,int(490+car.position.z)))
	label.text += "\n%02d km/h  ·  %s  ·  %s" % [int(car.linear_velocity.length()*3.6),"Нива 2121" if using_niva else "Буханка",car.drive_mode]
	if using_niva:
		label.text += "\n2: high   3: low (stop)   L: centre lock (%s)" % ("LOCKED" if car.centre_locked else "open")
	else:
		label.text += "\n1: 2H   2: 4H   3: 4L (stop)"
	if mode_notice>0: label.text += "\n"+notice_text
	if debug_label.visible:
		var slip := PackedStringArray()
		for value in car.wheel_slip: slip.append("%+.1f" % value)
		var contact := PackedStringArray()
		for wheel in car.wheels: contact.append("ON" if wheel.is_in_contact() else "--")
		debug_label.text = "TELEMETRY · F3 to hide\nSpeed %.1f km/h   Gear %s   RPM %.0f\nTire force %+.0f N (total)\nContact FL / FR / RL / RR: %s" % [car.linear_velocity.length()*3.6,"R" if car.gear<0 else str(car.gear),car.engine_rpm,car.drive_force," / ".join(contact)]
		debug_label.text += "\nSteer %+.1f°   Lateral %+.2f m/s\nWheel slip FL / FR / RL / RR (m/s): %s" % [rad_to_deg(car.steering),car.linear_velocity.dot(car.global_basis.x)," / ".join(slip)]
		var surfaces := PackedStringArray()
		for cover: Vector2 in car.wheel_surfaces: surfaces.append("ICE" if cover.x>0.5 else ("DEEP" if cover.y>0.5 else "SNOW"))
		debug_label.text += "\nTires FL / FR / RL / RR: %s" % " / ".join(surfaces)


func _process(delta: float) -> void:
	if not camera.current: return
	var pose := car.get_global_transform_interpolated()
	var heading := atan2(pose.basis.z.x,pose.basis.z.z)
	if camera_reset:
		camera_anchor = pose.origin
		camera_heading = heading
		camera_reset = false
	# Track travel without trailing behind; absorb bumps separately from steering.
	camera_anchor.x = pose.origin.x
	camera_anchor.z = pose.origin.z
	camera_anchor.y = lerpf(camera_anchor.y,pose.origin.y,1-exp(-delta*(4.0 if inside else 2.5)))
	camera_heading = lerp_angle(camera_heading,heading,1-exp(-delta*14.0))
	var level_basis := Basis(Vector3.UP,camera_heading)
	if inside:
		var eye: Vector3 = car.model.transform*car.driver_eye.position
		camera.global_transform = Transform3D(level_basis*Basis(Vector3.RIGHT,-0.12),camera_anchor+level_basis*eye)
	else:
		var forward := -level_basis.z
		var target := camera_anchor+Vector3(0,3.0,0)-forward*7.5
		target.y = maxf(target.y,surface_height(target.x,target.z)+1.1)
		camera.look_at_from_position(target,camera_anchor+Vector3(0,0.65,0)+forward*1.3,Vector3.UP)
