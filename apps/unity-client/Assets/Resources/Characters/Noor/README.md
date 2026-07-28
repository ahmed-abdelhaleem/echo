# Local Mixamo character: Noor

The playable Bedroom vertical slice can load a realistic Mixamo character from:

`Assets/Resources/Characters/Noor/Walking.fbx`

The local file is intentionally ignored and is not redistributed from this
repository. To reproduce it:

1. Sign in to Mixamo with an Adobe ID.
2. Choose the **Remy** character.
3. Apply the **Walking** animation with **In Place** enabled.
4. Download **FBX Binary**, **With Skin**, **30 FPS**, with no keyframe
   reduction.
5. Rename the file to `Walking.fbx` and place it in this directory.

Adobe's Mixamo FAQ says its characters and animations may be used royalty-free
in video games. When this optional file is absent, the Bedroom slice uses the
checked-in stylized fallback so development and tests remain runnable.
