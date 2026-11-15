extends Node3D

const TRACK_LIMIT := 4096
const TRACK_STEP := 0.22
# Dirt/mud are opt-in collider metadata: surface_type = "dirt" or "mud".
# The winter landscape and its physical contact sampler remain unchanged.
const SURFACES := [&"snow", &"ice", &"dirt", &"mud"]
var car: VehicleBody3D
var landscape: Node3D
var emitters: Array = []
var previous: Array[Vector3] = [Vector3.INF,Vector3.INF,Vector3.INF,Vector3.INF]
var contact_before: Array[Vector3] = [Vector3.ZERO,Vector3.ZERO,Vector3.ZERO,Vector3.ZERO]
var contact_now: Array[Vector3] = [Vector3.ZERO,Vector3.ZERO,Vector3.ZERO,Vector3.ZERO]
var grounded := [false,false,false,false]
var spin_delay := [0.0,0.0,0.0,0.0]
var phase := [0.0,0.0,0.0,0.0]
var tracks: MultiMeshInstance3D
var track_material: ShaderMaterial
var clock := 0.0
var track_count := 0
var next_track := 0

func setup(vehicle: VehicleBody3D, terrain: Node3D) -> void:
	car = vehicle
	landscape = terrain
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	for i in range(4):
		emitters.append([make_emitter(0),make_emitter(1),make_emitter(2)])
	tracks = MultiMeshInstance3D.new()
	tracks.name = "TyreTracks"
	tracks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	tracks.multimesh = MultiMesh.new()
	tracks.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	tracks.multimesh.use_colors = true
	tracks.multimesh.use_custom_data = true
	var plane := PlaneMesh.new()
	plane.size = Vector2(0.24,1.0)
	track_material = ShaderMaterial.new()
	track_material.shader = preload("res://materials/tyre_tracks.gdshader")
	plane.material = track_material
	tracks.multimesh.mesh = plane
	tracks.multimesh.instance_count = TRACK_LIMIT
	tracks.multimesh.visible_instance_count = 0
	add_child(tracks)

