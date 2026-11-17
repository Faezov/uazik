extends SceneTree
# godot --headless --path . --fixed-fps 60 --script tests/headless_drive.gd -- 452
# Add --niva for the Niva, or use --environment for regeneration/impact checks.
# The long drive uses only drive() inputs after the normal initial spawn.

var world: Node3D
var seed_value := 452
var ticks := 0
var distance := 0.0
var previous := Vector3.ZERO
var max_offset := 0.0
var collision_events := 0
var terrain_contacts := 0
var blocked: Array = []
var loaded_max := 0
var memory_max := 0.0
var chunks_seen: Dictionary = {}
var overlaps := 0
var close_buildings := 0
var minimum_spacing := INF
var tree_cells: Dictionary = {}
var road_obstructions := 0
var last_progress := 0.0
var stuck_ticks := 0
var started := 0
var last_km := -1
var braking_ticks := 0
var max_roll := 0.0
var max_pitch := 0.0
var snow_in_autumn := 0
var surface_errors := 0
var missing_chunks := 0
var road_checked: Dictionary = {}
var road_probe := BoxShape3D.new()
var testing_environment := false

var fixture: Node3D
var landscape: Node3D
var car: VehicleBody3D
var checks := 0
var failures: Array = []
var impacts: Array = []
var hit_kind := ""

func _initialize() -> void:
	if "--environment" in OS.get_cmdline_user_args():
		testing_environment = true
		call_deferred("run_environment")
		return
	if not OS.get_cmdline_user_args().is_empty(): seed_value = int(OS.get_cmdline_user_args()[0])
	road_probe.size = Vector3(6,1.2,1)
	world = load("res://scenes/main.tscn").instantiate()
	world.world_seed = seed_value
	root.add_child.call_deferred(world)
	setup.call_deferred()

func setup() -> void:
	world.set_physics_process(false)
	if "--niva" in OS.get_cmdline_user_args(): world.switch_vehicle()
	world.car.select_drive_mode("4H")
	world.car.contact_monitor = true
	world.car.max_contacts_reported = 16
	world.car.body_entered.connect(on_collision)
	previous = world.car.global_position
	started = Time.get_ticks_msec()

func on_collision(body: Node) -> void:
	if body.get_parent() is MeshInstance3D and body.get_parent().name == "Terrain":
		terrain_contacts += 1
	else:
		collision_events += 1
		print("OBSTACLE_CONTACT seed=",seed_value," z=",world.car.position.z," body=",body.get_path())

func audit_chunks() -> void:
	for key: Vector2i in world.landscape.chunks:
		if chunks_seen.has(key): continue
		chunks_seen[key] = true
		var chunk: Node3D = world.landscape.chunks[key]
		for kind in range(7):
			if kind!=2:
				for transform: Transform3D in chunk.get_meta("forest_transforms")[kind]:
					var p: Vector3 = chunk.position+transform.origin
					var cell := Vector2i(floori(p.x/4),floori(p.z/4))
					for dz in range(-1,2):
						for dx in range(-1,2):
							for other: Vector3 in tree_cells.get(cell+Vector2i(dx,dz),[]):
								var spacing := Vector2(p.x-other.x,p.z-other.z).length()
								minimum_spacing = minf(minimum_spacing,spacing)
								if spacing<2.4: overlaps += 1
					if not tree_cells.has(cell): tree_cells[cell] = []
					tree_cells[cell].append(p)
					if absf(p.x-world.route(p.z))<5: road_obstructions += 1
					# Both settlements have roadside building centres at known world stations.
					for station in range(floori((p.z-12)/36),ceili((p.z+12)/36)+1):
						var z := station*36.0
						if world.landscape.autumn_at(z)<0.45 or posmod(station,17)>4: continue
						var x: float = world.route(z)+(-world.landscape.AMERICAN_SETBACK if station%2==0 else world.landscape.AMERICAN_SETBACK)
						if absf(p.x-x)<5.5 and absf(p.z-z)<4.5: close_buildings += 1
		loaded_max = maxi(loaded_max,world.landscape.chunks.size())

