extends Node3D

const CHUNK_SIZE := 64
const STEP := 2
const COLLISION_RADIUS := 2
const TREE_SPACING := 3.2
const AMERICAN_SETBACK := 30.0
const RADIUS := 4 # Outer edges stay beyond the driving camera's far plane.
const WINTER := {"snow": Color("c5d1e0"), "road": Color("909eae"), "density": 0.78, "pine_share": 0.64, "rock_density": 0.65, "snowbank": 0.38}

var world_seed := 452
var follow: Node3D
var chunks: Dictionary = {}
var pending: Array[Vector2i] = []
var curves: Dictionary = {}
var focus := Vector2i(2147483647,2147483647)
var broad: FastNoiseLite
var hills: FastNoiseLite
var detail: FastNoiseLite
var forest: FastNoiseLite
var bends: FastNoiseLite
var rises: FastNoiseLite
var cover: FastNoiseLite
var meshes: Array[ArrayMesh] = []
var snow_material: StandardMaterial3D
var ground_material: ShaderMaterial
var road_origin := Vector3.ZERO
var progression: Dictionary = {}
var route_lengths: Array[float] = [0.0]
var trunk_shape: CapsuleShape3D
var rock_shape: BoxShape3D

func noise_layer(salt: int, frequency: float) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = world_seed+salt
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_NONE
	return noise

func setup(value: int) -> void:
	world_seed = value
	broad = noise_layer(11,0.002)
	hills = noise_layer(23,0.012)
	detail = noise_layer(37,0.16)
	forest = noise_layer(53,0.018)
	bends = noise_layer(71,0.0015)
	rises = noise_layer(89,0.002)
	cover = noise_layer(107,0.025)
	road_origin = road_knot(0)
	snow_material = StandardMaterial3D.new()
	snow_material.vertex_color_use_as_albedo = true
	snow_material.roughness = 0.92
	ground_material = ShaderMaterial.new()
	ground_material.shader = preload("res://materials/ground.gdshader")
	trunk_shape = CapsuleShape3D.new()
	trunk_shape.radius = 0.24
	trunk_shape.height = 5.0
	rock_shape = BoxShape3D.new()
	rock_shape.size = Vector3(1.5,1.0,1.5)
	make_prototypes()

# Cache cumulative route lengths, independently of streaming or driving history.
func road_distance(z: float) -> float:
	var station := floori(absf(z)/CHUNK_SIZE)
	# Biome progression follows the original driving direction (-Z).
	if z>0: return 0.0
	while route_lengths.size()<=station:
		var i := route_lengths.size()
		route_lengths.append(route_lengths[-1]+road_knot(-i*CHUNK_SIZE).distance_to(road_knot(-(i-1)*CHUNK_SIZE)))
	return route_lengths[station]+road_knot(z).distance_to(road_knot(-station*CHUNK_SIZE))

func autumn_at(z: float) -> float:
	# Preserve the home village before the kilometre-long transition.
	if z>=0: return 0.0
	var metre := floori(z)
	for sample_z in [metre,metre+1]:
		if not progression.has(sample_z): progression[sample_z] = smoothstep(700.0,1700.0,road_distance(sample_z))
	return lerpf(progression[metre],progression[metre+1],z-metre)

func biome_at(_x: float, z: float) -> Dictionary:
	var t := autumn_at(z)
	return {"snow": WINTER.snow.lerp(Color("665b35"),t), "road": WINTER.road.lerp(Color("30383d"),t), "density": lerpf(0.78,0.94,t), "pine_share": lerpf(0.64,0.10,t), "rock_density": lerpf(0.65,0.25,t), "snowbank": 0.38*(1-t)}

func road_knot(z: float) -> Vector3:
	return Vector3(90*bends.get_noise_2d(z,17)+18*bends.get_noise_2d(z*2.6,831),6*rises.get_noise_2d(z,29)+0.8*rises.get_noise_2d(z*3,701),z)

