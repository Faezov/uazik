extends VehicleBody3D

# Metres: 4.36 long, 1.94 wide, 2.064 high; 2.30 wheelbase, 1.455 track.
# Photo reference: https://all-auto.org/287-uaz-unikalnye-vnedorozhniki-s-legendarnoy-istoriey.html
# Dimensions: https://www.uaz.ru/data/uaz/assets/uaz-sgr-catalog.pdf
# Model faces -Z; Godot's positive engine force faces +Z.
var axle_positions := [-1.26, 1.04]
var model_offset := Vector3(0, -0.72, 0)
# Period UAZ gearbox, high transfer range (1:1), final drive.
# https://www.zr.ru/archive/zr/1965/09/novosti-sovietskoi-tiekhniki
var gear_ratios := [4.124, 2.641, 1.58, 1.0]
var reverse_ratio := 5.224
var final_drive := 5.125
# UAZ transfer case: https://www.uaz.ru/data/uploads/uaz/originals/manual-sgr-2020.pdf
var low_range := 1.94
# Estimated tire/flywheel inertia (kg m²); friction coefficients below are tuning.
const WHEEL_INERTIA = 2.0
const ENGINE_INERTIA = 0.18
# UMZ-451M anchors: 166.7 Nm at 2000–2500 rpm, 55.2 kW at 4000 rpm.
# NIIAT 1985: https://djvu.online/file/E7JLHe1SqQfoa (UAZ-452V).
# Intermediate points, idle/launch/rev limits are tuning estimates, not dyno data.
var torque_curve := [Vector2(650,105), Vector2(1200,145), Vector2(2200,166.7), Vector2(2500,166.7), Vector2(3200,154), Vector2(4000,132), Vector2(4500,100), Vector2(4800,0)]
# Assumed driveline efficiency and Cd * frontal area; calibrated for ~110 km/h
# empty on pavement. The original 75 hp version was rated at 95 km/h.
const EFFICIENCY = 0.85
var drag_area := 2.2
var steering_response := 0.12
var steering_limit := 0.50
var wheels: Array[VehicleWheel3D] = []
var drive_mode := "2H"
var wheel_visuals: Array[Node3D] = []
var wheel_slip := PackedFloat32Array([0,0,0,0]) # Contact slip speed, m/s; F3 telemetry.
var wheel_omega := PackedFloat64Array([0,0,0,0])
var spin_angle := PackedFloat64Array([0,0,0,0])
var previous_spin := PackedFloat64Array([0,0,0,0])
# Contact sampler returns ice coverage and snow depth (both 0..1).
var surface_at: Callable
var surface_grip: Callable
var wheel_surfaces: Array[Vector2] = [Vector2.ZERO,Vector2.ZERO,Vector2.ZERO,Vector2.ZERO]
var model: Node3D
var steering_wheel: Node3D
var driver_eye: Marker3D
var speed := 0.0
var throttle := 0.0
var braking := false
var suspension_motion := 0.0
var previous_suspension := 0.0
var engine_rpm := 760.0
var gear := 1
var shift_time := 0.0
var brake_pressure := 0.0
var drive_force := 0.0
var sound: AudioStreamPlayer
var engine_audio: Node3D
var road_sound: AudioStreamPlayer
var rattle_sound: AudioStreamPlayer
var rattle_cooldown := 0.0
var rng := RandomNumberGenerator.new()
var paint: ShaderMaterial
var glass: ShaderMaterial
var rubber := StandardMaterial3D.new()
var steel := StandardMaterial3D.new()
var dark := StandardMaterial3D.new()
var upholstery := StandardMaterial3D.new()
var tail_material: StandardMaterial3D

func finish(color: String, metallic := 0.0, roughness := 0.8) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color)
	mat.metallic = metallic
	mat.roughness = roughness
	return mat

