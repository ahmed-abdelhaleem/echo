# Echo Unity client

This is the authoritative explorable 3D game client. It uses Unity 6 Personal,
Universal Render Pipeline, C#, and the Input System.

The current free build contains three connected playable vignettes:

- **What Remains:** a playable rain-lit bedroom. Walk Noor through a short,
  no-fail objective thread: examine the photograph, cross the room to read the
  phone, make a contextual choice, and see a physical/narrative resolution.
  The room uses a Mixamo humanoid, CC0 PBR furniture, collisions, follow camera,
  objective guidance, optional noticing points, and procedural rain ambience.
- **The Crossing:** a harbor street with shops, café, public transit, plaza,
  ambient pedestrians, imported street furniture, a route-map-to-visitor
  objective thread, and a meaningful choice.
- **The Last Table:** a warmly lit closing-time café with a counter, espresso
  machine, pastries, imported tables/chairs/pendants, a forgotten-sketchbook
  objective thread, people, optional noticing points, and a meaningful choice.

All three use the same directly controlled third-person architecture and link
into a Bedroom → Street → Café → Bedroom loop. This is a playable production
system proof, not a claim that the art-direction, accessibility, performance,
asset/brand, or youth-safe gates have passed.

## Run

Open this directory with Unity `6000.5.4f1` (or the compatible Unity 6 LTS
editor), open `Assets/Scenes/SampleScene.unity`, and press Play.

From the repository root:

```bash
make unity-test
make unity-build-macos
open apps/unity-client/Builds/macOS/Echo.app
```

The scene is generated at runtime so it remains reviewable and deterministic.
It does not call paid generation APIs or require a game account.

## Controls and playthrough

- WASD / left stick — move
- Right-drag / right stick / arrow keys — look
- E / south gamepad button — interact
- Scroll — camera distance
- Escape / start — pause
- R — restart

The objective marker always points toward the next required story object.
Optional interactions do not change trait scoring. **Skip to choice** is an
accessibility path and carries no penalty.

## Free asset workflow

- Blender validates and optimizes authored/imported meshes.
- Mixamo supplies optional humanoid models and animations.
- The asset manifest reproducibly fetches the vetted CC0 1K Poly Haven set used
  across Bedroom, Street, and Café.
- Third-party raw files are committed only when their license explicitly allows
  redistribution. The local Mixamo setup is documented in
  `Assets/Resources/Characters/Noor/README.md`.

Recreate/audit the checked-in environment assets with:

```bash
make unity-fetch-bedroom-assets
make unity-validate-scale
```

`Assets/Resources/Config/real_world_scale_profiles.json` is the authoritative
metre-scale catalog. Every imported scene object needs a category, intended
longest dimension, and valid height range there before use. Blender verifies
the source/profile pair; runtime construction normalizes bounds and attaches
`EchoScaleAudit`; play-mode tests compare every object and the 1.78 m player
reference. Do not fix a bad import by repeatedly changing one scene's scale.

Validate the optional local character with:

```bash
make unity-validate-mixamo
```

If `Walking.fbx` is absent, the game uses a stylized pedestrian and remains
fully runnable.