func road_point(z: float) -> Vector3:
	var row := floori(z/CHUNK_SIZE)
	if not curves.has(row):
		var curve := Curve3D.new()
		for zz in [float(row*CHUNK_SIZE),float((row+1)*CHUNK_SIZE)]:
			var point := road_knot(zz)-road_origin
			point.z = zz
			var tangent := (road_knot(zz+1)-road_knot(zz-1))*CHUNK_SIZE/6.0
			curve.add_point(point,-tangent,tangent)
		curves[row] = curve
	return (curves[row] as Curve3D).sample(0,(z-row*CHUNK_SIZE)/CHUNK_SIZE)

# A world-coordinate field, shared by rendering and each tire contact.
func surface_at(point: Vector3) -> Vector2:
	var distance := absf(point.x-road_point(point.z).x)
	var road := 1-smoothstep(3.4,5.5,distance)
	var start := smoothstep(25,50,absf(point.z))
	var ice := smoothstep(0.27,0.43,cover.get_noise_2d(point.x*1.4,point.z*0.65))*road*start
	var drift := smoothstep(0.30,0.52,cover.get_noise_2d(point.x*0.5+413,point.z*0.55-271))*start
	# Ploughed lanes accumulate less powder than the untouched shoulders.
	var depth := maxf((1-road)*0.95,drift*road*0.65)*(1-ice)
	return Vector2(ice,depth)*(1-autumn_at(point.z))

# Keep the tire force model; blend only its surface coefficient.
func grip_at(point: Vector3, winter_grip: float) -> float:
	var shoulder := smoothstep(3.4,5.5,absf(point.x-road_point(point.z).x))
	return lerpf(winter_grip,lerpf(0.82,0.60,shoulder),autumn_at(point.z))

func icy_road(z: float) -> bool:
	return surface_at(road_point(z)).x>0.5

func height_at(x: float, z: float) -> float:
	var road := road_point(z)
	var distance := absf(x-road.x)
	var small := detail.get_noise_2d(x,z)
	var ground := (12+14*autumn_at(z))*broad.get_noise_2d(x,z)+2.5*hills.get_noise_2d(x,z)+small*0.13-road_origin.y
	var bank := float(biome_at(x,z).snowbank)*exp(-pow((distance-5.3)/1.1,2))
	var bed := road.y-0.035*smoothstep(0,3.4,distance)+small*0.014+bank
	return lerpf(bed,ground,smoothstep(7,24,distance))+surface_at(Vector3(x,0,z)).y*0.20

func cell_at(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x/CHUNK_SIZE),floori(position.z/CHUNK_SIZE))

func stream_at(position: Vector3, immediate := false) -> void:
	var cell := cell_at(position)
	if cell!=focus:
		focus = cell
		pending.clear()
		for z in range(cell.y-RADIUS,cell.y+RADIUS+1):
			for x in range(cell.x-RADIUS,cell.x+RADIUS+1):
				var key := Vector2i(x,z)
				if not chunks.has(key): pending.append(key)
		pending.sort_custom(func(a: Vector2i,b: Vector2i): return a.distance_squared_to(cell)<b.distance_squared_to(cell))
		# One chunk of hysteresis prevents rebuilding when hovering at a border.
		for key: Vector2i in chunks.keys():
			if maxi(absi(key.x-cell.x),absi(key.y-cell.y))>RADIUS+1:
				chunks[key].queue_free()
				chunks.erase(key)
		for key: Vector2i in chunks: update_obstacle_collision(chunks[key],key)
		for row: int in curves.keys():
			if absi(row-cell.y)>RADIUS+3: curves.erase(row)
	if immediate:
		while not pending.is_empty(): build_chunk(pending.pop_front())

func _process(_delta: float) -> void:
	if not is_instance_valid(follow): return
	stream_at(follow.global_position)
	if not pending.is_empty(): build_chunk(pending.pop_front())

