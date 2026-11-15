extends Node3D

const CHUNK_SIZE := 64
const STEP := 2
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
	make_prototypes()

# One selection point; streaming and roads do not depend on a particular biome.
func biome_at(_x: float, _z: float) -> Dictionary:
	return WINTER

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
	return Vector2(ice,depth)

func icy_road(z: float) -> bool:
	return surface_at(road_point(z)).x>0.5

func height_at(x: float, z: float) -> float:
	var road := road_point(z)
	var distance := absf(x-road.x)
	var small := detail.get_noise_2d(x,z)
	var ground := 12*broad.get_noise_2d(x,z)+2.5*hills.get_noise_2d(x,z)+small*0.13-road_origin.y
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

func make_road(chunk: Node3D, row: int) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var offsets := [-3.8,-3.4,-3.0,-2.5,-2.0,-1.5,-1.15,-0.65,0.0,0.65,1.15,1.5,2.0,2.5,3.0,3.4,3.8]
	for iz in range(CHUNK_SIZE+1):
		var z := float(row*CHUNK_SIZE+iz)
		var center := road_point(z)
		var tangent := road_point(z+0.1)-road_point(z-0.1)
		var right := Vector3(tangent.z,0,-tangent.x).normalized()
		for offset: float in offsets:
			var p := center+right*offset
			# Match the collision's actual triangles, including at tile boundaries.
			p.y = collision_height(p.x,p.z)+0.03
			var biome := biome_at(p.x,p.z)
			var color: Color = biome.road
			if absf(offset)>3.4: color = biome.snow
			elif absf(absf(offset)-0.9)<0.3: color = color.darkened(0.10)
			var surface := surface_at(p)
			color = color.lerp(biome.snow,surface.y)
			color = color.lerp(Color("9dbed3"),surface.x*0.85)
			color *= 0.97+0.04*detail.get_noise_2d(p.x,p.z)
			color.a = surface.x
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

func make_forest(chunk: Node3D, key: Vector2i) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d/%d/%d"%[world_seed,key.x,key.y])
	var transforms: Array = [[],[],[]]
	# Jittered candidates, filtered by continuous noise, leave groves and clearings.
	for iz in range(16):
		for ix in range(16):
			var x := key.x*CHUNK_SIZE+(ix+rng.randf_range(0.08,0.92))*4
			var z := key.y*CHUNK_SIZE+(iz+rng.randf_range(0.08,0.92))*4
			var road := road_point(z)
			var distance := absf(x-road.x)
			if distance<8 or (z< -420 and z> -550 and distance<27): continue
			var biome := biome_at(x,z)
			var density := smoothstep(-0.40,0.35,forest.get_noise_2d(x,z))*float(biome.density)
			if rng.randf()>density: continue
			if absf(height_at(x+1,z)-height_at(x-1,z))>1: continue
			var kind := 0 if rng.randf()<float(biome.pine_share)+0.18*forest.get_noise_2d(x+143,z) else 1
			var scale_y := rng.randf_range(0.75,1.55)
			var basis := Basis(Vector3.UP,rng.randf()*TAU).scaled(Vector3(rng.randf_range(0.8,1.2),scale_y,rng.randf_range(0.8,1.2)))
			transforms[kind].append(Transform3D(basis,Vector3(x,collision_height(x,z)-0.08,z)-chunk.position))
	for i in range(12):
		var x := key.x*CHUNK_SIZE+rng.randf()*CHUNK_SIZE
		var z := key.y*CHUNK_SIZE+rng.randf()*CHUNK_SIZE
		if absf(x-road_point(z).x)<7: continue
		var exposed := smoothstep(-0.45,0.4,hills.get_noise_2d(x,z))
		if rng.randf()>float(biome_at(x,z).rock_density)*exposed: continue
		var size := rng.randf_range(0.35,1.1)
		transforms[2].append(Transform3D(Basis(Vector3.UP,rng.randf()*TAU).scaled(Vector3(size,size*0.65,size)),Vector3(x,collision_height(x,z),z)-chunk.position))
	for kind in range(meshes.size()):
		if transforms[kind].is_empty(): continue
		var batch := MultiMeshInstance3D.new()
		batch.name = ["Pines","Birches","Rocks"][kind]
		batch.multimesh = MultiMesh.new()
		batch.multimesh.transform_format = MultiMesh.TRANSFORM_3D
		batch.multimesh.mesh = meshes[kind]
		batch.multimesh.instance_count = transforms[kind].size()
		for i in range(transforms[kind].size()): batch.multimesh.set_instance_transform(i,transforms[kind][i])
		chunk.add_child(batch)

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
	for kind in range(3):
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
		else:
			var rock := SphereMesh.new()
			rock.radius = 1
			rock.height = 1.6
			rock.radial_segments = 7
			rock.rings = 3
			append_part(st,rock,Transform3D(Basis.IDENTITY,Vector3(0,0.2,0)),Color("77818d"))
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
	for index in range(10):
		var z := -440.0-index*10
		var x := road_point(z).x+(-15 if index%2==0 else 16)
		if cell_at(Vector3(x,0,z))!=key: continue
		var house := preload("res://scenes/house.tscn").instantiate() as Node3D
		add_child(house)
		house.reparent(chunk)
		house.position = Vector3(x,height_at(x,z),z)-chunk.position
		box(house,Vector3(0,-0.25,0),Vector3(7,0.7,5),Color("5d5855"))
		for j in range(12): box(house,Vector3(-7+j*1.2,0.65,6),Vector3(0.17,1.3,0.16),Color("625e5a"))
		box(house,Vector3(0,0.8,6),Vector3(15,0.15,0.15),Color("625e5a"))
	var start := ceili(key.y*CHUNK_SIZE/40.0)
	var end := ceili((key.y+1)*CHUNK_SIZE/40.0)
	for i in range(start,end):
		var z := float(i*40)
		var a := road_point(z)+Vector3(8,0,0)
		if cell_at(a)!=key: continue
		a.y = height_at(a.x,a.z)
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
		box(chunk,stop-chunk.position+Vector3(0,1.4,0),Vector3(4,2.8,0.2),Color("667f83"))
		box(chunk,stop-chunk.position+Vector3(0,2.9,1),Vector3(4.5,0.25,2.6),Color("c6d1dd"))
		box(chunk,stop-chunk.position+Vector3(0,0.6,1),Vector3(3.5,0.2,0.6),Color("645447"))
