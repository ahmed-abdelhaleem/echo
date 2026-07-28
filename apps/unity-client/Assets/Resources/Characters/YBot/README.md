# Optional local Mixamo pedestrian

Echo runs without this download: it substitutes a stylized primitive pedestrian.
To enable the animated humanoid used by the local prototype:

1. Sign in to Mixamo with an Adobe ID.
2. Select **Y Bot** and the **Walking** animation.
3. Enable **In Place**.
4. Download **FBX Binary**, **With Skin**, **30 FPS**, and **No Keyframe Reduction**.
5. Save it here as `Walking.fbx`.

Unity imports the model and embedded animation automatically. The raw FBX and its
`.meta` file are deliberately ignored so this repository does not redistribute a
third-party downloadable asset. Adobe states that Mixamo characters and animations
are free with an Adobe ID and royalty-free for use in games:
<https://helpx.adobe.com/creative-cloud/faq/mixamo-faq.html>.