func make_emitter(kind: int) -> GPUParticles3D:
	var emitter := GPUParticles3D.new()
	emitter.name = ["Snow","Dust","Mud"][kind]+str(emitters.size())
	emitter.emitting = false
	emitter.amount = 160
	emitter.lifetime = 1.6
	emitter.local_coords = false
	emitter.fixed_fps = 30
	emitter.visibility_aabb = AABB(Vector3(-85,-8,-85),Vector3(170,24,170))
	emitter.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.09
	process.gravity = Vector3(0,-3.2,0)
	process.spread = 34
	process.damping_min = 0.5
	process.damping_max = 1.2
	process.scale_min = 0.05
	process.scale_max = 0.15
	process.lifetime_randomness = 0.45
	process.angle_min = -180
	process.angle_max = 180
	process.color = Color("d2deeb")
	if kind==1:
		emitter.amount = 112
		emitter.lifetime = 2.4
		process.color = Color("d0ba96")
		process.gravity = Vector3(0.08,0.12,-0.05)
		process.damping_min = 1.0
		process.damping_max = 1.8
		process.scale_min = 0.18
		process.scale_max = 0.42
	elif kind==2:
		emitter.amount = 72
		emitter.lifetime = 0.8
		process.color = Color("49382a")
		process.gravity = Vector3(0,-9.8,0)
		process.damping_min = 0.1
		process.damping_max = 0.4
		process.scale_min = 0.04
		process.scale_max = 0.10
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0,0.12,0.5,1])
	var opacity: float = [0.55,0.48,0.85][kind]
	gradient.colors = PackedColorArray([Color(1,1,1,0),Color(1,1,1,opacity),Color(1,1,1,opacity*0.5),Color(1,1,1,0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	process.color_ramp = ramp
	var curve := Curve.new()
	curve.add_point(Vector2(0,0.5))
	curve.add_point(Vector2(0.4,1))
	curve.add_point(Vector2(1,1.0 if kind==2 else 1.9))
	var size := CurveTexture.new()
	size.curve = curve
	process.scale_curve = size
	emitter.process_material = process
	var soft := GradientTexture2D.new()
	soft.width = 32
	soft.height = 32
	soft.fill = GradientTexture2D.FILL_RADIAL
	soft.fill_from = Vector2(0.5,0.5)
	soft.fill_to = Vector2(0.5,1)
	soft.gradient = Gradient.new()
	soft.gradient.colors = PackedColorArray([Color.WHITE,Color(1,1,1,0)])
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.albedo_texture = soft
	material.roughness = 1.0
	var quad := QuadMesh.new()
	if kind==2: quad.size = Vector2(0.65,1.0)
	quad.material = material
	emitter.draw_pass_1 = quad
	if kind==2:
		var clod := SphereMesh.new()
		clod.radius = 0.5
		clod.height = 0.75
		clod.radial_segments = 5
		clod.rings = 2
		material.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
		material.albedo_texture = null
		material.roughness = 0.3
		clod.material = material
		emitter.draw_pass_1 = clod
	add_child(emitter)
	return emitter

func _physics_process(delta: float) -> void:
	clock += delta
	for i in range(4):
		var wheel: VehicleWheel3D = car.wheels[i]
		var contact := wheel.get_contact_point()
		var touching: bool = wheel.is_in_contact() and car.contact_load(i)>25 and contact.distance_to(car.global_position)<5
		if not touching:
			for stream: GPUParticles3D in emitters[i]: stream.emitting = false
			previous[i] = Vector3.INF
			grounded[i] = false
			continue
		contact_before[i] = contact_now[i] if grounded[i] else contact
		contact_now[i] = contact
		grounded[i] = true
		var normal := wheel.get_contact_normal()
		var forward := (-car.global_basis.z).rotated(car.global_basis.y,wheel.steering).slide(normal).normalized()
		var velocity := car.linear_velocity+car.angular_velocity.cross(contact-car.global_position)
		var speed := velocity.slide(normal).length()
		var rotation_speed: float = car.wheel_omega[i]*wheel.wheel_radius
		var slip := absf(rotation_speed-velocity.dot(forward))
		var lateral := absf(velocity.dot(normal.cross(forward)))
		var depth: float = car.wheel_surfaces[i].y
		var ice: float = car.wheel_surfaces[i].x
		var kind := 1 if ice>0.5 else 0
		var body := wheel.get_contact_body()
		if is_instance_valid(body):
			var tag := StringName(body.get_meta("surface_type",&""))
			var tagged := SURFACES.find(tag)
			if tagged>=0:
				kind = tagged
				ice = 1.0 if kind==1 else 0.0
				depth = 0.0
			elif tag==&"deep_snow":
				kind = 0
				ice = 0.0
				depth = 0.95
		var preset := maxi(0,kind-1)
		var emitter: GPUParticles3D = emitters[i][preset]
		var activity := maxf(0,speed*0.22+slip*0.85+lateral*0.7-0.30)
		var process := emitter.process_material as ParticleProcessMaterial
		var inheritance: float = [0.45,0.10,0.50][preset]
		var kick: float = [0.30,0.10,0.42][preset]
		var lift: float = [0.55,1.10,1.15][preset]
		var launch := velocity*inheritance-forward*rotation_speed*kick+normal*(lift+minf(activity,10)*0.16)
		process.direction = launch.normalized()
		process.initial_velocity_min = launch.length()*0.65
		process.initial_velocity_max = launch.length()*1.2
		if preset==0:
			process.scale_min = 0.02 if kind==1 else 0.045+depth*0.04
			process.scale_max = 0.05 if kind==1 else 0.13+depth*0.16
		var density := (0.30+depth*0.70)*(1-ice*0.98) if preset==0 else (1.7 if preset==1 else 0.65)
		emitter.amount_ratio = clampf(clampf(activity/6,0,1)*density,0,1)
		if kind==1: emitter.amount_ratio = clampf(activity/12,0,1)*0.035
		for j in range(3): emitters[i][j].emitting = j==preset and emitter.amount_ratio>0.015
		if previous[i]==Vector3.INF or contact.distance_to(previous[i])>1.5:
			previous[i] = contact
			continue
		var travel := contact.distance_to(previous[i])
		if speed<0.25 and absf(rotation_speed)<0.5:
			previous[i] = contact
			continue
		var strength := clampf((slip+lateral)/5,0,1)
		var color := Color(0.40,0.49,0.60,0.19+depth*0.10+strength*0.09)
		if kind==1: color = Color(0.70,0.83,0.94,0.035+strength*0.13)
		elif kind==2: color = Color(0.23,0.18,0.13,0.28+strength*0.15)
		elif kind==3: color = Color(0.12,0.085,0.055,0.50+strength*0.22)
		if travel>=TRACK_STEP:
			var steps := mini(8,ceili(travel/TRACK_STEP))
			var direction := (contact-previous[i]).normalized()
			for j in range(steps):
				var p := previous[i].lerp(contact,(j+0.5)/steps)
				stamp(p,normal,direction,travel/steps+0.015,kind,color,strength,phase[i])
				phase[i] += travel/steps
			previous[i] = contact
		elif slip>1.2:
			spin_delay[i] -= delta
			if spin_delay[i]<=0:
				stamp(contact,normal,forward,0.28,kind,color,strength,phase[i])
				spin_delay[i] = 0.25

func stamp(point: Vector3, normal: Vector3, tangent: Vector3, length: float, kind: int, color: Color, smear: float, offset: float) -> void:
	var right := normal.cross(tangent).normalized()
	var basis := Basis(right,normal,right.cross(normal)).scaled(Vector3(1,1,length))
	if is_instance_valid(landscape):
		var road := absf(point.x-landscape.road_point(point.z).x)<4.3
		point.y = landscape.collision_height(point.x,point.z)+(0.048 if road else 0.018)
	else: point += normal*0.018
	tracks.multimesh.set_instance_transform(next_track,Transform3D(basis,point))
	tracks.multimesh.set_instance_color(next_track,color)
	tracks.multimesh.set_instance_custom_data(next_track,Color(clock,kind+smear*0.25,length,fposmod(offset,PI/24)))
	next_track = (next_track+1)%TRACK_LIMIT
	track_count = mini(track_count+1,TRACK_LIMIT)
	tracks.multimesh.visible_instance_count = track_count

func _process(_delta: float) -> void:
	var fraction := Engine.get_physics_interpolation_fraction()
	for i in range(4):
		if grounded[i]:
			for emitter: GPUParticles3D in emitters[i]:
				emitter.global_position = contact_before[i].lerp(contact_now[i],fraction)+car.wheels[i].get_contact_normal()*0.05
	track_material.set_shader_parameter("trail_time",clock)
	track_material.set_shader_parameter("trail_origin",car.global_position)
	tracks.multimesh.custom_aabb = AABB(car.global_position-Vector3(130,20,130),Vector3(260,40,260))
