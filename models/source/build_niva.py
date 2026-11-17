"""Build the original VAZ-2121 in metres. Run with Blender --background --python.
Photo/dimension reference: FIA homologation T-1039, pp. 1–2, 11–13:
https://historicdb.fia.com/sites/default/files/car_attachment/1589598001/homologation_form_number_1039_group_t1.pdf
Godot coordinates: X right, Y up, nose -Z. Blender conversion below.
"""
import bpy, math, bmesh
from pathlib import Path
from mathutils import Vector
ROOT = Path(__file__).resolve().parents[2]
bpy.ops.object.select_all(action='SELECT'); bpy.ops.object.delete(use_global=False)
for m in list(bpy.data.materials): bpy.data.materials.remove(m)
bpy.context.preferences.filepaths.save_version = 0
scene = bpy.context.scene
scene.unit_settings.system = 'METRIC'
scene['reference'] = __doc__
scene['dimensions'] = '3.72 m length; 1.68 m width; 2.20 m wheelbase; 1.43/1.40 m track'
export = []
def xyz(p): return (p[0], -p[2], p[1])
def mat(name, color, metal=0, rough=.65):
 m=bpy.data.materials.new(name); m.diffuse_color=(*color,1); m.use_nodes=True
 bs=m.node_tree.nodes.get('Principled BSDF'); bs.inputs['Base Color'].default_value=(*color,1)
 bs.inputs['Metallic'].default_value=metal; bs.inputs['Roughness'].default_value=rough
 return m
paint=mat('NivaWhite',(.88,.87,.81),.12,.58)
rubber=mat('NivaRubber',(.019,.022,.023),0,.92)
black=mat('NivaBlack',(.025,.03,.032),.1,.66)
steel=mat('NivaSteel',(.55,.56,.52),.65,.4)
glass=mat('NivaGlass',(.16,.22,.25),.1,.22)
bs=glass.node_tree.nodes.get('Principled BSDF'); bs.inputs['Alpha'].default_value=.24; glass.surface_render_method='DITHERED'
seat=mat('NivaUpholstery',(.105,.085,.064),0,.95)
red=mat('NivaTail',(.48,.027,.012),.05,.3)
amber=mat('NivaAmber',(.85,.32,.025),.1,.3)
lamp=mat('NivaLamp',(.85,.81,.63),.15,.25)
white=mat('NivaPlate',(.91,.9,.86),0,.8)
dirt=mat('NivaDirt',(.23,.19,.12),0,.95)
def mesh(name, verts, faces, material):
 me=bpy.data.meshes.new(name); me.from_pydata([xyz(v) for v in verts],[],faces); me.update()
 bm=bmesh.new(); bm.from_mesh(me); bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces)); bm.to_mesh(me); bm.free()
 ob=bpy.data.objects.new(name,me); scene.collection.objects.link(ob); ob.data.materials.append(material); export.append(ob); return ob
def bevel(ob,width=.012):
 mod=ob.modifiers.new('Soft pressed edges','BEVEL'); mod.width=width; mod.segments=3; mod.harden_normals=True
 mod=ob.modifiers.new('Weighted panel normals','WEIGHTED_NORMAL'); mod.keep_sharp=True
 return ob
def box(name,p,s,material,edge=.006):
 x,y,z=(0,0,0); a,b,c=[v/2 for v in s]
 ob=mesh(name,[(x+i*a,y+j*b,z+k*c) for i,j,k in [(-1,-1,-1),(-1,-1,1),(-1,1,-1),(-1,1,1),(1,-1,-1),(1,-1,1),(1,1,-1),(1,1,1)]],[(0,4,6,2),(1,3,7,5),(0,1,5,4),(2,6,7,3),(0,2,3,1),(4,5,7,6)],material)
 ob.location=xyz(p)
 return bevel(ob,edge) if edge else ob
def cyl(name,p,r,length,material,axis='X',n=48):
 bpy.ops.mesh.primitive_cylinder_add(vertices=n,radius=r,depth=length,location=xyz(p)); ob=bpy.context.object; ob.name=name
 if axis=='X': ob.rotation_euler[1]=math.pi/2
 elif axis=='Z': ob.rotation_euler[0]=math.pi/2
 ob.data.materials.append(material); export.append(ob); bevel(ob,.003)
 for f in ob.data.polygons: f.use_smooth=len(f.vertices)==4
 return ob