func audit_road() -> void:
	var car: VehicleBody3D = world.car
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = road_probe
	query.exclude = [car.get_rid()]
	for ahead in range(0,64,4):
		var station := floori((car.position.z-ahead)/4)*4
		if road_checked.has(station): continue
		road_checked[station] = true
		var point: Vector3 = world.landscape.road_point(station)
		point.y = world.surface_height(point.x,point.z)+1.0
		query.transform = Transform3D(Basis.IDENTITY,point)
		for contact: Dictionary in car.get_world_3d().direct_space_state.intersect_shape(query):
			if contact.collider.has_meta("obstacle_type"): road_obstructions += 1
	if not world.landscape.chunks.has(world.landscape.cell_at(car.position)): missing_chunks += 1
	# Allow the render callback to consume the last physics pose at the boundary.
	if world.landscape.autumn_at(car.position.z+2)>=1:
		var snow: CPUParticles3D = car.get_node("Snow")
		if snow.emitting or snow.visible: snow_in_autumn += 1
		for streams: Array in world.get_node("WheelEffects").emitters:
			if streams[0].emitting or streams[0].visible: snow_in_autumn += 1
		for wheel: VehicleWheel3D in car.wheels:
			if wheel.is_in_contact() and world.landscape.surface_at(wheel.get_contact_point())!=Vector2.ZERO: surface_errors += 1

func report(ok: bool) -> void:
	ok = ok and collision_events==0 and terrain_contacts==0 and road_obstructions==0 and overlaps==0 and close_buildings==0 and minimum_spacing>=3.2 and snow_in_autumn==0 and surface_errors==0 and missing_chunks==0
	var result := {"pass":ok,"vehicle":"Niva" if world.using_niva else "UAZ","seed":seed_value,"distance_m":distance,"road_progress_m":world.landscape.road_distance(world.car.position.z),"final_z":world.car.position.z,"physics_ticks":ticks,"wall_s":(Time.get_ticks_msec()-started)/1000.0,"obstacle_collision_events":collision_events,"chassis_terrain_contacts":terrain_contacts,"blocked_sections":blocked,"max_road_offset_m":max_offset,"tree_pairs_under_2_4m":overlaps,"trees_in_building_clearance":close_buildings,"min_tree_spacing_m":minimum_spacing,"road_obstructions":road_obstructions,"chunks_visited":chunks_seen.size(),"max_loaded_chunks":loaded_max,"peak_static_mb":memory_max,"braking_ticks":braking_ticks,"max_roll_degrees":rad_to_deg(max_roll),"max_pitch_degrees":rad_to_deg(max_pitch),"snow_effect_samples_in_autumn":snow_in_autumn,"surface_errors":surface_errors,"missing_chunks":missing_chunks}
	print("DRIVE_RESULT ",JSON.stringify(result))
	var file := FileAccess.open("user://drive-%d-%s.json"%[seed_value,"niva" if world.using_niva else "uaz"],FileAccess.WRITE)
	file.store_string(JSON.stringify(result,"  "))
	quit(0 if ok else 1)

func _physics_process(dt: float) -> bool:
	if testing_environment or not is_instance_valid(world.car): return false
	ticks += 1
	var car: VehicleBody3D = world.car
	if ticks<120:
		car.drive(0,0,true,dt)
		previous = car.position
		return false
	var lookahead := 6.0+maxf(car.speed,0)*1.1
	var target := Vector3(world.route(car.position.z-lookahead),0,car.position.z-lookahead)
	var desired := atan2(-(target.x-car.position.x),-(target.z-car.position.z))
	var error := wrapf(desired-car.rotation.y,-PI,PI)
	var wheelbase: float = car.axle_positions[1]-car.axle_positions[0]
	var steer_angle := atan(2*wheelbase*sin(error)/lookahead)
	var limit := minf(car.steering_limit,maxf(0.10,atan(wheelbase*8.0/maxf(car.speed*car.speed,1))))
	var ice := 0.0
	for ahead in [0.0,10.0,25.0,40.0]:
		ice = maxf(ice,world.landscape.surface_at(world.landscape.road_point(car.position.z-ahead)).x)
	var speed_target := 3.5 if ice>0.05 else 8.0
	var brake_now: bool = car.speed>speed_target+0.6
	if brake_now: braking_ticks += 1
	car.drive(clampf(0.25+(speed_target-car.speed)*0.45,0,0.85),clampf(steer_angle/limit,-1,1),brake_now,dt)
	distance += car.position.distance_to(previous)
	previous = car.position
	var offset := absf(car.position.x-world.route(car.position.z))
	max_offset = maxf(max_offset,offset)
	max_roll = maxf(max_roll,absf(car.rotation.z))
	max_pitch = maxf(max_pitch,absf(car.rotation.x))
	if ticks%60==0:
		audit_chunks()
		audit_road()
		memory_max = maxf(memory_max,Performance.get_monitor(Performance.MEMORY_STATIC)/1048576.0)
		if car.position.z<last_progress-0.5:
			last_progress = car.position.z
			stuck_ticks = 0
		else: stuck_ticks += 60
		if car.position.y<world.surface_height(car.position.x,car.position.z)-1 or offset>5 or stuck_ticks>3600:
			blocked.append({"z":car.position.z,"offset":offset,"stuck_s":stuck_ticks/60.0})
			report(false)
			return false
	var km := floori(distance/1000)
	if km>last_km:
		last_km = km
		print("DRIVE seed=",seed_value," km=",km," z=",car.position.z," speed=",car.speed," offset=",offset," wall_s=",(Time.get_ticks_msec()-started)/1000.0)
	if distance>=5050 and world.landscape.road_distance(car.position.z)>=5000:
		report(true)
	elif ticks>160000:
		blocked.append({"z":car.position.z,"reason":"timeout"})
		report(false)
	return false

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func make_fixture(seed_value: int, z: float) -> void:
	var script := GDScript.new()
	script.source_code = 'extends "res://scripts/world.gd"\nfunc _ready(): pass\nfunc _process(_delta): pass\nfunc _physics_process(_delta): pass\n'
	script.reload()
	fixture = script.new()
	root.add_child(fixture)
	landscape = load("res://scripts/landscape.gd").new()
	fixture.add_child(landscape)
	landscape.setup(seed_value)
	landscape.stream_at(Vector3(landscape.road_point(z).x,0,z),true)