func build_chunk(key: Vector2i) -> void:
	var chunk := Node3D.new()
	chunk.name = "Chunk_%d_%d"%[key.x,key.y]
	chunk.position = Vector3(key.x*CHUNK_SIZE,0,key.y*CHUNK_SIZE)
	chunk.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(chunk)
	chunks[key] = chunk
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var side := CHUNK_SIZE/STEP+1
	for iz in range(side):
		var z := float(key.y*CHUNK_SIZE+iz*STEP)
		for ix in range(side):
			var x := float(key.x*CHUNK_SIZE+ix*STEP)
			# Sample both sides of boundaries, rather than averaging per-chunk normals.
			var normal := Vector3(height_at(x-0.5,z)-height_at(x+0.5,z),1,height_at(x,z-0.5)-height_at(x,z+0.5)).normalized()
			var biome := biome_at(x,z)
			var color: Color = biome.snow
			color *= 0.97+0.05*detail.get_noise_2d(x,z)
			var surface := surface_at(Vector3(x,0,z))
			color = color.lerp(Color("a4bfd1"),surface.x*0.65)
			color.a = surface.x
			st.set_color(color)
			st.set_normal(normal)
			st.add_vertex(Vector3(ix*STEP,height_at(x,z),iz*STEP))
	for iz in range(side-1):
		for ix in range(side-1):
			var a := iz*side+ix
			for index in [a,a+1,a+side+1,a,a+side+1,a+side]: st.add_index(index)
	var terrain := MeshInstance3D.new()
	terrain.name = "Terrain"
	terrain.mesh = st.commit()
	terrain.material_override = ground_material
	chunk.add_child(terrain)
	terrain.create_trimesh_collision()
	# The ribbon is visual only. The continuous terrain provides the sole collision.
	var middle := road_point((key.y+0.5)*CHUNK_SIZE)
	if floori(middle.x/CHUNK_SIZE)==key.x: make_road(chunk,key.y)
	make_forest(chunk,key)
	make_roadside(chunk,key)
	update_obstacle_collision(chunk,key)

func make_road(chunk: Node3D, row: int) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var offsets := [-3.8,-3.4,-3.0,-2.5,-2.0,-1.5,-1.15,-0.65,-0.12,0.0,0.12,0.65,1.15,1.5,2.0,2.5,3.0,3.4,3.8]
	for iz in range(CHUNK_SIZE+1):
		var z := float(row*CHUNK_SIZE+iz)
		var center := road_point(z)
		var tangent := road_point(z+0.1)-road_point(z-0.1)
		var right := Vector3(tangent.z,0,-tangent.x).normalized()
		for offset: float in offsets:
			var p := center+right*offset
			# Match the collision's actual triangles, including at tile boundaries.
			p.y = collision_height(p.x,p.z)+0.002
			var biome := biome_at(p.x,p.z)
			var color: Color = biome.road
			if absf(offset)>3.4: color = biome.snow
			elif absf(absf(offset)-0.9)<0.3: color = color.darkened(0.10)
			if absf(offset)<=0.12:
				color = color.lerp(Color("b5a05b"),autumn_at(z)*0.8)
			var surface := surface_at(p)
			color = color.lerp(biome.snow,surface.y)
			color = color.lerp(Color("9dbed3"),surface.x*0.85)
			color *= 0.97+0.04*detail.get_noise_2d(p.x,p.z)
			color.a = maxf(surface.x,autumn_at(z)*0.48*smoothstep(-0.4,0.4,forest.get_noise_2d(p.x,p.z)))
			st.set_color(color)
			st.set_normal(Vector3.UP)
			st.add_vertex(p-chunk.position)
	for iz in range(CHUNK_SIZE):
		for ix in range(offsets.size()-1):
			var a := iz*offsets.size()+ix
			for index in [a,a+1,a+offsets.size()+1,a,a+offsets.size()+1,a+offsets.size()]: st.add_index(index)
	var road := MeshInstance3D.new()
	road.name = "Road"
	road.mesh = st.commit()
	road.material_override = ground_material
	chunk.add_child(road)