def rod(name,a,b,r,material):
 av,bv=Vector(xyz(a)),Vector(xyz(b)); ob=cyl(name,(0,0,0),r,(bv-av).length,material,axis='Y',n=12)
 ob.location=(av+bv)/2; ob.rotation_euler=(bv-av).to_track_quat('Z','Y').to_euler(); return ob
def quad(name,pts,material): return mesh(name,pts,[(0,1,2,3)],material)
def window(name,pts):
 # Outer white pressing, inset black weatherstrip, then clear glass.
 center=sum((Vector(p) for p in pts),Vector())/len(pts)
 def inset(f): return [tuple(center+(Vector(p)-center)*f) for p in pts]
 a=pts; b=inset(.94); c=inset(.90)
 mesh(name+' surround',a+b,[(i,(i+1)%4,(i+1)%4+4,i+4) for i in range(4)],paint)
 mesh(name+' seal',b+c,[(i,(i+1)%4,(i+1)%4+4,i+4) for i in range(4)],rubber)
 quad(name,c,glass)
# Pressed lower shell, hollow cabin, round wheel openings.
body=box('Lower monocoque', (0,.755,0), (1.66,.57,3.44),paint,.025)
for face in body.data.polygons: face.use_smooth=True
cutters=[]
def subtract(target,cut):
 mod=target.modifiers.new('Editable opening '+cut.name,'BOOLEAN'); mod.object=cut; mod.operation='DIFFERENCE'
 cutters.append(cut); export.remove(cut); cut.hide_render=True; cut.hide_set(True)
# Booleans precede bevel and normals.
for z in [-1.1,1.1]:
 cut=cyl('Arch cutter '+str(z),(0,.35,z),.398,2.1,black,n=64)
 for mod in list(cut.modifiers): cut.modifiers.remove(mod)
 subtract(body,cut)
cut=box('Cabin cavity',(0,.95,.52),(1.49,.76,2.25),black,0); subtract(body,cut)
# Move boolean modifiers before final edge treatment.
for i,mod in enumerate(list(body.modifiers)):
 if mod.type=='BOOLEAN': bpy.context.view_layer.objects.active=body; bpy.ops.object.modifier_move_up(modifier=mod.name); bpy.ops.object.modifier_move_up(modifier=mod.name)