func signature(chunk: Node3D) -> int:
	var data: Array = [chunk.get_meta("forest_transforms")]
	for record: Array in chunk.get_meta("buildings",[]): data.append([record[0].size,record[1]])
	return hash(var_to_bytes(data))

func static_checks(seed_value: int) -> void:
	make_fixture(seed_value,0)
	for z in [0.0,-500.0,-1200.0,-1900.0,-5000.0]:
		landscape.stream_at(Vector3(landscape.road_point(z).x,0,z),true)
		await physics_frame
		for key: Vector2i in landscape.chunks:
			var chunk: Node3D = landscape.chunks[key]
			var near := maxi(absi(key.x-landscape.focus.x),absi(key.y-landscape.focus.y))<=2
			check(chunk.has_node("Obstacles")==near,"collider activation radius seed=%d key=%s"%[seed_value,key])
			var transforms: Array = chunk.get_meta("forest_transforms")
			for kind in range(8):
				for transform: Transform3D in transforms[kind]:
					var p: Vector3 = transform.origin+chunk.position
					var rock := kind==2 or kind==7
					check(landscape.building_clearance(p.x,p.z,1.2 if rock else 3.2),"building clearance")
					check(absf(p.x-landscape.road_point(p.z).x)>=(8 if rock else 9),"road clearance")
					if landscape.autumn_at(p.z)>=1:
						check(kind not in [0,1,2],"no snowy prototypes in America")
			if near:
				check(chunk.get_node("Obstacles/Trees").get_child_count()==transforms[0].size()+transforms[1].size()+transforms[3].size()+transforms[4].size()+transforms[5].size()+transforms[6].size(),"all trunks have collisions")
				check(chunk.get_node("Obstacles/Rocks").get_child_count()==transforms[2].size()+transforms[7].size(),"all rocks have collisions")
				check(chunk.get_node("Obstacles/Buildings").get_child_count()==chunk.get_meta("buildings",[]).size(),"all buildings have collisions")
		var key: Vector2i = landscape.focus
		var before := signature(landscape.chunks[key])
		landscape.stream_at(Vector3(landscape.road_point(z-800).x,0,z-800),true)
		await process_frame
		landscape.stream_at(Vector3(landscape.road_point(z).x,0,z),true)
		check(signature(landscape.chunks[key])==before,"deterministic regeneration seed=%d z=%f"%[seed_value,z])
		var p: Vector3 = landscape.road_point(z)
		if z<=-1900:
			check(landscape.surface_at(p)==Vector2.ZERO,"no road ice or snow")
			check(landscape.surface_at(p+Vector3(14,0,0))==Vector2.ZERO,"no offroad snow")
			check(landscape.biome_at(p.x,z).snowbank==0,"no snowbanks")
			check(is_equal_approx(landscape.grip_at(p,0.42),0.82),"asphalt traction")
			check(is_equal_approx(landscape.grip_at(p+Vector3(14,0,0),0.42),0.60),"dirt traction")
		if z==0: check(landscape.grip_at(p,0.42)==0.42,"winter traction preserved")
	fixture.free()
	await process_frame

