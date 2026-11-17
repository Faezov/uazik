Niva VAZ-2121
=============

`niva_2121.blend` is the editable source; `../niva_2121.glb` is the game asset.
Named wheel pivots and `SteeringWheel` are attached to the existing physics in
`scripts/niva.gd`. Body panels, window seals, lamps, interior and wheel parts
remain separate editable objects in Blender. Hidden cutters retain the arch and
cabin booleans. The export combines meshes by material within each moving part.
No Blender installation is needed to play.

To rebuild from the source recipe, from the project root:

    blender --background --python models/source/build_niva.py

This regenerates both the blend and GLB. To keep manual Blender edits, export
from the blend instead, excluding the hidden cutter collection. Use glTF's Y-up
conversion. Coordinates in the recipe are metres, +Y up, nose -Z.

References
----------

- [FIA homologation T-1039](https://historicdb.fia.com/sites/default/files/car_attachment/1589598001/homologation_form_number_1039_group_t1.pdf):
  actual front/rear three-quarter photographs on PDF page 1; dimensions on page 2;
  suspension, body and interior photographs later in the document. The model
  follows the original small hatch, horizontal rear lamps, chrome bumpers,
  narrow arches and three-door window outline rather than the later 21213 body.
- [VAZ-2121 1600 driver's manual](https://www.niva-faq.msk.ru/an_lang/Drivers_manual_1600.pdf):
  four-speed ratios, 1.2/2.135 transfer ranges, permanent 4WD, centre lock,
  independent front/coil rear suspension, 16-inch steel wheels and cabin layout.

The body is 1.68 m wide with a 2.20 m wheelbase and 1.43/1.40 m track.
The playable setup uses 1210 kg and an early 4.3 final drive. Torque interpolation,
springs, damping and grip are estimates. The shared raycast suspension does not
simulate front wishbones or the rear live axle mechanically. Centre lock uses a
bounded torque coupling; it is not a full gear/differential solver. Engine audio
uses the project's existing RPM-driven recordings.

Controls and verification
-------------------------

F2 changes vehicles below 0.1 m/s and 0.1 rad/s. Horizontal position and heading,
the world, journey, tracks and radio survive. Only the selected vehicle exists.
Niva: 2 selects high range, 3 selects low range, L toggles centre lock; range/lock
changes require stopping. 1 is also a high-range shortcut and never selects 2WD.
C and V retain the existing cockpit and inspection controls.

Checked in Godot 4.5: both models rendered in the procedural world; Niva front,
rear and cockpit reviewed; repeated stationary switching, moving-switch refusal,
camera/control/effects rebinding, permanent 4WD, range/lock selection, braking,
flat and uneven-mesh wheel contact, snow/ice/deep-snow/dirt grip, and a switch
around z=-240 preserving chunk identities, radio, position, heading and cockpit.

The UAZ matched its pre-Niva baseline exactly over a 900-frame drive/brake
comparison, including a change to 4H. No world-generation code was changed for
the Niva.