# Same diagonal as the terrain mesh. Used by the road ribbon and object roots.
func collision_height(x: float, z: float) -> float:
	var x0 := floorf(x/STEP)*STEP
	var z0 := floorf(z/STEP)*STEP
	var u := (x-x0)/STEP
	var v := (z-z0)/STEP
	var a := height_at(x0,z0)
	var d := height_at(x0+STEP,z0+STEP)
	if u>v: return a*(1-u)+height_at(x0+STEP,z0)*(u-v)+d*v
	return a*(1-v)+height_at(x0,z0+STEP)*(v-u)+d*u

# Candidate positions and priority depend only on global lattice cells. The halo
# makes thinning identical on chunk edges and after unloading/regeneration.
func tree_site(cell: Vector2i) -> Vector3:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d/tree/%d/%d"%[world_seed,cell.x,cell.y])
	return Vector3((cell.x+rng.randf_range(0.08,0.92))*4,rng.randf(),(cell.y+rng.randf_range(0.08,0.92))*4)

func building_clearance(x: float, z: float, margin: float) -> bool:
	# Include roofs, yards and fences, even when the owner is in another chunk.
	for index in range(10):
		var station := -440.0-index*10
		if absf(z-station)>7+margin: continue
		var cx := road_point(station).x+(-15 if index%2==0 else 16)
		if absf(x-cx)<8+margin: return false
	for index in range(floori((z-9-margin)/36),ceili((z+9+margin)/36)+1):
		var station := float(index*36)
		if autumn_at(station)<0.45 or posmod(index,17)>4: continue
		var cx := road_point(station).x+(-AMERICAN_SETBACK if index%2==0 else AMERICAN_SETBACK)
		if absf(x-cx)<8+margin and z>station-6-margin and z<station+4+margin: return false
	var pole_z := roundf(z/40)*40
	if absf(z-pole_z)<1+margin and absf(x-road_point(pole_z).x-8)<1+margin: return false
	return not (absf(z+160)<3+margin and absf(x-road_point(-160).x-9)<3+margin)

