extends "res://scripts/vehicle.gd"

# Original 1600 three-door: 2.20 m wheelbase, 1.43/1.40 m track.
# FIA T-1039 photos/dimensions and transfer ratios; see models/source/README.md.
# Spring/damper values, torque interpolation and differential coupling are estimates.
var centre_locked := false
var axle_speed_difference := 0.0
var shell: Node3D

func _init() -> void:
	axle_positions = [-1.10,1.10]
	model_offset = Vector3(0,-0.60,0)
	gear_ratios = [3.667,2.10,1.361,1.0]
	reverse_ratio = 3.526
	final_drive = 4.3*1.2 # Early final drive, including high transfer range.
	low_range = 2.135/1.2
	drag_area = 1.05
	torque_curve = [Vector2(650,65),Vector2(1200,90),Vector2(2200,108),Vector2(3400,116),Vector2(4500,108),Vector2(5200,101),Vector2(5800,0)]
	steering_response = 0.085
	steering_limit = 0.56
	drive_mode = "4H"

func _ready() -> void:
	super._ready()
	mass = 1210
	center_of_mass = Vector3(0,0.02,-0.13)
	var collision: CollisionShape3D = get_child(0)
	collision.shape.size = Vector3(1.52,0.87,3.25)
	collision.position = Vector3(0,0.40,0)
	driver_eye.position = Vector3(-0.40,1.30,0.02)

func build_body() -> void:
	paint.shader = preload("res://materials/niva_paint.gdshader")
	shell = preload("res://models/niva_2121.glb").instantiate()
	model.add_child(shell)
	for part: MeshInstance3D in shell.find_children("*","MeshInstance3D"):
		for surface in range(part.mesh.get_surface_count()):
			var imported := part.mesh.surface_get_material(surface)
			match imported.resource_name:
				"NivaWhite": part.set_surface_override_material(surface,paint)
				"NivaGlass":
					part.set_surface_override_material(surface,glass)
					part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				"NivaLamp":
					var bulb: StandardMaterial3D = imported.duplicate()
					bulb.emission_enabled = true
					bulb.emission = Color("ffd99a")
					bulb.emission_energy_multiplier = 1.0
					part.set_surface_override_material(surface,bulb)
				"NivaTail":
					if not tail_material:
						tail_material = imported.duplicate()
						tail_material.emission_enabled = true
						tail_material.emission = Color("b52f1d")
					part.set_surface_override_material(surface,tail_material)
	steering_wheel = shell.find_child("SteeringWheel",true,false)

func build_details() -> void:
	# Lamps belong to the imported body; only their light sources are runtime nodes.
	for side in [-1,1]:
		var light := SpotLight3D.new()
		model.add_child(light)
		light.position = Vector3(side*0.594,0.82,-1.80)
		light.rotation.x = -0.07
		light.light_color = Color("ffdda0")
		light.light_energy = 3.5
		light.spot_range = 45
		light.spot_angle = 30

func build_interior() -> void:
	pass # Dashboard, chairs and steering wheel are editable Blender meshes.

func build_wheel(side: int, axle: float) -> void:
	var wheel := VehicleWheel3D.new()
	wheel.name = ("Front" if axle<0 else "Rear")+("Left" if side<0 else "Right")
	wheel.position = Vector3(side*(0.715 if axle<0 else 0.700),-0.18,axle)
	wheel.set_meta("connection",wheel.position)
	wheel.wheel_radius = 0.345
	wheel.wheel_rest_length = 0.20
	wheel.suspension_travel = 0.19
	wheel.suspension_stiffness = 29 if axle<0 else 25
	wheel.suspension_max_force = 10000
	wheel.damping_compression = 2.2
	wheel.damping_relaxation = 3.2
	wheel.wheel_friction_slip = 0.0
	wheel.use_as_traction = true
	wheel.use_as_steering = axle<0
	add_child(wheel)
	wheels.append(wheel)
	var tire := Node3D.new()
	wheel.add_child(tire)
	wheel_visuals.append(tire)
	var mesh: Node3D = shell.find_child(str(wheel.name),true,false)
	mesh.reparent(tire,false)
	mesh.position = Vector3.ZERO

func select_drive_mode(mode: String) -> bool:
	if mode not in ["4H","4L"]: return false
	return super.select_drive_mode(mode)

func toggle_centre_lock() -> bool:
	if linear_velocity.length()>0.1 or angular_velocity.length()>0.1: return false
	centre_locked = not centre_locked
	return true

func tyre_grip(i: int) -> float:
	var body := wheels[i].get_contact_body()
	if is_instance_valid(body):
		match StringName(body.get_meta("surface_type",&"")):
			&"dirt": return 0.65
			&"mud": return 0.28
	return super.tyre_grip(i)

func drive(accelerator: float, turn: float, foot_brake: bool, delta: float) -> void:
	axle_speed_difference = (wheel_omega[0]+wheel_omega[1]-wheel_omega[2]-wheel_omega[3])*0.5
	super.drive(accelerator,turn,foot_brake,delta)

func wheel_drive_torque(i: int, shaft_torque: float, _driven_count: int) -> float:
	if not centre_locked:
		# Open centre: equal axle torque is limited by the less supported axle.
		# Retain some torque to spin unloaded wheels rather than multiplying grip.
		var capacity := [0.0,0.0]
		for j in range(4):
			var grip := tyre_grip(j)
			capacity[j/2] += contact_load(j)*grip*wheels[j].wheel_radius
		return signf(shaft_torque)*minf(absf(shaft_torque)*0.25,minf(capacity[0],capacity[1])*0.5+12.0)
	# Lock couples axle speeds, transferring torque away from the spinning axle.
	var coupling := clampf(axle_speed_difference*18.0,-180.0,180.0)
	return shaft_torque*0.25+(-coupling if i<2 else coupling)