# Bonnet: slight slope, broad flat pressing, shoulders.
mesh('Bonnet',[(-.80,.965,-1.72),(.80,.965,-1.72),(.80,1.045,-.65),(-.80,1.045,-.65),(-.80,.91,-1.72),(.80,.91,-1.72),(.80,1.0,-.65),(-.80,1.0,-.65)],[(0,1,2,3),(4,7,6,5),(0,4,5,1),(3,2,6,7),(0,3,7,4),(1,5,6,2)],paint)
# Roof and four glass apertures; no solid slab behind the windows.
box('Roof pressing',(0,1.625,.60),(1.43,.065,1.76),paint,.025)
window('Windscreen',[(-.79,1.045,-.655),(.79,1.045,-.655),(.70,1.598,-.23),(-.70,1.598,-.23)])
window('Rear hatch glass',[(.79,1.065,1.72),(-.79,1.065,1.72),(-.70,1.595,1.43),(.70,1.595,1.43)])
def sidepoint(side,z,y,extra=0): return (side*(.826-(y-1.04)*.225+extra),y,z)
for side in [-1,1]:
 def sp(z,y,extra=0): return sidepoint(side,z,y,extra)
 window('Door glass '+str(side),[sp(-.625,1.055),sp(.43,1.055),sp(.43,1.59),sp(-.225,1.59)])
 window('Rear quarter glass '+str(side),[sp(.50,1.055),sp(1.68,1.055),sp(1.42,1.59),sp(.50,1.59)])
 quad('B pillar '+str(side),[sp(.43,1.04),sp(.50,1.04),sp(.50,1.60),sp(.43,1.60)],paint)
 # A/C pillars and roof gutter.
 rod('A pillar',sp(-.65,1.04),sp(-.24,1.60),.024,paint)
 rod('C pillar',sp(1.70,1.04),sp(1.43,1.60),.035,paint)
 rod('Rain gutter',sp(-.23,1.62,.013),sp(1.44,1.62,.013),.012,steel)
 rod('Vent window divider',sp(-.39,1.07,.003),sp(-.12,1.57,.003),.008,rubber)
 # Long doors, fine panel gaps and side waist crease.
 for a,b in [((-.64,.81),(-.64,1.045)),((.46,.49),(.46,1.045)),((-.53,.49),(.46,.49))]:
  rod('Door seam',sp(*a,.005),sp(*b,.005),.0025,black)
 rod('Waist pressing',sp(-1.67,1.025,.006),sp(1.68,1.025,.006),.007,paint)
 box('Door handle',(side*.836,.97,.29),(.027,.031,.13),black)
 cyl('Door lock',(side*.853,.925,.30),.009,.009,steel,n=16)
 rod('Mirror stalk',(side*.83,1.08,-.54),(side*.96,1.18,-.58),.012,black)
 box('Mirror housing',(side*.985,1.21,-.60),(.15,.12,.055),black,.018)
 box('Mirror face',(side*.985,1.21,-.568),(.13,.10,.004),steel)
 box('Side repeater',(side*.839,1.0,-1.43),(.014,.045,.085),amber)
 for z in [-1.1,1.1]:
  # Thin painted lip follows the wheel opening, original narrow arches.
  verts=[]
  for r in [.398,.414]:
   for i in range(49):
    a=math.pi*i/48; verts.append((side*.837,.35+math.sin(a)*r,z+math.cos(a)*r))
  mesh('Pressed wheel arch',verts,[(i,i+1,i+50,i+49) for i in range(48)],paint)
  box('Mud flap',(side*.71,.32,z+.37),(.21,.30,.018),rubber)
 # Subtle sill dirt strip, chips kept sparse.
 box('Sill weathering',(side*.834,.478,.02),(.004,.013,1.26),dirt,0)
# Black early grille and round headlamps (upper rectangular sidelights).
box('Grille',(0,.825,-1.729),(1.51,.235,.025),black,.015)
for y in [.755,.795,.835,.875,.915]: box('Grille slat',(0,y,-1.751),(.93,.009,.014),rubber,.002)
for side in [-1,1]:
 cyl('Headlamp bezel',(side*.594,.82,-1.755),.117,.034,steel,axis='Z')
 cyl('Round headlight',(side*.594,.82,-1.776),.101,.015,lamp,axis='Z')
 # Lens fluting, baked into the GLB.
 for x in range(-3,4): box('Lens flute',(side*.594+x*.022,.82,-1.786),(.002,.14,.002),white,0)
 box('Sidelight housing',(side*.59,1.005,-1.735),(.227,.092,.022),rubber,.013)
 box('Front indicator',(side*.643,1.005,-1.75),(.090,.066,.009),amber)
 box('Front sidelight',(side*.538,1.005,-1.75),(.091,.066,.009),white)
 box('Rear lamp housing',(side*.565,.91,1.735),(.36,.14,.03),black)
 box('Rear red lamp',(side*.64,.91,1.755),(.17,.108,.013),red)
 box('Rear amber lamp',(side*.49,.91,1.755),(.11,.108,.013),amber)
 box('Reversing lamp',(side*.41,.91,1.755),(.045,.108,.013),white)
 for z in [-1.82,1.82]: box('Bumper overrider',(side*.61,.625,z),(.072,.16,.105),rubber)
box('Lada red badge',(0,.838,-1.77),(.04,.08,.011),red)
rod('Lada sail',(-.01,.815,-1.78),(.01,.855,-1.78),.004,steel)
for z in [-1.82,1.82]:
 box('Chrome bumper',(0,.61,z),(1.73,.092,.085),steel,.015)
 for side in [-1,1]: box('Bumper end',(side*.857,.61,z),(.055,.099,.095),rubber)
 box('Number plate',(0,.705,z),(.43,.105,.012),white)
 # Lettering is a mesh in the editable asset, with comfortable plate margins.
 bpy.ops.object.text_add(location=xyz((0,.705,z+(-.008 if z<0 else .008))))
 text=bpy.context.object; text.name='Plate lettering'; text.data.body='PORA DOMOY'
 text.data.align_x='CENTER'; text.data.align_y='CENTER'; text.data.size=.051
 text.rotation_euler=(math.pi/2,0,0 if z>0 else math.pi)
 text.data.materials.append(black)
 bpy.ops.object.convert(target='MESH'); export.append(bpy.context.object)