func make_forest(chunk: Node3D, key: Vector2i) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d/%d/%d"%[world_seed,key.x,key.y])
	var transforms: Array = [[],[],[],[],[],[],[],[],[]]
	var sites: Dictionary = {}
	for iz in range(-1,17):
		for ix in range(-1,17):
			var cell := key*16+Vector2i(ix,iz)
			sites[cell] = tree_site(cell)
	for iz in range(16):
		for ix in range(16):
			var cell := key*16+Vector2i(ix,iz)
			var site: Vector3 = sites[cell]
			var x := site.x
			var z := site.z
			if absf(x-road_point(z).x)<9 or not building_clearance(x,z,3.2): continue
			var crowded := false
			for dz in range(-1,2):
				for dx in range(-1,2):
					if dx==0 and dz==0: continue
					var other: Vector3 = sites[cell+Vector2i(dx,dz)]
					var wins := other.y>site.y or (other.y==site.y and (dz>0 or (dz==0 and dx>0)))
					if wins and Vector2(x-other.x,z-other.z).length()<TREE_SPACING: crowded = true
			if crowded: continue
			var biome := biome_at(x,z)
			var density := smoothstep(-0.40,0.35,forest.get_noise_2d(x,z))*float(biome.density)
			if rng.randf()>density: continue
			if absf(height_at(x+1,z)-height_at(x-1,z))>1: continue
			var kind := 0 if rng.randf()<float(biome.pine_share)+0.18*forest.get_noise_2d(x+143,z) else 1
			if rng.randf()<autumn_at(z): kind = rng.randi_range(3,6)
			var scale_y := rng.randf_range(0.75,1.55)
			var basis := Basis(Vector3.UP,rng.randf()*TAU).scaled(Vector3(rng.randf_range(0.8,1.2),scale_y,rng.randf_range(0.8,1.2)))
			transforms[kind].append(Transform3D(basis,Vector3(x,collision_height(x,z)-0.08,z)-chunk.position))
	# Widely spaced rock candidates; reserve space around every potential trunk.
	for i in range(12):
		var x := key.x*CHUNK_SIZE+(i%4+rng.randf_range(0.2,0.8))*16
		var z := key.y*CHUNK_SIZE+(i/4+rng.randf_range(0.2,0.8))*CHUNK_SIZE/3.0
		if absf(x-road_point(z).x)<8 or not building_clearance(x,z,1.2): continue
		var crowded := false
		var cell := Vector2i(floori(x/4),floori(z/4))
		for dz in range(-1,2):
			for dx in range(-1,2):
				var tree := tree_site(cell+Vector2i(dx,dz))
				if Vector2(x-tree.x,z-tree.z).length()<2.2: crowded = true
		if crowded: continue
		var exposed := smoothstep(-0.45,0.4,hills.get_noise_2d(x,z))
		if rng.randf()>float(biome_at(x,z).rock_density)*exposed: continue
		var size := rng.randf_range(0.35,1.1)
		var kind := 7 if rng.randf()<autumn_at(z) else 2
		transforms[kind].append(Transform3D(Basis(Vector3.UP,rng.randf()*TAU).scaled(Vector3(size,size*0.65,size)),Vector3(x,collision_height(x,z),z)-chunk.position))
	for i in range(64):
		var x := key.x*CHUNK_SIZE+(i%8+rng.randf())*8
		var z := key.y*CHUNK_SIZE+(i/8+rng.randf())*8
		if rng.randf()>autumn_at(z)*0.65 or absf(x-road_point(z).x)<4.3 or not building_clearance(x,z,0.3): continue
		var normal := Vector3(height_at(x-0.5,z)-height_at(x+0.5,z),1,height_at(x,z-0.5)-height_at(x,z+0.5)).normalized()
		var basis := Basis(Quaternion(Vector3.UP,normal))*Basis(Vector3.UP,rng.randf()*TAU)
		transforms[8].append(Transform3D(basis,Vector3(x,collision_height(x,z)+0.025,z)-chunk.position))
	chunk.set_meta("forest_transforms",transforms)
	for kind in range(meshes.size()):
		if transforms[kind].is_empty(): continue
		var batch := MultiMeshInstance3D.new()
		batch.name = ["Pines","Birches","Rocks","Oak","Maple","Beech","AutumnPine","AutumnRocks","Leaves"][kind]
		batch.multimesh = MultiMesh.new()
		batch.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		batch.multimesh.mesh = meshes[kind]
		batch.multimesh.instance_count = transforms[kind].size()
		for i in range(transforms[kind].size()): batch.multimesh.set_instance_transform(i,transforms[kind][i])
		chunk.add_child(batch)

# A few bodies per nearby chunk, with shared primitive shapes. Far chunks retain
# only placement data and MultiMeshes; physics bodies are created on approach.
func collision_part(body: StaticBody3D, shape: Shape3D, transform: Transform3D) -> void:
	var part := CollisionShape3D.new()
	part.shape = shape
	part.transform = transform
	body.add_child(part)

func building_collision(chunk: Node3D, center: Vector3, size: Vector3) -> void:
	var records: Array = chunk.get_meta("buildings",[])
	var shape := BoxShape3D.new()
	shape.size = size
	records.append([shape,Transform3D(Basis.IDENTITY,center-chunk.position)])
	chunk.set_meta("buildings",records)

