extends Node3D
@export var house := false

func _ready() -> void:
	var world := get_parent()
	if house:
		world.box(self,Vector3(0,1.6,0),Vector3(7,3.2,5),Color("66564d"))
		for side in [-1,1]:
			var roof = world.box(self,Vector3(side*1.85,3.6,0),Vector3(4.3,0.25,6),Color("d4dce5"))
			roof.rotation.z = side*-0.35
		for x in [-2,2]:
			world.box(self,Vector3(x,1.7,2.52),Vector3(1.1,1.2,0.06),Color("ffc475"),true)
			world.box(self,Vector3(x,1.7,2.57),Vector3(0.06,1.25,0.08),Color("928779"))
		world.box(self,Vector3(0,1.1,2.55),Vector3(1,2.2,0.12),Color("443f3c"))
		world.box(self,Vector3(2,4.2,-1),Vector3(0.6,1.8,0.6),Color("756a65"))
	else:
		var birch := randf()<0.4
		world.box(self,Vector3(0,3,0),Vector3(0.3,6,0.3),Color("d5d8d7") if birch else Color("625d59"))
		if birch:
			for i in range(8):
				world.box(self,Vector3(0,i*0.7+0.3,0.16),Vector3(0.31,0.12,0.02),Color("515964"))
			for i in range(4):
				var branch = world.box(self,Vector3(0,4+i*0.5,0),Vector3(3-i*0.5,0.13,0.14),Color("d1d9e0"))
				branch.rotation.y = i*1.6
		else:
			for i in range(3):
				var mesh := MeshInstance3D.new()
				var cone := CylinderMesh.new()
				cone.top_radius = 0
				cone.bottom_radius = 2.2-i*0.55
				cone.height = 3
				cone.radial_segments = 7
				mesh.mesh = cone
				mesh.material_override = world.material(Color("9baeb9"))
				add_child(mesh)
				mesh.position.y = 2.5+i*1.5
