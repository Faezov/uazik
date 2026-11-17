Validated with Godot 4.5 stable, 60 fixed physics ticks per second, headless.

The road follower uses the existing `drive(throttle, steering, brake, delta)` method and 4H. It starts at the normal spawn, follows bends and slopes, brakes ahead of ice, and never changes the vehicle transform or velocity during a run. Each run must cover 5,050 m physically and at least 5,000 m along the road. The driver stops and reports a section if it leaves the road, falls through terrain, or makes no forward progress for 60 seconds.

Final driving results:

| Seed | Vehicle | Driven distance | Unexpected collisions | Blocked sections | Maximum road offset | Wall time | Peak static memory |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 452 | UAZ | 5050.00 m | 0 | 0 | 0.81 m | 40.8 s | 170.8 MiB |
| 453 | UAZ | 5050.06 m | 0 | 0 | 0.24 m | 41.2 s | 170.0 MiB |
| 987 | UAZ | 5050.09 m | 0 | 0 | 0.40 m | 43.5 s | 170.0 MiB |
| 452 | Niva | 5050.11 m | 0 | 0 | 1.69 m | 44.2 s | 167.0 MiB |

Total after changes: 20.200 km. All runs reported zero missing driven chunks, physical road obstructions, snow-effect samples in fully autumn areas, and surface-sampling errors. Each run loaded at most 100 chunks, including the existing streaming hysteresis. Wheel/ground contact is normal and is excluded from the unexpected-collision count.

Before/after placement audit across the streamed routes:

| Seed | Tree pairs closer than 2.4 m, before → after | Trees inside American building clearance, before → after | Minimum trunk spacing, before → after |
| --- | ---: | ---: | ---: |
| 452 | 14,644 → 0 | 57 → 0 | 0.66 → 3.20 m |
| 453 | 14,275 → 0 | 45 → 0 | 0.67 → 3.20 m |
| 987 | 14,065 → 0 | 59 → 0 | 0.67 → 3.20 m |

All three baseline drives also completed 5.05 km without road blockages, but scenery had no solid obstacle bodies and snowfall remained active in America. American houses also occupied steep road-cut slopes. Their sites now use a 30 m setback and reject steep footprints.

Placement uses global candidate cells and deterministic priority thinning across chunk boundaries. Building, fence and utility clearances are sampled independently of chunk build order. Rocks reserve space around potential trunks. Simple capsule/box colliders are grouped into three bodies per nearby chunk and removed beyond two chunks; distant scenery retains only render batches and placement data.

Autumn now has bare rocks, leaf litter, brown ground, asphalt and dirt shoulders. Snowfall shrinks through the transition and becomes hidden and stops emitting in full autumn. Snow spray also fades out and is hidden in America; existing dust emitters take over. The tire force model is unchanged; its surface coefficient blends from the original winter value to 0.82 on asphalt and 0.60 on dirt.

Additional validation:

- 193,243 environment checks passed on seeds 452, 453 and 987, covering obstacle activation, road/building clearance, complete colliders, regeneration after unloading, snow-free prototypes/ground samples, and surface grip.
- Six separate deliberate impact probes passed: UAZ and Niva against generated trees, buildings and rocks. Fresh vehicles spawned for each approach, drove approximately 5 m under their own physics, registered the expected obstacle collision and stopped below 0.08 m/s. Probe distances are excluded from the long-drive totals.
- 581 camera checks passed, including both vehicles, first/third-person modes, inspection orbit/pan/zoom and returning to driving.
- Camera following, vehicle force/control code, Niva implementation, inspection, audio, radio and pause-menu code were checked against the starting version. Only the shared surface-grip hook was added to the vehicle.
- `git diff --check` passed; final Godot logs contain no script errors or warnings.

Baseline UAZ wall times were 42.0, 41.5 and 42.9 seconds; final UAZ times were 40.8, 41.2 and 43.5 seconds. Peak static memory, including audit data, fell from approximately 173–174 MiB to 170–171 MiB. These measurements show no significant headless regression; GPU/rendering performance was not measured.

Reproduce from the project root (use the installed Godot executable in place of `godot`):

```sh
godot --headless --path . --fixed-fps 60 --script tests/headless_drive.gd -- 452
godot --headless --path . --fixed-fps 60 --script tests/headless_drive.gd -- 453
godot --headless --path . --fixed-fps 60 --script tests/headless_drive.gd -- 987
godot --headless --path . --fixed-fps 60 --script tests/headless_drive.gd -- 452 --niva
godot --headless --path . --fixed-fps 60 --script tests/headless_drive.gd -- --environment
```

The script prints JSON results, writes `user://drive-<seed>-<vehicle>.json` or `user://environment.json`, and exits with a nonzero code on failure.