func update_obstacle_collision(chunk: Node3D, key: Vector2i) -> void:
	var existing := chunk.get_node_or_null("Obstacles")
	if maxi(absi(key.x-focus.x),absi(key.y-focus.y))>COLLISION_RADIUS:
		if existing:
			for body: StaticBody3D in existing.get_children(): body.collision_layer = 0
			chunk.remove_child(existing)
			existing.queue_free()
		return
	if existing: return
	var obstacles := Node3D.new()
	obstacles.name = "Obstacles"
	chunk.add_child(obstacles)
	for kind in ["Trees","Rocks","Buildings"]:
		var body := StaticBody3D.new()
		body.name = kind
		body.set_meta("obstacle_type",kind)
		obstacles.add_child(body)
	var transforms: Array = chunk.get_meta("forest_transforms")
	for kind in range(8):
		for transform: Transform3D in transforms[kind]:
			if kind==2 or kind==7:
				var size := transform.basis.get_scale().x
				collision_part(obstacles.get_node("Rocks"),rock_shape,Transform3D(Basis.IDENTITY.scaled(Vector3.ONE*size),transform.origin+Vector3.UP*0.4*size))
			else:
				collision_part(obstacles.get_node("Trees"),trunk_shape,Transform3D(Basis.IDENTITY,transform.origin+Vector3.UP*2.5))
	for record: Array in chunk.get_meta("buildings",[]):
		collision_part(obstacles.get_node("Buildings"),record[0],record[1])

func append_part(st: SurfaceTool, mesh: Mesh, transform: Transform3D, color: Color) -> void:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for i in indices:
		st.set_color(color)
		st.set_normal((transform.basis*normals[i]).normalized())
		st.add_vertex(transform*vertices[i])

func branch(st: SurfaceTool, a: Vector3, b: Vector3, radius: float, color: Color) -> void:
	var shape := CylinderMesh.new()
	shape.top_radius = radius*0.45
	shape.bottom_radius = radius
	shape.height = a.distance_to(b)
	shape.radial_segments = 5
	shape.rings = 1
	append_part(st,shape,Transform3D(Basis(Quaternion(Vector3.UP,(b-a).normalized())),(a+b)*0.5),color)

func make_prototypes() -> void:
	for kind in range(9):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		if kind==0:
			branch(st,Vector3.ZERO,Vector3(0,8,0),0.16,Color("625d57"))
			for layer in range(5):
				var cone := CylinderMesh.new()
				cone.top_radius = 0
				cone.bottom_radius = 2.2-layer*0.34
				cone.height = 2.8-layer*0.15
				cone.radial_segments = 9
				cone.rings = 1
				var pos := Vector3(0,2.5+layer*1.15,0)
				append_part(st,cone,Transform3D(Basis.IDENTITY,pos),Color("495e5e"))
				cone.bottom_radius *= 0.96
				cone.height *= 0.77
				append_part(st,cone,Transform3D(Basis.IDENTITY,pos+Vector3.UP*0.34),Color("c0cfdc"))
		elif kind==1:
			branch(st,Vector3.ZERO,Vector3(0.25,8,0),0.15,Color("d6dbdb"))
			for i in range(12):
				var patch := BoxMesh.new()
				patch.size = Vector3(0.27,0.055+(i%3)*0.02,0.27)
				append_part(st,patch,Transform3D(Basis(Vector3.UP,i*2.1),Vector3(i*0.018,i*0.58+0.4,0)),Color("48515c"))
			for i in range(10):
				var angle := i*2.4
				var a := Vector3(0.15,3.2+i*0.37,0)
				var b := a+Vector3(cos(angle)*(2.3-i*0.12),1.2,sin(angle)*(2.3-i*0.12))
				branch(st,a,b,0.055,Color("c2ccd5"))
				branch(st,b,(b-a)*1.3+a+Vector3.UP*0.65,0.025,Color("737e8c"))
		elif kind==8:
			for i in range(12):
				var leaf := BoxMesh.new()
				leaf.size = Vector3(0.15,0.008,0.25)
				var p := Vector3(cos(i*2.4)*(i%4)*0.35,0,sin(i*2.4)*(i%4)*0.35)
				append_part(st,leaf,Transform3D(Basis(Vector3.UP,i*1.7),p),[Color("9e6231"),Color("b58537"),Color("783c29")][i%3])
		elif kind>=3 and kind<=6:
			branch(st,Vector3.ZERO,Vector3(0,7,0),0.22,Color("645747"))
			var colors := [Color("956135"),Color("b94729"),Color("c2a046"),Color("354c39")]
			for i in range(7):
				var crown := SphereMesh.new()
				crown.radius = 1.7 if kind!=6 else 1.1
				crown.height = 3.5
				crown.radial_segments = 7
				crown.rings = 3
				var tip := Vector3(cos(i*2.4)*1.3,5.0+(i%3)*1.0,sin(i*2.4)*1.3)
				branch(st,Vector3(0,3,0),tip,0.07,Color("645747"))
				append_part(st,crown,Transform3D(Basis.IDENTITY,tip),colors[kind-3].lightened((i%3)*0.045))
		else:
			var rock := SphereMesh.new()
			rock.radius = 1
			rock.height = 1.6
			rock.radial_segments = 7
			rock.rings = 3
			append_part(st,rock,Transform3D(Basis.IDENTITY,Vector3(0,0.2,0)),Color("77818d"))
			if kind==2:
				rock.radius = 0.92
				rock.height = 0.9
				append_part(st,rock,Transform3D(Basis.IDENTITY,Vector3(0,0.65,0)),Color("c5d1de"))
		st.index()
		var mesh := st.commit()
		mesh.surface_set_material(0,snow_material)
		meshes.append(mesh)