func mesh_part(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.mesh = mesh
	part.material_override = mat
	parent.add_child(part)
	part.position = pos
	return part

func box(parent: Node3D, pos: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	return mesh_part(parent, mesh, pos, mat)

func cylinder(parent: Node3D, pos: Vector3, radius: float, length: float, mat: Material, axis := Vector3.RIGHT) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = length
	mesh.radial_segments = 24
	var part := mesh_part(parent, mesh, pos, mat)
	part.quaternion = Quaternion(Vector3.UP, axis.normalized())
	return part

func rod(parent: Node3D, a: Vector3, b: Vector3, radius: float, mat: Material) -> MeshInstance3D:
	return cylinder(parent, (a+b)*0.5, radius, a.distance_to(b), mat, (b-a).normalized())

func _ready() -> void:
	mass = 1870 # Published unladen UAZ-452V mass (NIIAT 1985).
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	# 55/45 axle loading from the handbook; ~0.84 m COM height is an estimate.
	center_of_mass = Vector3(0,0.12,-0.22)
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0 # Explicit tire and aerodynamic forces below; no hidden default damping.
	angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	angular_damp = 0.25 # Springs/dampers, rather than global drag, settle the body.
	continuous_cd = true
	can_sleep = false
	rng.seed = 452
	paint = ShaderMaterial.new()
	paint.shader = preload("res://materials/paint.gdshader")
	glass = ShaderMaterial.new()
	glass.shader = preload("res://materials/glass.gdshader")
	rubber = finish("252828",0,0.96)
	steel = finish("888b80",0.65,0.55)
	dark = finish("343a36",0.3)
	upholstery = finish("403e34",0,0.95)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.84,1.35,3.98)
	collision.shape = shape
	collision.position = Vector3(0,0.61,0)
	add_child(collision)
	model = Node3D.new()
	model.name = "Bodywork"
	add_child(model)
	model.position = model_offset
	build_body()
	build_details()
	build_interior()
	for axle in axle_positions:
		for side in [-1,1]: build_wheel(side,axle)
	driver_eye = Marker3D.new()
	model.add_child(driver_eye)
	driver_eye.position = Vector3(-0.46,1.72,-0.70)
	make_audio()

func build_body() -> void:
	var shell := preload("res://models/bukhanka_body.glb").instantiate()
	model.add_child(shell)
	# Keep the game's paint/glass response on the editable Blender body.
	for part: MeshInstance3D in shell.find_children("*", "MeshInstance3D"):
		for surface in range(part.mesh.get_surface_count()):
			var imported := part.mesh.surface_get_material(surface)
			match imported.resource_name:
				"BodyPaint": part.set_surface_override_material(surface,paint)
				"WindowRubber": part.set_surface_override_material(surface,rubber)
				"WindowGlass":
					part.set_surface_override_material(surface,glass)
					part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The central floor stays between the new wheel openings.
	box(model,Vector3(0,0.6,0),Vector3(1.05,0.10,3.8),dark)

func build_details() -> void:
	var lamp := finish("ffe4b2",0.1,0.25)
	lamp.emission_enabled = true
	lamp.emission = Color("ffd99a")
	lamp.emission_energy_multiplier = 1.5
	var indicator := finish("b87b32",0.05,0.35)
	tail_material = finish("8c2820",0.05,0.3)
	tail_material.emission_enabled = true
	tail_material.emission = Color("b52f1d")
	var plate := ShaderMaterial.new()
	plate.shader = preload("res://materials/plate.gdshader")
	var plate_font := FontVariation.new()
	plate_font.base_font = ThemeDB.fallback_font
	plate_font.variation_embolden = 0.8
	for side in [-1,1]:
		cylinder(model,Vector3(side*0.66,1.065,-2.065),0.153,0.055,dark,Vector3.FORWARD)
		cylinder(model,Vector3(side*0.66,1.065,-2.103),0.129,0.024,lamp,Vector3.FORWARD)
		# Fluting in the headlight glass.
		for x in range(-3,4):
			box(model,Vector3(side*0.66+x*0.028,1.065,-2.118),Vector3(0.002,0.16,0.003),steel)
		cylinder(model,Vector3(side*0.70,0.77,-2.07),0.063,0.04,indicator,Vector3.FORWARD)
		var light := SpotLight3D.new()
		model.add_child(light)
		light.position = Vector3(side*0.65,1.04,-2.14)
		light.rotation.x = -0.07
		light.light_color = Color("ffdda0")
		light.light_energy = 3.5
		light.spot_range = 45
		light.spot_angle = 30
		box(model,Vector3(side*0.73,0.93,2.075),Vector3(0.14,0.25,0.05),tail_material)
		# Mirrors, hinges, door handles, seams, step and mud flaps.
		rod(model,Vector3(side*0.95,1.39,-1.72),Vector3(side*1.16,1.62,-1.82),0.014,steel)
		box(model,Vector3(side*1.17,1.66,-1.82),Vector3(0.15,0.26,0.055),rubber)
		box(model,Vector3(side*1.17,1.66,-1.786),Vector3(0.12,0.22,0.012),steel)
		box(model,Vector3(side*0.99,1.25,-0.84),Vector3(0.035,0.035,0.16),steel)
		box(model,Vector3(side*0.98,0.48,-0.69),Vector3(0.22,0.065,0.42),dark)
		for z in [-1.82,-0.68,0.29,1.27]:
			rod(model,Vector3(side*0.974,0.91,z),Vector3(side*0.974,1.30,z),0.006,rubber)
		for y in [0.98,1.28]:
			box(model,Vector3(side*0.982,y,-1.81),Vector3(0.035,0.07,0.07),steel)
		for axle in axle_positions:
			box(model,Vector3(side*0.78,0.37,axle+0.48),Vector3(0.29,0.36,0.035),rubber)
		for z in [0.55,0.68,0.81,0.94]:
			box(model,Vector3(side*0.975,1.14,z),Vector3(0.016,0.025,0.075),dark)
		# Wipers rest just above the windshield sill.
		rod(model,Vector3(side*0.3,1.35,-2.079),Vector3(side*0.5,1.46,-2.055),0.009,dark)
		rod(model,Vector3(side*0.27,1.43,-2.067),Vector3(side*0.70,1.49,-2.04),0.012,rubber)
	box(model,Vector3(0,0.76,-2.106),Vector3(0.83,0.33,0.035),rubber)
	for i in range(9):
		box(model,Vector3(-0.35+i*0.088,0.76,-2.132),Vector3(0.014,0.28,0.016),steel)
	for y in [0.66,0.76,0.86]:
		box(model,Vector3(0,y,-2.145),Vector3(0.78,0.012,0.012),dark)
	box(model,Vector3(0,1.12,-2.111),Vector3(0.36,0.085,0.025),paint)
	rod(model,Vector3(-0.09,1.25,-2.114),Vector3(0,1.21,-2.124),0.009,steel)
	rod(model,Vector3(0,1.21,-2.124),Vector3(0.09,1.25,-2.114),0.009,steel)
	for z in [-2.115,2.115]:
		box(model,Vector3(0,0.56,z),Vector3(1.99,0.14,0.12),dark)
		box(model,Vector3(0,0.67,z+signf(z)*0.042),Vector3(0.43,0.105,0.012),plate)
		var text := Label3D.new()
		model.add_child(text)
		text.text = "PORA DOMOY"
		text.font = plate_font
		text.font_size = 32
		text.pixel_size = minf(0.0017,0.385/plate_font.get_string_size(text.text,HORIZONTAL_ALIGNMENT_LEFT,-1,32).x)
		text.modulate = Color("101010")
		text.outline_size = 0
		text.position = Vector3(0,0.67,z+signf(z)*0.05)
		if z<0: text.rotation.y = PI
	rod(model,Vector3(0,0.74,2.11),Vector3(0,1.35,2.11),0.006,rubber)
	for x in [-0.12,0.12]: box(model,Vector3(x,1.18,2.12),Vector3(0.12,0.035,0.035),steel)
	# Ladder frame and differential housings, above the snow.
	for x in [-0.53,0.53]: box(model,Vector3(x,0.39,0),Vector3(0.08,0.12,3.65),dark)
	for z in axle_positions:
		cylinder(model,Vector3(0,0.34,z),0.055,1.45,dark)
		cylinder(model,Vector3(0,0.34,z),0.13,0.25,dark)

func build_interior() -> void:
	box(model,Vector3(0,1.26,-1.65),Vector3(1.72,0.17,0.46),paint)
	box(model,Vector3(0,1.35,-1.66),Vector3(1.72,0.045,0.47),rubber)
	box(model,Vector3(0,0.91,-0.7),Vector3(0.54,0.54,1.17),upholstery)
	for side in [-1,1]:
		box(model,Vector3(side*0.52,0.88,-0.61),Vector3(0.49,0.17,0.59),upholstery)
		var back := box(model,Vector3(side*0.52,1.18,-0.29),Vector3(0.49,0.58,0.13),upholstery)
		back.rotation.x = -0.12
		for x in [-0.17,0.17]:
			rod(model,Vector3(side*0.52+x,0.64,-0.8),Vector3(side*0.52+x,0.82,-0.35),0.018,steel)
		for z in [0.65,1.38]:
			box(model,Vector3(side*0.52,0.87,z),Vector3(0.51,0.15,0.55),upholstery)
			box(model,Vector3(side*0.52,1.14,z+0.23),Vector3(0.51,0.47,0.12),upholstery)
		# Inner door card and window crank.
		box(model,Vector3(side*0.90,1.13,-1.25),Vector3(0.03,0.3,0.90),dark)
		rod(model,Vector3(side*0.87,1.15,-1.1),Vector3(side*0.87,1.1,-1.23),0.012,steel)
	for x in [-0.46,-0.19]:
		cylinder(model,Vector3(x,1.27,-1.407),0.074 if x< -0.3 else 0.043,0.018,steel,Vector3.BACK)
		cylinder(model,Vector3(x,1.27,-1.393),0.063 if x< -0.3 else 0.035,0.009,rubber,Vector3.BACK)
		rod(model,Vector3(x,1.27,-1.382),Vector3(x-0.025,1.3,-1.382),0.003,finish("ddd4b1"))
	box(model,Vector3(0.51,1.26,-1.408),Vector3(0.43,0.12,0.012),dark)
	for x in [0.08,0.18,0.28]: cylinder(model,Vector3(x,1.25,-1.396),0.014,0.025,rubber,Vector3.BACK)
	rod(model,Vector3(-0.47,0.78,-1.5),Vector3(-0.47,1.35,-1.18),0.024,dark)
	steering_wheel = Node3D.new()
	model.add_child(steering_wheel)
	steering_wheel.position = Vector3(-0.47,1.36,-1.18)
	steering_wheel.rotation.x = -0.55
	var ring := TorusMesh.new()
	ring.inner_radius = 0.18
	ring.outer_radius = 0.199
	ring.rings = 32
	ring.ring_segments = 8
	var rim := mesh_part(steering_wheel,ring,Vector3.ZERO,rubber)
	rim.rotation.x = PI/2
	cylinder(steering_wheel,Vector3.ZERO,0.048,0.03,steel,Vector3.BACK)
	for i in range(3):
		var angle := i*TAU/3
		rod(steering_wheel,Vector3.ZERO,Vector3(cos(angle)*0.183,sin(angle)*0.183,0),0.009,steel)
	for x in [0.17,0.29]:
		rod(model,Vector3(x,0.72,-0.95),Vector3(x,1.12,-1.06),0.012,steel)
		cylinder(model,Vector3(x,1.13,-1.06),0.026,0.04,rubber,Vector3.UP)
	box(model,Vector3(0,1.80,-1.64),Vector3(0.25,0.09,0.035),steel)
	for side in [-1,1]: box(model,Vector3(side*0.43,1.87,-1.74),Vector3(0.56,0.12,0.035),upholstery)

func build_wheel(side: int, axle: float) -> void:
	var wheel := VehicleWheel3D.new()
	wheel.name = ("Front" if axle<0 else "Rear") + ("Left" if side<0 else "Right")
	wheel.position = Vector3(side*0.7275,-0.22,axle)
	wheel.wheel_radius = 0.375
	wheel.wheel_rest_length = 0.24
	wheel.suspension_travel = 0.22
	wheel.suspension_stiffness = 24 if axle<0 else 22 # Front carries more of the empty van.
	wheel.suspension_max_force = 14000
	wheel.damping_compression = 1.8
	wheel.damping_relaxation = 2.8
	wheel.wheel_friction_slip = 0.0 # Tire forces below; keep native suspension only.
	wheel.use_as_traction = axle>0
	wheel.use_as_steering = axle<0
	wheel.set_meta("connection",wheel.position)
	add_child(wheel)
	wheels.append(wheel)
	# Native wheel handles suspension/steering/rolling; this pivot adds tire slip.
	var tire := Node3D.new()
	wheel.add_child(tire)
	wheel_visuals.append(tire)
	cylinder(tire,Vector3.ZERO,0.375,0.225,rubber)
	cylinder(tire,Vector3(side*0.119,0,0),0.235,0.025,dark)
	cylinder(tire,Vector3(side*0.137,0,0),0.201,0.025,steel)
	cylinder(tire,Vector3(side*0.163,0,0),0.09,0.07,dark)
	for i in range(5):
		var angle := i*TAU/5
		cylinder(tire,Vector3(side*0.155,cos(angle)*0.127,sin(angle)*0.127),0.018,0.018,dark)
		cylinder(tire,Vector3(side*0.157,cos(angle)*0.175,sin(angle)*0.175),0.022,0.01,rubber)
	for i in range(30):
		var angle := i*TAU/30
		for lane in [-1,1]:
			var tread := box(tire,Vector3(lane*0.059,cos(angle)*0.371,sin(angle)*0.371),Vector3(0.10,0.018,0.042),rubber)
			tread.rotation.x = angle

func engine_torque(rpm: float) -> float:
	for i in range(torque_curve.size()-1):
		if rpm <= torque_curve[i+1].x:
			var t := inverse_lerp(torque_curve[i].x,torque_curve[i+1].x,rpm)
			return lerpf(torque_curve[i].y,torque_curve[i+1].y,clampf(t,0,1))
	return 0.0

func select_drive_mode(mode: String) -> bool:
	if mode not in ["2H","4H","4L"]: return false
	if mode==drive_mode: return true
	if (mode=="4L" or drive_mode=="4L") and linear_velocity.length()>0.1: return false
	drive_mode = mode
	for wheel in wheels: wheel.use_as_traction = mode!="2H" or not wheel.use_as_steering
	return true

func reset_wheel_motion() -> void:
	for i in range(wheels.size()):
		wheel_slip[i] = 0
		wheel_omega[i] = 0
		spin_angle[i] = 0
		previous_spin[i] = 0

func contact_load(i: int) -> float:
	var wheel := wheels[i]
	if not wheel.is_in_contact(): return 0.0
	# Reconstruct the native spring/damper load from its contact, without changing it.
	var normal := wheel.get_contact_normal()
	var connection := to_global(wheel.get_meta("connection"))
	# The native ray starts one radius above the connection, but scales hit distance.
	var ray_length := wheel.wheel_rest_length+wheel.wheel_radius
	var distance := (connection-wheel.get_contact_point()).dot(global_basis.y)+wheel.wheel_radius
	var length := clampf(distance*ray_length/(ray_length+wheel.wheel_radius)-wheel.wheel_radius,wheel.wheel_rest_length-wheel.suspension_travel,wheel.wheel_rest_length+wheel.suspension_travel)
	var inverse_dot := 1/maxf(0.1,normal.dot(global_basis.y))
	var velocity := linear_velocity+angular_velocity.cross(wheel.get_contact_point()-global_position)
	var rate := velocity.dot(normal)*inverse_dot
	var damping := wheel.damping_compression if rate<0 else wheel.damping_relaxation
	return clampf(mass*(wheel.suspension_stiffness*(wheel.wheel_rest_length-length)*inverse_dot-damping*rate),0,wheel.suspension_max_force)

func tyre_grip(i: int) -> float:
	var cover := wheel_surfaces[i]
	var grip := lerpf(lerpf(0.42,0.36,cover.y),0.045,cover.x)
	if surface_grip.is_valid() and wheels[i].is_in_contact():
		return surface_grip.call(wheels[i].get_contact_point(),grip)
	return grip

func wheel_drive_torque(_i: int, shaft_torque: float, driven_count: int) -> float:
	return shaft_torque/driven_count # One engine; 50/50 axle split in 4WD.

func drive(accelerator: float, turn: float, foot_brake: bool, delta: float) -> void:
	speed = -linear_velocity.dot(global_basis.z)
	shift_time = maxf(shift_time-delta,0)
	var change_direction := absf(accelerator)>0.1 and (accelerator<0)!=(gear<0)
	braking = foot_brake or (change_direction and absf(speed)>0.4)
	if change_direction and not braking:
		gear = -1 if accelerator<0 else 1
		shift_time = 0.3
	var pedal := absf(accelerator) if not braking else 0.0
	throttle = move_toward(throttle,pedal,delta*(2.5 if pedal>throttle else 5.0))
	# Prompt pedal/rack response; mass and contact forces provide the heaviness.
	# Leave enough steering authority to exceed grip and countersteer on snow.
	var limit := minf(steering_limit,maxf(0.10,atan((axle_positions[1]-axle_positions[0])*8.0/maxf(speed*speed,1))))
	steering = lerpf(steering,turn*limit,1-exp(-delta/(steering_response+absf(speed)*0.003)))
	var driven_count := 2 if drive_mode=="2H" else 4
	var wheel_rotation := 0.0
	var contacts := 0
	var rolling_coefficient := 0.0
	var spinning := false
	for i in range(wheels.size()):
		var wheel := wheels[i]
		if wheel.is_in_contact():
			wheel_surfaces[i] = surface_at.call(wheel.get_contact_point()) if surface_at.is_valid() else Vector2.ZERO
			contacts += 1
		var cover := wheel_surfaces[i]
		rolling_coefficient += lerpf(lerpf(0.035,0.30,cover.y),0.008,cover.x)/wheels.size()
		if wheel.use_as_traction:
			wheel_rotation += wheel_omega[i]/driven_count
			spinning = spinning or absf(wheel_omega[i]*wheel.wheel_radius-speed)>maxf(2.0,absf(speed)*0.4)
	var transfer := low_range if drive_mode=="4L" else 1.0
	var ratio: float = (gear_ratios[gear-1] if gear>0 else reverse_ratio)*transfer
	var wheel_rpm := absf(wheel_rotation)*60/TAU
	var coupled_rpm := wheel_rpm*ratio*final_drive
	if gear>0 and shift_time<=0 and contacts>0:
		var next_gear := gear
		if absf(speed)<0.5 and not spinning: next_gear = 1
		elif coupled_rpm>3600 and gear<4 and throttle>0.1 and not spinning:
			var higher_ratio: float = gear_ratios[gear]*transfer
			var available := engine_torque(coupled_rpm*higher_ratio/ratio)*higher_ratio*final_drive*EFFICIENCY/wheels[0].wheel_radius
			var load := mass*9.81*(rolling_coefficient+maxf(-global_basis.z.y,0))+0.5*1.225*drag_area*speed*speed
			if available>load+200: next_gear += 1
		elif coupled_rpm<1400 and gear>1: next_gear -= 1
		if next_gear!=gear:
			gear = next_gear
			shift_time = 0.3
			ratio = gear_ratios[gear-1]*transfer
			coupled_rpm = wheel_rpm*ratio*final_drive
	var uphill := maxf(-global_basis.z.y if gear>0 else global_basis.z.y,0)
	var launch_rpm := 1400+800*smoothstep(0,0.3,uphill)
	engine_rpm = lerpf(engine_rpm,maxf(coupled_rpm,lerpf(760,launch_rpm,throttle)),1-exp(-delta*8))
	var shaft_torque := (1 if gear>0 else -1)*engine_torque(engine_rpm)*throttle*ratio*final_drive*EFFICIENCY
	if shift_time>0: shaft_torque = 0
	else:
		var overrun := 10+28*pow(engine_rpm/3000,2)
		var closed_throttle := maxf(1-throttle,smoothstep(4500,5000,engine_rpm))
		shaft_torque -= signf(wheel_rotation)*overrun*closed_throttle*smoothstep(760,1200,coupled_rpm)*ratio*final_drive
	if braking or brake_pressure>0: shaft_torque = 0
	brake_pressure = move_toward(brake_pressure,1.0 if braking else 0.0,delta*6)
	engine_force = 0
	# Longitudinal braking is included in tire torque; native brake would apply it twice.
	brake = 0
	apply_central_force(-linear_velocity*linear_velocity.length()*0.5*1.225*drag_area)
	var suspension := 0.0
	drive_force = 0.0
	for i in range(wheels.size()):
		var wheel := wheels[i]
		var radius := wheel.wheel_radius
		var normal := wheel.get_contact_normal() if wheel.is_in_contact() else global_basis.y
		var point := wheel.get_contact_point() if wheel.is_in_contact() else wheel.global_position
		var velocity := linear_velocity+angular_velocity.cross(point-to_global(center_of_mass))
		var forward := (-global_basis.z).rotated(global_basis.y,wheel.steering).slide(normal).normalized()
		var rolling_speed := velocity.dot(forward)
		var slip_speed := wheel_omega[i]*radius-rolling_speed
		var side := forward.cross(normal)
		var lateral_speed := velocity.dot(side)
		wheel_slip[i] = slip_speed if wheel.is_in_contact() else 0.0
		var cover := wheel_surfaces[i]
		var grip := tyre_grip(i)
		var slip := Vector2(slip_speed,lateral_speed).length()/maxf(absf(rolling_speed),2.0)
		grip *= lerpf(1.0,0.78,smoothstep(0.12,0.8,slip))
		var load := contact_load(i)
		var inertia := WHEEL_INERTIA
		var torque := 0.0
		if wheel.use_as_traction:
			torque = wheel_drive_torque(i,shaft_torque,driven_count)
			inertia += ENGINE_INERTIA*pow(ratio*final_drive,2)/driven_count
		var brake_torque := brake_pressure*mass*5.0*radius/wheels.size()
		var brake_reaction := clampf(wheel_omega[i]*inertia/delta+torque,-brake_torque,brake_torque)
		# Implicit rolling constraint; excess torque accelerates the tire, not the van.
		var share := mass*(0.275 if wheel.use_as_steering else 0.225)
		# Include chassis acceleration in the rolling constraint, not just wheel inertia.
		var force := (torque-brake_reaction+slip_speed*inertia/(radius*delta))/radius
		force /= 1.0+inertia/(share*radius*radius)
		force = clampf(force,-grip*load,grip*load)
		wheel_omega[i] += (torque-force*radius)*delta/inertia
		wheel_omega[i] = move_toward(wheel_omega[i],0,brake_torque*delta/inertia)
		# Native friction can rescale drive force without updating our wheel spin.
		# Apply both tire forces here, at the full contact lever arm for roll/pitch.
		# A shared friction circle: drive/brake force leaves less cornering grip.
		# Finite cornering stiffness builds slip before saturation; rear is slightly firmer.
		var remaining := sqrt(maxf(pow(grip*load,2)-force*force,0.0))
		var lateral := -lateral_speed*load*(5.0 if wheel.use_as_steering else 5.5)/maxf(absf(rolling_speed),2.0)
		lateral /= sqrt(1.0+pow(lateral/maxf(remaining,1.0),2))
		wheel.engine_force = 0
		wheel.brake = 0
		if wheel.is_in_contact():
			apply_force(forward*force+side*lateral,point-global_position)
		previous_spin[i] = spin_angle[i]
		# Native wheel basis is mirrored; account for its handedness when adding roll.
		spin_angle[i] -= signf(wheel.basis.determinant())*(wheel_omega[i]+wheel.get_rpm()*TAU/60)*delta
		drive_force += force
		if wheel.is_in_contact():
			var resistance := lerpf(lerpf(0.035,0.30,cover.y),0.008,cover.x)*load
			# Soil compaction opposes impending motion, up to the available snow resistance.
			var demand := velocity.slide(normal)*share/delta+forward*force+Vector3.DOWN*9.81*share
			apply_force(-demand.slide(normal).limit_length(resistance),point-global_position)
		suspension += wheel.position.y
	suspension_motion = lerpf(suspension_motion,absf(suspension-previous_suspension)/maxf(delta,0.001),0.15)
	previous_suspension = suspension
	steering_wheel.rotation.z = steering*5
	tail_material.emission_energy_multiplier = 1.7 if braking else 0.25

# Original PCM engine fallback, road noise and suspension rattle.
func audio_loop(kind: int) -> AudioStreamWAV:
	var rate := 22050
	var count := rate if kind<2 else int(rate*0.22)
	var data := PackedByteArray()
	data.resize(count*2)
	var filtered := 0.0
	for i in range(count):
		var t := float(i)/rate
		var noise := rng.randf_range(-1,1)
		filtered = lerpf(filtered,noise,0.12)
		var sample := 0.0
		if kind==0:
			var phase := fmod(t*40.0,1.0)
			sample = (exp(-phase*12)-0.083)*0.7+sin(t*TAU*40)*0.28+sin(t*TAU*80)*0.10+filtered*0.06
		elif kind==1:
			sample = filtered*0.7+noise*0.05
		else:
			sample = (sin(t*TAU*83)*noise*0.5+filtered)*exp(-t*26)
		data.encode_s16(i*2,int(clampf(sample,-1,1)*28000))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.data = data
	if kind<2:
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		stream.loop_end = count
	return stream

func make_audio() -> void:
	# The headless server has no sound output or audio mixing thread.
	if DisplayServer.get_name() == "headless": return
	for kind in range(3):
		var player := AudioStreamPlayer.new()
		player.bus = &"SFX"
		player.stream = audio_loop(kind)
		add_child(player)
		match kind:
			0: sound = player
			1: road_sound = player
			2: rattle_sound = player
	sound.volume_db = -22
	road_sound.volume_db = -60
	engine_audio = preload("res://scripts/engine_audio.gd").new()
	add_child(engine_audio)
	engine_audio.setup(self,sound)
	road_sound.play()

func _process(delta: float) -> void:
	for i in range(wheel_visuals.size()):
		var wheel := wheels[i]
		var tire := wheel_visuals[i]
		# Native suspension centres can sit below the ray contact's radius.
		# Correct only the mesh along suspension travel; retain steering and roll.
		tire.position = Vector3.ZERO
		if wheel.is_in_contact():
			var normal := wheel.get_contact_normal()
			var up := global_basis.y.normalized()
			var clearance := (wheel.global_position-wheel.get_contact_point()).dot(normal)
			var offset := (wheel.wheel_radius-clearance)/maxf(up.dot(normal),0.1)
			tire.position = wheel.global_basis.inverse()*(up*offset)
		tire.rotation.x = lerpf(previous_spin[i],spin_angle[i],Engine.get_physics_interpolation_fraction())
	paint.set_shader_parameter("body_inverse",model.global_transform.affine_inverse())
	if not sound: return
	road_sound.pitch_scale = 0.75+minf(absf(speed)/18,0.75)
	road_sound.volume_db = linear_to_db(clampf(absf(speed)/18,0.001,1)*0.18+(0.06 if braking and absf(speed)>0.5 else 0.0))
	rattle_cooldown -= delta
	if suspension_motion>0.45 and absf(speed)>1.5 and rattle_cooldown<=0:
		rattle_sound.volume_db = -27+minf(suspension_motion,2)*3
		rattle_sound.pitch_scale = rng.randf_range(0.85,1.1)
		rattle_sound.play()
		rattle_cooldown = 0.25

func _exit_tree() -> void:
	for player in [sound,road_sound,rattle_sound]:
		if is_instance_valid(player):
			player.stop()
			player.stream = null