# Original small hatch, hinges, horizontal rear lamps, badge and vents.
for side in [-1,1]:
 box('Hatch hinge',(side*.40,1.607,1.445),(.085,.025,.025),steel)
 for y in [1.15,1.21,1.27]: box('C pillar vent',(side*.776,y,1.57),(.009,.025,.055),black)
box('Hatch latch',(0,1.035,1.737),(.06,.02,.02),black)
box('Rear badge',( .49,1.04,1.737),(.20,.028,.012),steel)
for side in [-1,1]:
 rod('Wiper', (side*.28,1.065,-.676),(side*.42,1.17,-.604),.006,black)
 rod('Wiper blade',(side*.22,1.165,-.608),(side*.62,1.19,-.59),.007,rubber)
# Interior: black dash, twin round binnacle, vinyl chairs and three transfer levers.
box('Floor',(0,.53,.37),(1.44,.055,2.60),black)
box('Dashboard',(0,1.005,-.53),(1.45,.16,.32),black,.025)
for x in [-.50,-.30]:
 cyl('Instrument rim',(x,1.08,-.353),.066,.012,steel,axis='Z',n=32)
 cyl('Instrument face',(x,1.08,-.342),.059,.006,rubber,axis='Z',n=32)
 rod('Gauge needle',(x,1.08,-.337),(x-.025,1.113,-.337),.002,white)
 for i in range(12):
  a=i*math.tau/12
  rod('Dial tick',(x+math.cos(a)*.049,1.08+math.sin(a)*.049,-.337),(x+math.cos(a)*.054,1.08+math.sin(a)*.054,-.337),.001,white)

for side in [-1,1]:
 box('Front seat cushion',(side*.40,.72,.16),(.47,.15,.48),seat,.04)
 ob=box('Front seat back',(side*.40,.98,.40),(.47,.53,.12),seat,.035); ob.rotation_euler[0]=-.10
 box('Inner door card',(side*.762,.85,-.02),(.035,.32,.82),black)
 box('Inner door pull',(side*.736,.95,.20),(.028,.023,.16),steel)
box('Rear bench',(0,.77,1.13),(1.27,.17,.43),seat,.03)
box('Rear backrest',(0,1.02,1.38),(1.27,.40,.12),seat,.03)
box('Transmission tunnel',(0,.66,.05),(.24,.22,1.25),black,.02)
for x,z,h in [(0,-.05,.32),(.10,.12,.20),(-.07,.15,.18)]:
 rod('Gear lever',(x,.73,z),(x,.73+h,z-.08),.009,black); cyl('Lever knob',(x,.74+h,z-.08),.02,.03,rubber,axis='Y',n=16)
# Steering wheel separate pivot for existing steering animation.
steer_start=len(export)
rod('Steering column',(-.4,.86,-.47),(-.4,1.10,-.22),.019,black)
# Ring in XY plane, as Godot animates around local Z.
verts=[]; faces=[]
for i in range(48):
 a=i*math.tau/48
 for j in range(8):
  b=j*math.tau/8; r=.175+.011*math.cos(b); verts.append((-.4+r*math.cos(a),1.10+r*math.sin(a),-.20+.011*math.sin(b)))
for i in range(48):
 for j in range(8): faces.append((i*8+j,((i+1)%48)*8+j,((i+1)%48)*8+(j+1)%8,i*8+(j+1)%8))
mesh('Steering rim',verts,faces,rubber)
for a in [0,math.pi,math.pi*1.5]: rod('Steering spoke',(-.4,1.10,-.20),(-.4+math.cos(a)*.17,1.10+math.sin(a)*.17,-.20),.008,steel)
# Group steering pieces under an origin at its axis.
def parent_group(name,objects,origin):
 empty=bpy.data.objects.new(name,None); scene.collection.objects.link(empty); empty.location=xyz(origin); export.append(empty)
 for ob in objects: ob.parent=empty
 # Explicit preserve world positions; depsgraph must evaluate new origin first.
 bpy.context.view_layer.update()
 for ob in objects: ob.matrix_parent_inverse=empty.matrix_world.inverted()
 return empty
