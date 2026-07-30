# Echo — Hero Prop Interaction Benchmark

> The photograph defines what "right" means. Every other prop inherits the state
> machine, the capture method, the metrics and this checklist — never the
> photograph's numeric offsets.

This document is the reviewed contract for embodied prop interaction in the Unity
client. It exists so that "does this look right?" is answered by measurements and
a fixed review matrix rather than by someone scrubbing a video.

---

## 1. Why this shape

The first implementation moved props with generic transform tweens: the object
lerped toward a pose anchored to a hand bone, on a coroutine timer. That reads as
floating, because nothing in it is causal — the object begins moving before the
hand arrives, the hand never actually contacts the object, and the timing is a
guess rather than a consequence of the motion.

The rebuild inverts the causality:

- **Before contact**, the *hand* moves to the *stationary* object.
- **At contact**, the object attaches to the palm.
- **After contact**, the object is a strict function of the palm:
  `propWorldPose = palmWorldPose × inverse(gripPrimaryLocalPose)`
- **Detach** happens when the support pose is restored, not when a timer expires.

Everything else in this document exists to prove those four statements hold.

---

## 2. The four archetypes

Six objects, four reusable interaction shapes. Object-specific character comes
from the profile data and the IK targets, not from six bespoke implementations.

| Archetype | Objects | Defining behaviour |
|---|---|---|
| `tabletop_one_hand` | phone, mug | One hand lifts a small object from a surface |
| `two_hand_read` | photograph, sketchbook | Primary carries; secondary settles onto grip two |
| `supported_inspect` | tip jar | Touched and turned **in place**; never attaches to a palm |
| `low_handle` | suitcase | Carried by a handle with its base pinned to the floor |

Each archetype covers anticipation, reach, contact, hold, return, release and
recovery. The archetype supplies the motion; the `EchoInteractionProfile` supplies
the object.

### Two constraints that are easy to confuse

`staysSupported` and `groundedPivot` are **mutually exclusive** and mean different
things. `Validate` rejects a profile that sets both.

- `staysSupported` (tip jar) — the prop is **never attached to a palm at all**.
  The hand reaches, touches, and may turn it slightly, but the jar keeps its
  support contact for the whole interaction. It must never float.
- `groundedPivot` (suitcase) — the prop **is** carried by the hand and its
  collider travels with it, but its lowest point stays pinned to whatever surface
  it was resting on, so it tilts about its grounded edge. Note the pin height is
  the prop's actual rest surface, not world zero: the suitcase may sit on a rug.

Collapsing these into one flag welds the suitcase to the floor and silently
contradicts its own acceptance gate.

---

## 3. The frozen profile schema

`Assets/Resources/Config/interaction_profiles.json`, `schemaVersion: 1`, loaded by
`EchoInteractionProfileCatalog`. This mirrors the existing
`real_world_scale_profiles.json` idiom — the world is built from C#, so authored
data lives in JSON, not in prefabs or `.asset` files.

Changing the meaning of an existing field, or removing one, is a schema break:
bump `schemaVersion` and update every profile in the same commit.

### Real-world target dimensions

Props are validated against these on import. A prop outside tolerance fails the
scale audit rather than being silently rescaled at runtime.

| Prop | Dimensions | Archetype |
|---|---|---|
| Photograph / frame | 18 × 24 × 2 cm | `two_hand_read` |
| Phone | 7.5 × 15 × 0.8 cm | `tabletop_one_hand` |
| Mug | 9 cm dia × 10 cm tall | `tabletop_one_hand` |
| Suitcase | 55 × 35 × 22 cm | `low_handle` |
| Sketchbook | 15 × 21 × 2 cm | `two_hand_read` |
| Tip jar | 14 cm dia × 20 cm tall | `supported_inspect` |

### Socket placement rule

Grip sockets go **where a palm or fingers actually contact**, not at the visual
centre. Mug grip on the handle at handle height; photograph grips on the two lower
frame edges; suitcase grip on top-centre of the handle; phone grip on the lower
back face. `SupportPose` stays aligned with the surface the prop rests on.

---

## 4. Acceptance gates

Enforced by `tools/capture/encode_interaction_capture.py` over the `metrics.json`
each take emits. A take with **no** metrics fails: an unmeasured take otherwise
reads exactly like a passing one.