# Keep the original village, bus stop and power line as streamed roadside scenery.
func box(parent: Node3D, pos: Vector3, size: Vector3, color: Color, glow := false) -> MeshInstance3D:
	return get_parent().box(parent,pos,size,color,glow)

func make_roadside(chunk: Node3D, key: Vector2i) -> void:
	make_american_roadside(chunk,key)
	for index in range(10):
		var z := -440.0-index*10
		var x := road_point(z).x+(-15 if index%2==0 else 16)
		if cell_at(Vector3(x,0,z))!=key: continue
		var house := preload("res://scenes/house.tscn").instantiate() as Node3D
		add_child(house)
		house.reparent(chunk)
		house.position = Vector3(x,height_at(x,z),z)-chunk.position
		building_collision(chunk,chunk.position+house.position+Vector3(0,1.6,0),Vector3(7,3.2,5))
		box(house,Vector3(0,-0.25,0),Vector3(7,0.7,5),Color("5d5855"))
		for j in range(12): box(house,Vector3(-7+j*1.2,0.65,6),Vector3(0.17,1.3,0.16),Color("625e5a"))
		box(house,Vector3(0,0.8,6),Vector3(15,0.15,0.15),Color("625e5a"))
		building_collision(chunk,chunk.position+house.position+Vector3(0,0.65,6),Vector3(15,1.3,0.18))
	var start := ceili(key.y*CHUNK_SIZE/40.0)
	var end := ceili((key.y+1)*CHUNK_SIZE/40.0)
	for i in range(start,end):
		var z := float(i*40)
		var a := road_point(z)+Vector3(8,0,0)
		if cell_at(a)!=key: continue
		a.y = height_at(a.x,a.z)
		building_collision(chunk,a+Vector3(0,4,0),Vector3(0.22,8,0.22))
		box(chunk,a-chunk.position+Vector3(0,4,0),Vector3(0.22,8,0.22),Color("5a5757"))
		box(chunk,a-chunk.position+Vector3(0,7.5,0),Vector3(2,0.16,0.2),Color("5a5757"))
		var b := road_point(z+40)+Vector3(8,0,0)
		b.y = height_at(b.x,b.z)
		for wire_offset in [-0.7,0.7]:
			var p := a+Vector3(wire_offset,7.6,0)
			var q := b+Vector3(wire_offset,7.6,0)
			var mid := (p+q)*0.5-Vector3.UP*0.55
			for pair in [[p,mid],[mid,q]]:
				var wire := box(chunk,(pair[0]+pair[1])*0.5-chunk.position,Vector3(0.025,0.025,pair[0].distance_to(pair[1])),Color("3d4654"))
				wire.look_at(pair[1])
	var stop := road_point(-160)+Vector3(9,0,0)
	if cell_at(stop)==key:
		stop.y = height_at(stop.x,stop.z)
		building_collision(chunk,stop+Vector3(0,1.4,0),Vector3(4,2.8,0.2))
		building_collision(chunk,stop+Vector3(0,2.9,1),Vector3(4.5,0.25,2.6))
		box(chunk,stop-chunk.position+Vector3(0,1.4,0),Vector3(4,2.8,0.2),Color("667f83"))
		box(chunk,stop-chunk.position+Vector3(0,2.9,1),Vector3(4.5,0.25,2.6),Color("c6d1dd"))
		box(chunk,stop-chunk.position+Vector3(0,0.6,1),Vector3(3.5,0.2,0.6),Color("645447"))