parent_group('SteeringWheel',export[steer_start+1:],(-.4,1.10,-.20))
# Four independent wheel pivots, narrow original 16-inch stamped steel rims.
for index,(z,track) in enumerate([(-1.1,.715),(1.1,.700)]):
 for side in [-1,1]:
  start=len(export); x=side*track
  # Rounded cross-section carcass, no torus hole exposed behind steel rim.
  verts=[]; faces=[]; profile=[(-.092,.235),(-.093,.29),(-.075,.331),(-.05,.343),(.05,.343),(.075,.331),(.093,.29),(.092,.235)]
  for xx,r in profile:
   for i in range(64):
    a=i*math.tau/64; verts.append((x+xx,.35+math.cos(a)*r,z+math.sin(a)*r))
  for j in range(len(profile)-1):
   for i in range(64): faces.append((j*64+i,j*64+(i+1)%64,(j+1)*64+(i+1)%64,(j+1)*64+i))
  ob=mesh('Tyre carcass',verts,faces,rubber)
  for p in ob.data.polygons:p.use_smooth=True
  cyl('Steel rim',(x,.35,z),.216,.165,steel)
  cyl('Stamped dish',(x+side*.089,.35,z),.168,.014,steel)
  cyl('Hub cap',(x+side*.104,.35,z),.084,.035,steel)
  for i in range(8):
   a=i*math.tau/8
   cyl('Rim ventilation',(x+side*.099,.35+math.cos(a)*.164,z+math.sin(a)*.164),.022,.006,black,n=16)
  for i in range(5):
   a=i*math.tau/5; cyl('Wheel bolt',(x+side*.112,.35+math.cos(a)*.108,z+math.sin(a)*.108),.009,.012,black,n=12)
  for i in range(36):
   a=i*math.tau/36
   for lane in [-1,1]:
    ob=box('Tyre lug',(x+lane*.045,.35+math.cos(a)*.338,z+math.sin(a)*.338),(.075,.014,.034),rubber,.002)
    ob.rotation_euler[0]=-a
  parent_group(('Front' if index==0 else 'Rear')+('Left' if side<0 else 'Right'),export[start:],(x,.35,z))
# Store cutters separately, excluded from GLB while retaining editable booleans.
col=bpy.data.collections.new('Editable opening cutters'); scene.collection.children.link(col)
for ob in cutters:
 for c in list(ob.users_collection):c.objects.unlink(ob)
 col.objects.link(ob)
# Bake modifiers on export only; .blend retains named editable components.
bpy.ops.object.select_all(action='DESELECT')
for ob in export: ob.select_set(True)
scene.world.color=(.2,.2,.2)
bpy.ops.wm.save_as_mainfile(filepath=str(ROOT/'models/source/niva_2121.blend'))
# Collapse export meshes by material within each pivot, retaining the editable source.
for ob in list(export):
 if ob.type == 'MESH':
  bpy.context.view_layer.objects.active=ob
  for modifier in list(ob.modifiers):
   bpy.ops.object.modifier_apply(modifier=modifier.name)
groups={}
for ob in export:
 if ob.type=='MESH': groups.setdefault((ob.parent,ob.data.materials[0].name),[]).append(ob)
for (parent,material_name),objects in groups.items():
 bpy.ops.object.select_all(action='DESELECT')
 for ob in objects: ob.select_set(True)
 bpy.context.view_layer.objects.active=objects[0]
 bpy.ops.object.join()
 objects[0].name=(parent.name+'_' if parent else '')+material_name
bpy.ops.object.select_all(action='DESELECT')
for ob in scene.objects:
 if ob not in cutters: ob.select_set(True)
bpy.ops.export_scene.gltf(filepath=str(ROOT/'models/niva_2121.glb'),export_format='GLB',use_selection=True,export_apply=True,export_yup=True)
print('NIVA_EXPORTED',len(export))
