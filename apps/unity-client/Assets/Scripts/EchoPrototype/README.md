# Echo Unity Personal proof scenes

This client proves the free 3D approach without paid assets or game accounts.
`EchoWorldBootstrap` creates three connected, playable vignettes at runtime in
any Unity scene:

- **What Remains:** Noor's rain-lit bedroom, unmade bed, desk, chipped mug,
  half-packed feeling, three optional noticing points, pacing animated character,
  and a choice about answering honestly.
- **The Crossing:** road, café, bookshop, apartments, bus stop, plaza, trees,
  street props, animated pedestrian, and a choice about helping a visitor.
- **The Last Table:** a closing-time café/shop interior with animated barista,
  last guest, espresso counter, pastries, tables, forgotten sketchbook, three
  optional noticing points, ambient pendant lighting, and a choice about
  returning something left behind.
- bounded third-person movement and a collision-aware damped follow camera in
  all three scenes;
- required two-beat objective routes, optional noticing points, no-penalty
  skip-to-choice, pause/restart, choices, resolutions, and scene transitions;
- hand-relative interaction responses: Noor turns before slowly lifting small
  props into a readable rigged-hand pose and returning them to their supports;
  large luggage receives a grounded handle pull, while nearby characters turn
  toward her;
- visible story and lighting responses that never depend on optional
  exploration.

Press Play in Unity. Hold WASD/left stick to walk; right-drag, right stick, or
the arrow keys to look; press E/south gamepad button to interact; scroll to
zoom; Escape/start pauses; and R restarts the active vignette.

The runtime construction is intentional for this proof of concept. The
Mixamo FBX is loaded from `Assets/Resources/Characters/Noor/Walking.fbx`; crowd
instances receive varied clothing, skin, hair, proportions, facing, and motion
(with a procedural distant fallback when the local FBX is unavailable), and
played through Unity's Playables API, so it does not need a hand-authored
Animator Controller. Verified CC0 Poly Haven meshes now replace hero furniture
in the Bedroom; the parked car, hydrant, planters, and book display in The
Crossing; and the reading nook, plant, cake, seating, and pendants in The Last
Table. Remaining visible greybox architecture and secondary NPCs still need
authored production passes before the art-direction gate can pass.

`EchoInteractionActionDirector` keeps these motions separate from vignette
progression. Handheld props follow the animated right-hand bone with per-prop
grip/orientation offsets; actions never gate a choice, and restarting a
vignette stops active motions and restores every prop and NPC to its authored
pose.

Imported props are not accepted on visual guesswork alone. The shared
`Resources/Config/real_world_scale_profiles.json` catalog defines their metre
targets and height ranges; `EchoRealWorldScale` normalizes and grounds them,
and play-mode tests fail on missing profiles, scale drift, or wrong-axis
imports. Run `make unity-validate-scale` after adding or replacing any model.
