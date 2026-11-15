extends Camera3D

var active := false
var car: VehicleBody3D
var driving_camera: Camera3D
var instructions: Label
var driving_hint: String
var center: Vector3
var pan := Vector3.ZERO
var orbit := Vector2.ZERO
var distance := 7.0
var safe_distance := 3.0

func setup(vehicle: VehicleBody3D, previous_camera: Camera3D, hint: Label) -> void:
	car = vehicle
	driving_camera = previous_camera
	instructions = hint
	driving_hint = hint.text
	process_mode = Node.PROCESS_MODE_ALWAYS
	near = 0.06
	far = previous_camera.far
	fov = 55

func toggle() -> void:
	active = not active
	# Freezing VehicleBody3D can corrupt grounded wheels on release (Godot #92891).
	# Pause the simulation instead; this camera still receives input while paused.
	get_tree().paused = active
	if active:
		# Include mirrors and wheels, which extend beyond the chassis collider.
		var bounds := AABB()
		for part: MeshInstance3D in car.find_children("*", "MeshInstance3D", true, false):
			bounds = bounds.merge((car.global_transform.affine_inverse() * part.global_transform) * part.get_aabb())
		center = car.to_global(bounds.get_center())
		safe_distance = bounds.size.length() * 0.5 + 0.25
		reset_view()
		make_current()
		instructions.text = "INSPECTION · Driving paused\nLeft drag: orbit   Wheel: zoom   Middle drag: pan   R: reset   V: drive · Esc: pause"
	else:
		driving_camera.make_current()
		instructions.text = driving_hint

func reset_view() -> void:
	pan = Vector3.ZERO
	orbit = Vector2(car.rotation.y + 0.6, 0.25)
	distance = maxf(7.0, safe_distance * 2.0)
	update_view()

func _input(event: InputEvent) -> void:
	if get_parent().audio_settings.visible: return
	if event is InputEventKey and event.pressed and not event.echo:
		var key: int = event.physical_keycode if event.physical_keycode else event.keycode
		if key == KEY_V:
			toggle()
		elif active:
			if key == KEY_ESCAPE: return
			elif key == KEY_R: reset_view()
		else:
			return
	elif active and event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			orbit.x -= event.relative.x * 0.006
			orbit.y = clampf(orbit.y - event.relative.y * 0.006, 0.02, PI / 2.0 - 0.01)
		elif event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			pan += (-global_basis.x * event.relative.x + global_basis.y * event.relative.y) * distance * 0.0015
		update_view()
	elif active and event is InputEventMouseButton:
		if event.pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP: distance /= 1.12
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN: distance *= 1.12
			distance = clampf(distance, safe_distance, 20.0)
			update_view()
	else:
		return
	get_viewport().set_input_as_handled()

func update_view() -> void:
	var direction := Vector3(sin(orbit.x) * cos(orbit.y), sin(orbit.y), cos(orbit.x) * cos(orbit.y))
	global_position = center + pan + direction * distance
	# Panning must not bypass the zoom limit and move the lens into the van.
	var away := global_position - center
	if away.length() < safe_distance:
		global_position = center + (away.normalized() if away.length_squared() > 0.0001 else direction) * safe_distance
	look_at(center + pan)