| Metric | Bound |
|---|---|
| `gripPositionErrorMeters` | ≤ 0.02 |
| `gripAngleErrorDegrees` | ≤ 5.0 |
| `footErrorMeters` | ≤ 0.02 |
| `propPenetrationMeters` | = 0 |
| `supportRestoreErrorMeters` | ≤ 0.005 |
| `maxPropSpeedMetersPerSecond` | ≤ 2.5 |
| `propMovementBeforeContactMeters` | ≤ 0.001 |
| `attachFrame` / `releaseFrame` | both ≥ 0 |
| `bothFeetGrounded` | true |

`propMovementBeforeContactMeters` is the gate that catches a regression back to
the old floating behaviour. If the prop moves at all before the hand reaches it,
the causality is wrong no matter how good the video looks.

---

## 5. Review matrix

```bash
make unity-capture-interactions CAPTURE_MATRIX=fast
```

- **fast** — per-commit subset: one prop, front approach, three yaws, 60 fps.
- **full** — pre-review / nightly: eight camera yaws at 45°, three pitches, three
  zooms (near / middle / far), every valid approach, at 30 / 60 / 120 fps, with
  arrow input held throughout, plus restart, pause and repeated-interaction input
  injected during every phase.

Capture is deliberately **not** `com.unity.recorder`. Unity renders fixed-timestep
PNG sequences; ffmpeg encodes MP4s and contact sheets. That keeps the capture path
dependency-free and runnable in CI without a GPU, and it makes output
byte-reproducible so contact sheets can be committed as goldens.

PNG sequences and MP4s are gitignored. Approved golden contact frames are
committed under `tools/capture/golden/`.

---

## 6. Per-object gates

Beyond the shared metrics, each object has one thing that is specifically easy to
get wrong:

| Object | Gate |
|---|---|
| Phone | Portrait, screen toward the eyes, no wrist hyperextension |
| Mug | Fingers through the handle, cup stays level within `maxTiltDegrees` |
| Tip jar | Never floats; support contact is continuous |
| Sketchbook | Both hands have purposeful contact; cover rotates about its hinge |
| Suitcase | Hand stays on the handle, base stays grounded, collider moves with it |
| Photograph | Both hands on the frame edges, held upright facing the eyes |

---

## 7. Camera and input

During a hold, the arrow keys **orbit the camera** while the grip stays fixed.
The hands and prop do not rotate with input. This was chosen over "rotate the
object in an inspect mode" because the grip is the expensive thing to get right,
and rotating the object re-opens every grip and penetration question at every
angle.

The alternative is implemented behind `EchoInteractionCamera.OrbitCameraOnInput`.
Setting it false rotates the prop about its `InspectPivot` and holds the camera
still. It is a switch, not a rewrite.

---

## 8. Known gaps

**Animation assets.** The character set currently has one clip — `Walking.fbx`,
per character, gitignored as a local Mixamo download. There is no authored idle,
no turn-in-place, no reach and no finger poses.

The framework therefore drives reach, contact and hold through **IK targets
rather than authored clips**, and phase progression goes through the
`IEchoContactSignal` seam:

- `EchoTimedContactSignal` — used today, derives phases from the profile timings.
- `EchoAnimationEventContactSignal` — `OnReachContact()` / `OnSupportContact()`,
  callable by name from a Unity `AnimationEvent`.

The coordinator does not know which is in use. When real clips land, author the
events and swap the signal; the state machine does not change.

What clips buy is **quality, not function**: anticipation, weight shift, and
settle that IK alone will not fake. The gates in §4 are all measurable without
them; the gates that remain subjective — does the reach read as intentional, does
the body carry the suitcase's weight — are the ones that need the clips.

The minimum set to acquire, in priority order:

1. Neutral idle (blocks everything; the current idle is two phase-offset copies
   of the walk clip averaged together)
2. Turn-in-place at 45° / 90° / 180°
3. One reach-and-return per archetype (four clips, not six)
4. Finger poses: relaxed, pinch/frame, phone, mug handle, suitcase handle, open
   support

Clips retarget across humanoid characters; each character then needs only a small
`EchoCharacterCalibration` for height, palm orientation, reach and foot offset.