func obstacle_contact(body: Node) -> void:
	if body.has_meta("obstacle_type"): hit_kind = body.get_meta("obstacle_type")

func probe(kind: String, niva: bool, seed_value: int) -> void:
	make_fixture(seed_value,-1900)
	var chosen := Vector3.INF
	var obstacle_depth := 0.0
	var best_cost := INF
	# Choose a gentle approach, near the road, among the actual generated shapes.
	for chunk: Node3D in landscape.chunks.values():
		var obstacles := chunk.get_node_or_null("Obstacles")
		if not obstacles: continue
		for part: CollisionShape3D in obstacles.get_node(kind).get_children():
			var p := part.global_position
			var depth: float = 0.24 if kind=="Trees" else (part.shape.size.z*part.scale.z*0.5)
			var launch_z: float = p.z+depth+7
			var slope: float = absf(landscape.collision_height(p.x,launch_z)-landscape.collision_height(p.x,p.z+depth+2))/5
			var cost := absf(p.z+1900)+slope*80+absf(p.x-landscape.road_point(p.z).x)
			if kind=="Buildings" and part.shape.size.x<4: continue
			if kind=="Buildings" and part.shape.size.y<2: continue
			if slope<0.25 and absf(p.x-landscape.road_point(p.z).x)<(140 if kind=="Rocks" else 60) and cost<best_cost:
				best_cost = cost
				chosen = p
				obstacle_depth = depth
	check(chosen.is_finite(),"found generated "+kind+" for impact probe")
	if not chosen.is_finite():
		fixture.free()
		return
	car = VehicleBody3D.new()
	car.set_script(load("res://scripts/niva.gd") if niva else load("res://scripts/vehicle.gd"))
	car.position = Vector3(chosen.x,landscape.collision_height(chosen.x,chosen.z+obstacle_depth+7)+0.85,chosen.z+obstacle_depth+7)
	car.surface_at = landscape.surface_at
	car.surface_grip = landscape.grip_at
	fixture.add_child(car)
	car.select_drive_mode("4H")
	car.contact_monitor = true
	car.max_contacts_reported = 16
	car.body_entered.connect(obstacle_contact)
	hit_kind = ""
	var start := car.position
	var hit_tick := 0
	var peak_speed := 0.0
	for tick in range(1200):
		await physics_frame
		var target := Vector3(chosen.x,0,car.position.z-4)
		var desired := atan2(-(target.x-car.position.x),-(target.z-car.position.z))
		var steering := wrapf(desired-car.rotation.y,-PI,PI)*1.5
		car.drive(clampf(0.4+(1.5-car.speed)*0.4,0,0.8) if tick>60 else 0.0,clampf(steering,-1,1),car.speed>2.5,1.0/60.0)
		peak_speed = maxf(peak_speed,car.linear_velocity.length())
		if hit_kind==kind and hit_tick==0:
			hit_tick = tick
		if hit_tick>0 and tick>hit_tick+90: break
	check(hit_kind==kind,"vehicle hits generated "+kind+" niva="+str(niva))
	check(peak_speed>0.5,"probe approaches under vehicle physics")
	check(car.position.z>chosen.z-obstacle_depth,"vehicle cannot pass through "+kind)
	check(car.linear_velocity.length()<0.8,"solid "+kind+" stops vehicle")
	impacts.append({"seed":seed_value,"vehicle":"Niva" if niva else "UAZ","obstacle":kind,"contact":hit_kind,"distance_m":start.distance_to(car.position),"peak_speed_m_s":peak_speed,"final_speed_m_s":car.linear_velocity.length(),"tick":hit_tick,"start":str(start),"target":str(chosen),"end":str(car.position)})
	print("IMPACT ",JSON.stringify(impacts[-1]))
	fixture.free()
	await process_frame

func run_environment() -> void:
	if "--impacts-only" not in OS.get_cmdline_user_args():
		for seed_value in [452,453,987]: await static_checks(seed_value)
	for niva in [false,true]:
		for kind in ["Trees","Buildings","Rocks"]: await probe(kind,niva,452)
	var report := {"checks":checks,"failures":failures,"impacts":impacts}
	var file := FileAccess.open("user://environment.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"  "))
	print("ENVIRONMENT_RESULT ",JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)