func make_american_roadside(chunk: Node3D, key: Vector2i) -> void:
	for index in range(floori(key.y*64.0/36),ceili((key.y+1)*64.0/36)):
		var z := float(index*36)
		if autumn_at(z)<0.45: continue
		var side := -1.0 if index%2==0 else 1.0
		var x := road_point(z).x+side*AMERICAN_SETBACK
		if cell_at(Vector3(x,0,z))!=key: continue
		if posmod(index,17)>4: continue
		# Houses sit beyond the road cutting, on reasonably gentle building sites.
		var level := height_at(x,z)
		var steep := false
		for corner in [Vector2(-4,-3),Vector2(4,-3),Vector2(-4,3),Vector2(4,3)]:
			if absf(height_at(x+corner.x,z+corner.y)-level)>0.8: steep = true
		if steep: continue
		var root := Node3D.new()
		chunk.add_child(root)
		root.position = Vector3(x,collision_height(x,z),z)-chunk.position
		building_collision(chunk,chunk.position+root.position+Vector3(0,1.8,0),Vector3(8,3.6,6))
		var barn := posmod(index,4)==0
		var wall := Color("923d32") if barn else (Color("876358") if posmod(index,7)==0 else Color("b6ada0"))
		box(root,Vector3(0,1.8,0),Vector3(8,3.6,6),wall)
		for side_roof in [-1,1]:
			var roof := box(root,Vector3(side_roof*2.1,4.1,0),Vector3(4.7,0.22,7),Color("454b4a"))
			roof.rotation.z = side_roof*-0.38
		for wx in [-2.5,2.5]:
			box(root,Vector3(wx,2,3.04),Vector3(1.1,1.3,0.12),Color("d2cec0"))
			box(root,Vector3(wx,2,3.12),Vector3(0.85,1.05,0.06),Color("536575"))
		box(root,Vector3(0,1.2,3.1),Vector3(1.4,2.4,0.15),Color("564c41"))
		var mailbox := Vector3(road_point(z).x+side*5.6,0,z+5)
		mailbox.y = collision_height(mailbox.x,mailbox.z)
		box(chunk,mailbox-chunk.position+Vector3(0,0.6,0),Vector3(0.12,1.2,0.12),Color("76634c"))
		box(chunk,mailbox-chunk.position+Vector3(0,1.25,0),Vector3(0.36,0.35,0.65),Color("515859"))
		building_collision(chunk,chunk.position+root.position+Vector3(0,0.65,-5),Vector3(14,1.3,0.18))
		for rail in [0.6,1.1]:
			box(root,Vector3(0,rail,-5),Vector3(14,0.12,0.12),Color("827057"))
		for post in range(-7,8,2):
			box(root,Vector3(post,0.65,-5),Vector3(0.15,1.3,0.15),Color("827057"))
