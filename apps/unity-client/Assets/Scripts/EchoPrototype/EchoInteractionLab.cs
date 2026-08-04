using System;
using System.Collections;
using System.Text;
using UnityEngine;
using UnityEngine.Rendering;

namespace Echo.FreePrototype
{
    /// <summary>
    /// The authored diagnostic scene from docs/15: flat ground, a table or counter
    /// at the profile's own surface height, one selectable character carrying a
    /// built <see cref="EchoCharacterInteractionRig"/>, one selectable hero prop
    /// carrying an <see cref="EchoHeroProp"/> and an
    /// <see cref="EchoInteractionStation"/>, draggable authoring handles, socket
    /// gizmos and a live metric readout.
    ///
    /// <para>
    /// The lab exists so that "does this look right?" can be answered by looking at
    /// numbers and at socket axes rather than at a video. Nothing here is a prefab:
    /// the whole scene is built procedurally from C# exactly like the rest of the
    /// prototype, and every authored value comes from
    /// <c>Resources/Config/interaction_profiles.json</c>.
    /// </para>
    /// <para>
    /// The lab works on a private clone of the catalog profile. Dragging the grip
    /// or look handle writes straight back into that clone and re-configures the
    /// prop, so socket authoring is a live loop; the shared catalog instance is
    /// never mutated, so a lab session cannot poison the running game.
    /// </para>
    /// <para>
    /// Capture harness contract: <see cref="Build"/>, <see cref="SetCameraPose"/>,
    /// <see cref="BeginInteraction"/>, <see cref="IsInteractionRunning"/>,
    /// <see cref="Coordinator"/>, <see cref="Prop"/>, <see cref="Rig"/> and
    /// <see cref="Camera"/> are the stable surface. Everything else is convenience
    /// for a human sitting in front of the Scene view.
    /// </para>
    /// </summary>
    [DisallowMultipleComponent]
    public sealed class EchoInteractionLab : MonoBehaviour
    {
        /// <summary>Character loaded when <see cref="Build"/> is given no usable id.</summary>
        public const string DefaultCharacterId = "Noor";

        /// <summary>Interaction loaded when <see cref="Build"/> is given no usable id.</summary>
        public const string DefaultInteractionId = "photograph";

        /// <summary>Playback rate the slow-motion button selects.</summary>
        public const float SlowMotionRate = 0.25f;

        private const float GroundHalfExtentMeters = 6f;
        private const float GroundThicknessMeters = 0.1f;
        private const float SurfaceWidthMeters = 1.3f;
        private const float SurfaceDepthMeters = 0.7f;
        private const float SurfaceSlabThicknessMeters = 0.06f;
        private const float SurfaceCentreOffsetMeters = -0.22f;
        private const float CompanionSurfaceOffsetMeters = -1.95f;
        private const float FloorSurfaceEpsilonMeters = 0.05f;

        private const float ApproachStartBackMeters = 0.75f;
        private const float ApproachStartSideMeters = 0.28f;
        private const float CharacterProbeStartMeters = 1.6f;

        private const float DefaultCameraYawDegrees = 34f;
        private const float DefaultCameraPitchDegrees = 14f;
        private const float DefaultCameraDistanceMeters = 2.1f;
        private const float MinimumCameraDistanceMeters = 0.25f;
        private const float MaximumCameraDistanceMeters = 20f;
        private const float MaximumCameraPitchDegrees = 85f;
        private const float CameraFocusSharpness = 6f;

        private const float SocketAxisLengthMeters = 0.06f;
        private const float PalmAxisLengthMeters = 0.09f;
        private const float HandleDiameterMeters = 0.05f;
        private const int GizmoCircleSegments = 48;

        private const float HandleMoveEpsilonMeters = 0.0005f;
        private const float HandleTurnEpsilonDegrees = 0.05f;

        private readonly StringBuilder readoutBuilder = new();

        private Material groundMaterial;
        private Material furnitureMaterial;
        private Material propMaterial;
        private Material accentMaterial;

        private Transform standHandle;
        private Transform gripHandle;
        private Transform lookHandle;
        private Transform cameraHandle;
        private Renderer[] handleRenderers = Array.Empty<Renderer>();

        private Camera labCamera;
        private Animator characterAnimator;
        private EchoMixamoCharacter characterPlayback;

        private Vector3 restCharacterPosition;
        private Quaternion restCharacterRotation = Quaternion.identity;

        private Vector3 lastStandHandlePosition;
        private Quaternion lastStandHandleRotation = Quaternion.identity;
        private Vector3 lastGripHandlePosition;
        private Quaternion lastGripHandleRotation = Quaternion.identity;
        private Vector3 lastLookHandlePosition;
        private Vector3 lastCameraHandlePosition;

        private float cameraYaw = DefaultCameraYawDegrees;
        private float cameraPitch = DefaultCameraPitchDegrees;
        private float cameraDistance = DefaultCameraDistanceMeters;

        private float playbackRate = 1f;
        private bool paused;
        private bool ownsTimeScale;
        private Coroutine stepRoutine;

        private EchoInteractionState pausePhase;
        private bool hasPausePhase;

        private GUIStyle headerStyle;
        private GUIStyle readoutStyle;

        /// <summary>
        /// The character the lab actually loaded, "Noor" or "YBot". It can differ
        /// from the id passed to <see cref="Build"/> when the requested FBX is
        /// missing and the other character was used instead.
        /// </summary>
        public string CharacterId { get; private set; } = DefaultCharacterId;

        /// <summary>The interaction id the lab was built for, e.g. "photograph".</summary>
        public string InteractionId { get; private set; } = DefaultInteractionId;

        /// <summary>
        /// The lab's private, editable copy of the catalog profile. The handles
        /// write into this object; the shared catalog entry is never touched.
        /// </summary>
        public EchoInteractionProfile Profile { get; private set; }

        /// <summary>The interaction state machine driving the lab's character.</summary>
        public EchoInteractionCoordinator Coordinator { get; private set; }

        /// <summary>The hero prop built from <see cref="Profile"/>.</summary>
        public EchoHeroProp Prop { get; private set; }

        /// <summary>The station that resolves where the character stands.</summary>
        public EchoInteractionStation Station { get; private set; }

        /// <summary>The interaction rig built on the character, or null when it failed.</summary>
        public EchoCharacterInteractionRig Rig { get; private set; }

        /// <summary>The lab camera. Its pose comes from <see cref="SetCameraPose"/>.</summary>
        public Camera Camera => labCamera;

        /// <summary>
        /// The framing camera under test. It is present but disabled by default, so
        /// the lab's own orbit stays authoritative and captures are reproducible;
        /// switch it on through <see cref="UseFramingCamera"/>.
        /// </summary>
        public EchoInteractionCamera FramingCamera { get; private set; }

        /// <summary>The character root the coordinator moves during Align.</summary>
        public Transform CharacterRoot { get; private set; }

        /// <summary>True once the rig, the prop and the registration are all live.</summary>
        public bool IsReady
        {
            get
            {
                return Coordinator != null &&
                    Rig != null &&
                    Rig.IsBuilt &&
                    Prop != null &&
                    Prop.Profile != null &&
                    Coordinator.IsRegistered(InteractionId);
            }
        }

        /// <summary>
        /// True from the moment an interaction is reserved until it has recovered.
        /// Mirrors <see cref="EchoInteractionCoordinator.IsBusy"/>.
        /// </summary>
        public bool IsInteractionRunning
        {
            get { return Coordinator != null && Coordinator.IsBusy; }
        }

        /// <summary>Current orbit yaw of the lab camera in degrees.</summary>
        public float CameraYawDegrees
        {
            get { return cameraYaw; }
        }

        /// <summary>Current orbit pitch of the lab camera in degrees.</summary>
        public float CameraPitchDegrees
        {
            get { return cameraPitch; }
        }

        /// <summary>Current orbit distance of the lab camera in metres.</summary>
        public float CameraDistanceMeters
        {
            get { return cameraDistance; }
        }

        /// <summary>The world point the lab camera orbits, i.e. the camera handle.</summary>
        public Vector3 CameraTarget
        {
            get { return cameraHandle != null ? cameraHandle.position : transform.position; }
        }

        /// <summary>
        /// True (the default) while the camera handle tracks the action: the prop's
        /// look target while idle, blended toward the eye anchor while an
        /// interaction runs. Dragging the handle or calling
        /// <see cref="SetCameraTarget"/> switches it off so a capture take can pin
        /// the framing to one point.
        /// </summary>
        public bool CameraFollowsAction { get; set; } = true;

        /// <summary>
        /// True to hand the camera to <see cref="EchoInteractionCamera"/> while an
        /// interaction is framed. The lab's own orbit takes over again whenever the
        /// framing camera is not writing the transform.
        /// </summary>
        public bool UseFramingCamera
        {
            get { return FramingCamera != null && FramingCamera.enabled; }
            set
            {
                if (FramingCamera != null)
                {
                    FramingCamera.enabled = value;
                }
            }
        }

        /// <summary>True to draw the IMGUI button panel and metric readout.</summary>
        public bool ShowOverlay { get; set; } = true;

        /// <summary>True to draw socket axes, reach radii and approach gizmos.</summary>
        public bool ShowGizmos { get; set; } = true;

        /// <summary>True to render the draggable handle markers.</summary>
        public bool ShowHandles
        {
            get { return showHandles; }
            set
            {
                showHandles = value;
                foreach (Renderer handleRenderer in handleRenderers)
                {
                    if (handleRenderer != null)
                    {
                        handleRenderer.enabled = value;
                    }
                }
            }
        }

        private bool showHandles = true;

        /// <summary>The playback rate the lab returns to when it is not paused.</summary>
        public float PlaybackRate
        {
            get { return playbackRate; }
        }

        /// <summary>True while the lab is holding <c>Time.timeScale</c> at zero.</summary>
        public bool IsPaused
        {
            get { return paused; }
        }

        /// <summary>
        /// The metric readout the overlay shows, rebuilt once per frame. Handy for a
        /// capture harness that wants the same text in its log as on screen.
        /// </summary>
        public string ReadoutText { get; private set; } = string.Empty;

        /// <summary>
        /// Builds a complete lab scene and returns the component that owns it. Call
        /// it in play mode: the rig needs the character's PlayableGraph to be
        /// evaluating before any interaction can run.
        /// </summary>
        /// <param name="characterId">"Noor" or "YBot"; anything else falls back to Noor.</param>
        /// <param name="interactionId">A profile id from the catalog, e.g. "mug".</param>
        /// <returns>
        /// The lab, never null. A missing character FBX or a missing profile is
        /// logged and leaves the corresponding half of the lab unbuilt rather than
        /// failing the whole scene.
        /// </returns>
        public static EchoInteractionLab Build(string characterId, string interactionId)
        {
            string resolvedInteractionId = string.IsNullOrEmpty(interactionId)
                ? DefaultInteractionId
                : interactionId;
            GameObject root = new($"EchoInteractionLab_{resolvedInteractionId}");
            EchoInteractionLab lab = root.AddComponent<EchoInteractionLab>();
            lab.Assemble(characterId, resolvedInteractionId);
            return lab;
        }

        /// <summary>
        /// Places the lab camera on its orbit around <see cref="CameraTarget"/>.
        /// This is the deterministic camera the capture matrix drives; it applies
        /// every frame, so a take can set it once and trust it.
        /// </summary>
        /// <param name="yawDegrees">Orbit yaw about world up, in degrees.</param>
        /// <param name="pitchDegrees">Orbit pitch above the target, clamped to ±85.</param>
        /// <param name="distanceMeters">Orbit radius in metres, clamped to 0.25..20.</param>
        public void SetCameraPose(float yawDegrees, float pitchDegrees, float distanceMeters)
        {
            cameraYaw = yawDegrees;
            cameraPitch = Mathf.Clamp(
                pitchDegrees,
                -MaximumCameraPitchDegrees,
                MaximumCameraPitchDegrees);
            cameraDistance = Mathf.Clamp(
                distanceMeters,
                MinimumCameraDistanceMeters,
                MaximumCameraDistanceMeters);
            ApplyCameraPose();
        }

        /// <summary>
        /// Places the character on a specific authored approach yaw around the prop,
        /// then points them back at the prop centre on the floor plane.
        /// </summary>
        /// <param name="yawDegrees">Approach yaw about world up, in degrees.</param>
        /// <returns>False when the lab has no usable profile, station, prop or character.</returns>
        public bool SetApproachYawDegrees(float yawDegrees)
        {
            if (Profile == null || Station == null || Prop == null || CharacterRoot == null)
            {
                return false;
            }

            Vector3 floorPoint = Prop.transform.position;
            floorPoint.y -= Profile.stationHeightMeters;

            Transform source = Prop.SupportPose != null ? Prop.SupportPose : Prop.transform;
            Vector3 referenceForward = source.forward;
            referenceForward.y = 0f;
            if (referenceForward.sqrMagnitude < 0.0001f)
            {
                referenceForward = source.up;
                referenceForward.y = 0f;
            }
            if (referenceForward.sqrMagnitude < 0.0001f)
            {
                referenceForward = Vector3.forward;
            }
            referenceForward.Normalize();

            Vector3 approachDirection =
                Quaternion.AngleAxis(yawDegrees, Vector3.up) * referenceForward;
            Vector3 standPosition = floorPoint + approachDirection * Profile.stationDistanceMeters;

            Vector3 facing = floorPoint - standPosition;
            facing.y = 0f;
            Quaternion standRotation = facing.sqrMagnitude > 0.0001f
                ? Quaternion.LookRotation(facing.normalized, Vector3.up)
                : Quaternion.identity;

            CharacterRoot.SetPositionAndRotation(standPosition, standRotation);
            Physics.SyncTransforms();
            SyncHandlesToScene();
            return true;
        }

        /// <summary>
        /// Advances one deterministic simulation step for capture code that runs
        /// without the normal player loop.
        /// </summary>
        /// <param name="deltaTime">Seconds to advance by.</param>
        public void Tick(float deltaTime)
        {
            float frameDelta = Mathf.Max(0f, deltaTime);

            if (Coordinator != null)
            {
                Coordinator.Tick(frameDelta);
            }
            if (characterPlayback != null)
            {
                characterPlayback.Tick(frameDelta);
            }

            UpdateHandles();
            UpdateCameraTarget();
            ApplyCameraPose();
            ReadoutText = BuildReadout();
        }

        /// <summary>
        /// Pins the camera's orbit centre and stops it tracking the action.
        /// </summary>
        /// <param name="worldPosition">The point the camera should orbit.</param>
        public void SetCameraTarget(Vector3 worldPosition)
        {
            CameraFollowsAction = false;
            if (cameraHandle != null)
            {
                cameraHandle.position = worldPosition;
                lastCameraHandlePosition = worldPosition;
            }
            ApplyCameraPose();
        }

        /// <summary>
        /// Starts the lab's interaction through the ordinary coordinator gate — no
        /// shortcuts, so a refusal here is a real refusal.
        /// </summary>
        /// <returns>False when the machine is busy, or the rig or data is missing.</returns>
        public bool BeginInteraction()
        {
            if (Coordinator == null || string.IsNullOrEmpty(InteractionId))
            {
                return false;
            }
            return Coordinator.TryBegin(InteractionId);
        }

        /// <summary>
        /// Runs the interaction and pauses playback the moment the machine enters
        /// the requested phase. The state machine is never made to skip: the lab
        /// only starts it and stops the clock at the right moment.
        ///
        /// <para>
        /// Phases the machine passes through inside a single frame — Validate,
        /// Reserve, LockLocomotion and Support — pause on the phase that follows
        /// them, because the frame has already moved on by the time the clock stops.
        /// Asking for a phase that has already gone by simply lets playback run.
        /// </para>
        /// </summary>
        /// <param name="phase">The phase to stop on.</param>
        /// <returns>False when there is nothing to run.</returns>
        public bool RunToPhase(EchoInteractionState phase)
        {
            if (Coordinator == null)
            {
                return false;
            }

            pausePhase = phase;
            hasPausePhase = true;
            Resume();
            if (Coordinator.IsBusy)
            {
                return true;
            }

            if (BeginInteraction())
            {
                return true;
            }

            hasPausePhase = false;
            return false;
        }

        /// <summary>
        /// Cancels anything running, puts the prop back on its support pose, returns
        /// the character to the pose the lab was built with and resumes 1x playback.
        /// </summary>
        public void ResetToRest()
        {
            hasPausePhase = false;
            if (Coordinator != null)
            {
                Coordinator.CancelAll();
            }
            if (Prop != null)
            {
                Prop.RestoreRestPose();
            }
            if (CharacterRoot != null)
            {
                CharacterRoot.SetPositionAndRotation(restCharacterPosition, restCharacterRotation);
                Physics.SyncTransforms();
            }
            if (characterPlayback != null)
            {
                characterPlayback.SetPlaybackSpeed(0f);
            }
            SetPlaybackRate(1f);
            SyncHandlesToScene();
        }

        /// <summary>
        /// Sets the rate playback runs at and resumes if the lab was paused. The
        /// slow-motion button uses <see cref="SlowMotionRate"/>.
        /// </summary>
        /// <param name="rate">Multiplier on wall-clock time; clamped to 0.01..4.</param>
        public void SetPlaybackRate(float rate)
        {
            playbackRate = Mathf.Clamp(rate, 0.01f, 4f);
            paused = false;
            ApplyTimeScale();
        }

        /// <summary>Holds playback at the current frame.</summary>
        public void Pause()
        {
            paused = true;
            ApplyTimeScale();
        }

        /// <summary>Releases a pause and returns to <see cref="PlaybackRate"/>.</summary>
        public void Resume()
        {
            paused = false;
            ApplyTimeScale();
        }

        /// <summary>
        /// Advances exactly one frame at 1x and pauses again. A capture harness that
        /// has set <c>Time.captureDeltaTime</c> gets an exact, repeatable step;
        /// otherwise the step is one real rendered frame.
        /// </summary>
        public void StepFrame()
        {
            if (stepRoutine != null || !isActiveAndEnabled)
            {
                return;
            }
            stepRoutine = StartCoroutine(StepFrameRoutine());
        }

        private IEnumerator StepFrameRoutine()
        {
            ownsTimeScale = true;
            Time.timeScale = 1f;

            // Resumes after Update and before LateUpdate of the next frame, by which
            // point that frame has already been advanced with a full delta. Putting
            // the clock back now leaves exactly one frame simulated.
            yield return null;

            paused = true;
            Time.timeScale = 0f;
            stepRoutine = null;
        }

        private void Assemble(string requestedCharacterId, string interactionId)
        {
            InteractionId = interactionId;
            Profile = ResolveProfile(interactionId);
            CreateMaterials();
            BuildLighting();
            BuildGround();

            float surfaceTopMeters = ResolveSurfaceTopMeters(Profile);
            BuildFurniture(surfaceTopMeters);
            BuildCamera();
            BuildCharacter(requestedCharacterId);

            // Colliders created this frame have not been pushed to the physics scene
            // yet, and the prop's support probe is a raycast that runs inside
            // Configure. Without this the prop never finds the table it rests on.
            Physics.SyncTransforms();

            BuildProp(surfaceTopMeters);
            BuildCoordinator();
            BuildHandles();
            PlaceCharacterAtApproach();
            Physics.SyncTransforms();

            ApplyCameraPose();
            SyncHandlesToScene();
            Debug.Log(
                $"[Echo Lab] Built '{InteractionId}' on {CharacterId}: rig " +
                $"{(Rig != null && Rig.IsBuilt ? "built" : "MISSING")}, prop " +
                $"{(Prop != null ? "configured" : "MISSING")}, surface top " +
                $"{surfaceTopMeters:0.000}m.");
        }

        private static EchoInteractionProfile ResolveProfile(string interactionId)
        {
            EchoInteractionProfile source;
            try
            {
                source = EchoInteractionProfileCatalog.Find(interactionId);
            }
            catch (InvalidOperationException error)
            {
                Debug.LogError($"[Echo Lab] The interaction catalog is unusable: {error.Message}");
                return null;
            }

            if (source == null)
            {
                Debug.LogError(
                    $"[Echo Lab] No interaction profile is authored for '{interactionId}'; " +
                    "the lab builds its room without a prop.");
                return null;
            }

            // A private copy, because the handles author straight into it and the
            // catalog instance is shared with every other scene in the process.
            EchoInteractionProfile clone =
                JsonUtility.FromJson<EchoInteractionProfile>(JsonUtility.ToJson(source));
            string reason = "clone is null";
            bool cloneIsValid = clone != null && clone.Validate(out reason);
            if (!cloneIsValid)
            {
                Debug.LogError($"[Echo Lab] '{interactionId}' did not survive cloning: {reason}");
                return source;
            }
            return clone;
        }

        /// <summary>
        /// The world height of the surface the prop rests on. It is derived so the
        /// station's own floor plane lands exactly on y = 0: the profile's support
        /// pose offset is taken out of the authored station height rather than being
        /// ignored, which is what keeps a face-down phone and an upright mug both
        /// honest on the same table.
        /// </summary>
        private static float ResolveSurfaceTopMeters(EchoInteractionProfile profile)
        {
            if (profile == null)
            {
                return 0.75f;
            }
            return profile.stationHeightMeters + ResolveSupportOffset(profile).y;
        }

        /// <summary>
        /// The vector from the prop's origin to its support contact point, in world
        /// axes, once the prop is stood up so the support patch faces world up.
        /// </summary>
        private static Vector3 ResolveSupportOffset(EchoInteractionProfile profile)
        {
            return ResolvePropRotation(profile) * profile.supportPoseLocalPosition;
        }

        /// <summary>
        /// The prop's world rotation at rest: the one that makes the support patch's
        /// +Y point along world up and its +Z point along world +Z, so approach yaw
        /// zero is the +Z side of the table for every profile.
        /// </summary>
        private static Quaternion ResolvePropRotation(EchoInteractionProfile profile)
        {
            return Quaternion.Inverse(Quaternion.Euler(profile.supportPoseLocalEuler));
        }

        private void CreateMaterials()
        {
            groundMaterial = CreateMaterial("EchoLab_Ground", new Color(0.19f, 0.2f, 0.23f), 0.1f);
            furnitureMaterial = CreateMaterial("EchoLab_Wood", new Color(0.36f, 0.24f, 0.16f), 0.2f);
            propMaterial = CreateMaterial("EchoLab_Prop", new Color(0.72f, 0.68f, 0.6f), 0.3f);
            accentMaterial = CreateMaterial("EchoLab_Accent", new Color(0.2f, 0.42f, 0.6f), 0.45f);
        }

        private static Material CreateMaterial(string materialName, Color color, float smoothness)
        {
            Shader shader = Shader.Find("Universal Render Pipeline/Lit");
            if (shader == null)
            {
                shader = Shader.Find("Standard");
            }

            Material material = new(shader) { name = materialName };
            if (material.HasProperty("_BaseColor"))
            {
                material.SetColor("_BaseColor", color);
            }
            if (material.HasProperty("_Color"))
            {
                material.SetColor("_Color", color);
            }
            if (material.HasProperty("_Smoothness"))
            {
                material.SetFloat("_Smoothness", smoothness);
            }
            return material;
        }

        private static Material CreateHandleMaterial(string materialName, Color color)
        {
            Material material = CreateMaterial(materialName, color, 0.1f);
            if (material.HasProperty("_EmissionColor"))
            {
                material.EnableKeyword("_EMISSION");
                material.SetColor("_EmissionColor", color * 0.8f);
            }
            return material;
        }

        private void BuildLighting()
        {
            GameObject lightObject = new("LabKeyLight");
            lightObject.transform.SetParent(transform, false);
            lightObject.transform.rotation = Quaternion.Euler(48f, 38f, 0f);
            Light keyLight = lightObject.AddComponent<Light>();
            keyLight.type = LightType.Directional;
            keyLight.color = new Color(1f, 0.96f, 0.9f);
            keyLight.intensity = 1.25f;
            keyLight.shadows = LightShadows.Soft;

            // Only claim the scene's ambient when the lab is the scene. Built
            // additively next to another world, it leaves that world's lighting be.
            Light[] lights = FindObjectsByType<Light>();
            if (lights.Length > 1)
            {
                return;
            }

            RenderSettings.ambientMode = AmbientMode.Trilight;
            RenderSettings.ambientSkyColor = new Color(0.42f, 0.46f, 0.53f);
            RenderSettings.ambientEquatorColor = new Color(0.3f, 0.31f, 0.34f);
            RenderSettings.ambientGroundColor = new Color(0.14f, 0.14f, 0.16f);
        }

        private void BuildGround()
        {
            CreatePrimitive(
                PrimitiveType.Cube,
                "LabGround",
                transform,
                new Vector3(0f, -GroundThicknessMeters * 0.5f, 0f),
                new Vector3(
                    GroundHalfExtentMeters * 2f,
                    GroundThicknessMeters,
                    GroundHalfExtentMeters * 2f),
                groundMaterial,
                true);
        }

        /// <summary>
        /// Builds the surface the prop rests on plus one companion piece at the
        /// other believable height, so the lab always shows a table next to a
        /// counter and a wrong surface height reads immediately.
        /// </summary>
        private void BuildFurniture(float surfaceTopMeters)
        {
            bool restsOnFloor = surfaceTopMeters <= FloorSurfaceEpsilonMeters;
            if (!restsOnFloor)
            {
                BuildSurface(
                    surfaceTopMeters >= 0.92f ? "LabCounter" : "LabTable",
                    surfaceTopMeters,
                    new Vector3(0f, 0f, SurfaceCentreOffsetMeters));
            }

            float companionTop = surfaceTopMeters >= 0.92f ? 0.75f : 1.05f;
            BuildSurface(
                companionTop >= 0.92f ? "LabCounter_Reference" : "LabTable_Reference",
                companionTop,
                new Vector3(CompanionSurfaceOffsetMeters, 0f, SurfaceCentreOffsetMeters));
        }

        private void BuildSurface(string surfaceName, float topMeters, Vector3 centre)
        {
            GameObject surface = new(surfaceName);
            surface.transform.SetParent(transform, false);
            surface.transform.localPosition = centre;

            CreatePrimitive(
                PrimitiveType.Cube,
                $"{surfaceName}_Top",
                surface.transform,
                new Vector3(0f, topMeters - SurfaceSlabThicknessMeters * 0.5f, 0f),
                new Vector3(SurfaceWidthMeters, SurfaceSlabThicknessMeters, SurfaceDepthMeters),
                furnitureMaterial,
                true);

            float legHeight = Mathf.Max(0.05f, topMeters - SurfaceSlabThicknessMeters);
            float legInsetX = SurfaceWidthMeters * 0.5f - 0.1f;
            float legInsetZ = SurfaceDepthMeters * 0.5f - 0.09f;
            for (int index = 0; index < 4; index++)
            {
                float signX = index < 2 ? -1f : 1f;
                float signZ = index % 2 == 0 ? -1f : 1f;
                CreatePrimitive(
                    PrimitiveType.Cube,
                    $"{surfaceName}_Leg{index}",
                    surface.transform,
                    new Vector3(signX * legInsetX, legHeight * 0.5f, signZ * legInsetZ),
                    new Vector3(0.07f, legHeight, 0.07f),
                    furnitureMaterial,
                    true);
            }
        }

        private void BuildCamera()
        {
            GameObject cameraObject = new("LabCamera");
            cameraObject.transform.SetParent(transform, false);
            labCamera = cameraObject.AddComponent<Camera>();
            labCamera.fieldOfView = 45f;
            labCamera.nearClipPlane = 0.05f;
            labCamera.farClipPlane = 60f;
            labCamera.clearFlags = CameraClearFlags.SolidColor;
            labCamera.backgroundColor = new Color(0.09f, 0.1f, 0.12f);
        }

        private void BuildCharacter(string requestedCharacterId)
        {
            GameObject characterObject = new("LabCharacter");
            characterObject.transform.SetParent(transform, false);
            characterObject.transform.SetPositionAndRotation(
                new Vector3(0f, 0f, CharacterProbeStartMeters),
                Quaternion.LookRotation(Vector3.back, Vector3.up));
            CharacterRoot = characterObject.transform;

            CharacterController collision = characterObject.AddComponent<CharacterController>();
            collision.height = 1.82f;
            collision.radius = 0.28f;
            collision.center = new Vector3(0f, 0.91f, 0f);
            collision.skinWidth = 0.04f;

            foreach (string resourcePath in CandidateCharacterPaths(requestedCharacterId))
            {
                if (TryBuildCharacterVisual(resourcePath))
                {
                    return;
                }
            }

            Debug.LogWarning(
                "[Echo Lab] No character FBX could be loaded from Resources/Characters; the lab " +
                "shows a placeholder body and every interaction will be refused for want of a rig.");
            BuildFallbackBody(characterObject.transform);
        }

        private static string[] CandidateCharacterPaths(string characterId)
        {
            string requested = string.IsNullOrEmpty(characterId) ? DefaultCharacterId : characterId;
            bool wantsYBot = requested.IndexOf("YBot", StringComparison.OrdinalIgnoreCase) >= 0;
            return wantsYBot
                ? new[] { "Characters/YBot/Walking", "Characters/Noor/Walking" }
                : new[] { "Characters/Noor/Walking", "Characters/YBot/Walking" };
        }

        private bool TryBuildCharacterVisual(string resourcePath)
        {
            GameObject modelPrefab = Resources.Load<GameObject>(resourcePath);
            AnimationClip walkClip = FirstImportedClip(resourcePath);
            if (modelPrefab == null || walkClip == null)
            {
                return false;
            }

            string loadedId = resourcePath.IndexOf("YBot", StringComparison.OrdinalIgnoreCase) >= 0
                ? "YBot"
                : "Noor";
            GameObject visual = Instantiate(modelPrefab, CharacterRoot);
            visual.name = $"{loadedId}_Visual";
            visual.transform.SetLocalPositionAndRotation(Vector3.zero, Quaternion.identity);
            visual.transform.localScale = Vector3.one;
            StyleCharacterVisual(visual, resourcePath);
            EchoRealWorldScale.NormalizeCharacter(visual, CharacterRoot);

            characterAnimator = visual.GetComponentInChildren<Animator>();
            if (characterAnimator == null)
            {
                characterAnimator = visual.AddComponent<Animator>();
            }

            characterPlayback = CharacterRoot.gameObject.AddComponent<EchoMixamoCharacter>();
            if (!characterPlayback.Configure(characterAnimator, walkClip, 0f))
            {
                Destroy(characterPlayback);
                Destroy(visual);
                characterPlayback = null;
                characterAnimator = null;
                return false;
            }

            characterPlayback.SetPlaybackSpeed(0f);
            CharacterId = loadedId;

            EchoCharacterInteractionRig rig =
                CharacterRoot.gameObject.AddComponent<EchoCharacterInteractionRig>();
            if (rig.Build(
                    characterAnimator,
                    characterPlayback,
                    EchoCharacterInteractionRig.DefaultCalibration(loadedId)))
            {
                Rig = rig;
            }
            else
            {
                Destroy(rig);
                Rig = null;
            }
            return true;
        }

        private static AnimationClip FirstImportedClip(string resourcePath)
        {
            AnimationClip[] clips = Resources.LoadAll<AnimationClip>(resourcePath);
            foreach (AnimationClip clip in clips)
            {
                if (!clip.name.StartsWith("__preview__", StringComparison.OrdinalIgnoreCase))
                {
                    return clip;
                }
            }
            return null;
        }

        /// <summary>
        /// Re-shades an imported character onto the render pipeline's own lit shader,
        /// keeping whatever diffuse texture came with the FBX. Materials that already
        /// use the pipeline shader are left exactly as the importer made them.
        /// </summary>
        private static void StyleCharacterVisual(GameObject visual, string resourcePath)
        {
            Shader shader = Shader.Find("Universal Render Pipeline/Lit");
            if (shader == null)
            {
                return;
            }

            Texture2D[] embedded = Resources.LoadAll<Texture2D>(resourcePath);
            foreach (Renderer visualRenderer in visual.GetComponentsInChildren<Renderer>(true))
            {
                Material[] sourceMaterials = visualRenderer.sharedMaterials;
                Material[] styledMaterials = new Material[sourceMaterials.Length];
                for (int index = 0; index < sourceMaterials.Length; index++)
                {
                    Material source = sourceMaterials[index];
                    if (source != null &&
                        source.shader != null &&
                        source.shader.name.IndexOf(
                            "Universal Render Pipeline",
                            StringComparison.Ordinal) >= 0)
                    {
                        styledMaterials[index] = source;
                        continue;
                    }

                    string sourceName = source != null ? source.name : "Character";
                    Material styled = new(shader) { name = $"EchoLab_{sourceName}" };
                    Texture2D diffuse = FirstDiffuseTexture(embedded);
                    if (diffuse != null && styled.HasProperty("_BaseMap"))
                    {
                        styled.SetTexture("_BaseMap", diffuse);
                        styled.SetColor("_BaseColor", Color.white);
                    }
                    else if (styled.HasProperty("_BaseColor"))
                    {
                        styled.SetColor("_BaseColor", new Color(0.62f, 0.6f, 0.58f));
                    }
                    styledMaterials[index] = styled;
                }
                visualRenderer.sharedMaterials = styledMaterials;
            }
        }

        private static Texture2D FirstDiffuseTexture(Texture2D[] textures)
        {
            foreach (Texture2D texture in textures)
            {
                if (texture == null)
                {
                    continue;
                }
                string key = texture.name.ToLowerInvariant();
                if (key.Contains("diffuse") || key.Contains("basecolor") || key.Contains("albedo"))
                {
                    return texture;
                }
            }
            return textures.Length > 0 ? textures[0] : null;
        }

        private void BuildFallbackBody(Transform parent)
        {
            CreatePrimitive(
                PrimitiveType.Capsule,
                "FallbackTorso",
                parent,
                new Vector3(0f, 1.08f, 0f),
                new Vector3(0.45f, 0.55f, 0.32f),
                accentMaterial,
                false);
            CreatePrimitive(
                PrimitiveType.Sphere,
                "FallbackHead",
                parent,
                new Vector3(0f, 1.72f, 0f),
                new Vector3(0.42f, 0.46f, 0.4f),
                propMaterial,
                false);
        }

        private void BuildProp(float surfaceTopMeters)
        {
            if (Profile == null)
            {
                return;
            }

            Quaternion propRotation = ResolvePropRotation(Profile);
            Vector3 supportOffset = ResolveSupportOffset(Profile);
            Vector3 supportPoint = new(0f, surfaceTopMeters, 0f);

            GameObject propObject = new($"Prop_{InteractionId}");
            propObject.transform.SetParent(transform, false);
            propObject.transform.SetPositionAndRotation(supportPoint - supportOffset, propRotation);

            BuildPropVisual(propObject.transform);
            Prop = propObject.AddComponent<EchoHeroProp>();
            Prop.Configure(Profile);

            GameObject stationObject = new($"Station_{InteractionId}");
            stationObject.transform.SetParent(transform, false);
            stationObject.transform.position = propObject.transform.position -
                Vector3.up * Profile.stationHeightMeters;
            Station = stationObject.AddComponent<EchoInteractionStation>();
            Station.Configure(Profile, propObject.transform);
        }

        /// <summary>
        /// Builds a readable stand-in body for the prop in the profile's own upright
        /// frame: origin at the centre of the bottom face, +Y up, +Z the face a
        /// person reads. Every visual part is collider-free so the prop keeps the
        /// single box collider <see cref="EchoHeroProp"/> gives it, and the
        /// penetration metric measures the authored box rather than the decoration.
        /// </summary>
        private void BuildPropVisual(Transform propTransform)
        {
            Vector3 size = Profile.dimensionsMeters;
            switch (Profile.interactionId)
            {
                case "mug":
                    BuildMugVisual(propTransform, size);
                    return;
                case "tip_jar":
                    BuildTipJarVisual(propTransform, size);
                    return;
                case "suitcase":
                    BuildSuitcaseVisual(propTransform, size);
                    return;
                default:
                    BuildFlatPropVisual(propTransform, size);
                    return;
            }
        }

        private void BuildFlatPropVisual(Transform propTransform, Vector3 size)
        {
            CreatePrimitive(
                PrimitiveType.Cube,
                "Body",
                propTransform,
                new Vector3(0f, size.y * 0.5f, 0f),
                size,
                propMaterial,
                false);
            // The read face, so a prop that ends up held backwards is obvious.
            CreatePrimitive(
                PrimitiveType.Cube,
                "Face",
                propTransform,
                new Vector3(0f, size.y * 0.5f, size.z * 0.5f + 0.0012f),
                new Vector3(size.x * 0.82f, size.y * 0.82f, 0.002f),
                accentMaterial,
                false);
        }

        private void BuildMugVisual(Transform propTransform, Vector3 size)
        {
            float radius = size.x * 0.5f;
            CreatePrimitive(
                PrimitiveType.Cylinder,
                "Body",
                propTransform,
                new Vector3(0f, size.y * 0.5f, 0f),
                new Vector3(size.x, size.y * 0.5f, size.z),
                propMaterial,
                false);
            CreatePrimitive(
                PrimitiveType.Cube,
                "Handle",
                propTransform,
                new Vector3(radius + 0.015f, size.y * 0.62f, 0f),
                new Vector3(0.03f, 0.05f, 0.014f),
                accentMaterial,
                false);
        }

        private void BuildTipJarVisual(Transform propTransform, Vector3 size)
        {
            CreatePrimitive(
                PrimitiveType.Cylinder,
                "Body",
                propTransform,
                new Vector3(0f, size.y * 0.5f, 0f),
                new Vector3(size.x, size.y * 0.5f, size.z),
                propMaterial,
                false);
            CreatePrimitive(
                PrimitiveType.Cylinder,
                "Lid",
                propTransform,
                new Vector3(0f, size.y - 0.005f, 0f),
                new Vector3(size.x * 1.05f, 0.006f, size.z * 1.05f),
                accentMaterial,
                false);
        }

        private void BuildSuitcaseVisual(Transform propTransform, Vector3 size)
        {
            CreatePrimitive(
                PrimitiveType.Cube,
                "Body",
                propTransform,
                new Vector3(0f, size.y * 0.5f, 0f),
                size,
                propMaterial,
                false);
            CreatePrimitive(
                PrimitiveType.Cube,
                "HandleBar",
                propTransform,
                new Vector3(0f, size.y + 0.018f, 0f),
                new Vector3(0.2f, 0.025f, 0.035f),
                accentMaterial,
                false);
            for (int index = 0; index < 2; index++)
            {
                float sign = index == 0 ? -1f : 1f;
                CreatePrimitive(
                    PrimitiveType.Cube,
                    $"HandlePost{index}",
                    propTransform,
                    new Vector3(sign * 0.085f, size.y + 0.005f, 0f),
                    new Vector3(0.02f, 0.03f, 0.03f),
                    accentMaterial,
                    false);
            }
        }

        private void BuildCoordinator()
        {
            if (CharacterRoot == null)
            {
                return;
            }

            Coordinator = CharacterRoot.gameObject.AddComponent<EchoInteractionCoordinator>();
            // No player locomotion in the lab, and the timed contact signal is what
            // the prototype ships with; swap it through Coordinator.ContactSignal.
            Coordinator.Configure(Rig, CharacterRoot, null, null);
            Coordinator.StateChanged += HandleStateChanged;
            if (Prop != null && Station != null)
            {
                Coordinator.Register(InteractionId, Prop, Station);
            }

            if (labCamera != null)
            {
                FramingCamera = labCamera.gameObject.AddComponent<EchoInteractionCamera>();
                FramingCamera.Configure(labCamera, Coordinator);
                // Off by default: the capture matrix wants the pose it asked for,
                // not the pose the framing solver would rather have.
                FramingCamera.enabled = false;
            }
        }

        private void BuildHandles()
        {
            standHandle = CreateHandle(
                "Handle_Stand",
                transform,
                new Color(0.25f, 0.85f, 0.95f));
            cameraHandle = CreateHandle(
                "Handle_CameraTarget",
                transform,
                new Color(0.95f, 0.95f, 0.95f));

            Transform propParent = Prop != null ? Prop.transform : transform;
            gripHandle = CreateHandle(
                "Handle_Grip",
                propParent,
                new Color(0.95f, 0.25f, 0.8f));
            lookHandle = CreateHandle(
                "Handle_Look",
                propParent,
                new Color(0.98f, 0.85f, 0.2f));

            handleRenderers = new[]
            {
                standHandle.GetComponentInChildren<Renderer>(),
                cameraHandle.GetComponentInChildren<Renderer>(),
                gripHandle.GetComponentInChildren<Renderer>(),
                lookHandle.GetComponentInChildren<Renderer>()
            };
            ShowHandles = showHandles;
        }

        private Transform CreateHandle(string handleName, Transform parent, Color color)
        {
            GameObject handle = new(handleName);
            handle.transform.SetParent(parent, false);
            CreatePrimitive(
                PrimitiveType.Sphere,
                $"{handleName}_Marker",
                handle.transform,
                Vector3.zero,
                Vector3.one * HandleDiameterMeters,
                CreateHandleMaterial($"EchoLab_{handleName}", color),
                false);
            return handle.transform;
        }

        private void PlaceCharacterAtApproach()
        {
            if (CharacterRoot == null)
            {
                return;
            }

            if (Station != null &&
                Station.TryResolveStandPose(
                    CharacterRoot.position,
                    out Vector3 standPosition,
                    out Quaternion standRotation))
            {
                // A step back and to the side of the stand point, already facing the
                // prop, so Align has real travel and a real turn to show.
                Vector3 start = standPosition -
                    standRotation * Vector3.forward * ApproachStartBackMeters +
                    standRotation * Vector3.right * ApproachStartSideMeters;
                start.y = 0f;
                CharacterRoot.SetPositionAndRotation(start, standRotation);
            }

            CharacterRoot.GetPositionAndRotation(
                out restCharacterPosition,
                out restCharacterRotation);
        }

        private void HandleStateChanged(EchoInteractionState state)
        {
            if (!hasPausePhase || state != pausePhase)
            {
                return;
            }

            hasPausePhase = false;
            Pause();
        }

        private void LateUpdate()
        {
            UpdateHandles();
            UpdateCameraTarget();
            ApplyCameraPose();
            ReadoutText = BuildReadout();
        }

        /// <summary>
        /// Reads the handles a human dragged in the Scene view and writes them back
        /// into the working profile, then re-configures the prop so the sockets, the
        /// gizmos and the measured grip error all agree again. Handles are only
        /// honoured while the machine is idle; during an interaction they follow the
        /// live scene instead, so a stray drag cannot corrupt a running take.
        /// </summary>
        private void UpdateHandles()
        {
            bool idle = Coordinator == null || !Coordinator.IsBusy;
            bool profileChanged = false;

            if (standHandle != null && CharacterRoot != null)
            {
                if (idle && HasMoved(
                        standHandle.position,
                        lastStandHandlePosition,
                        standHandle.rotation,
                        lastStandHandleRotation))
                {
                    Vector3 standPosition = standHandle.position;
                    standPosition.y = 0f;
                    CharacterRoot.SetPositionAndRotation(standPosition, LevelYaw(standHandle.rotation));
                }
                standHandle.SetPositionAndRotation(CharacterRoot.position, CharacterRoot.rotation);
                lastStandHandlePosition = standHandle.position;
                lastStandHandleRotation = standHandle.rotation;
            }

            if (gripHandle != null && Prop != null && Profile != null)
            {
                if (idle && HasMoved(
                        gripHandle.localPosition,
                        lastGripHandlePosition,
                        gripHandle.localRotation,
                        lastGripHandleRotation))
                {
                    Profile.gripPrimaryLocalPosition = gripHandle.localPosition;
                    Profile.gripPrimaryLocalEuler = gripHandle.localRotation.eulerAngles;
                    profileChanged = true;
                }
                else
                {
                    gripHandle.SetLocalPositionAndRotation(
                        Profile.gripPrimaryLocalPosition,
                        Quaternion.Euler(Profile.gripPrimaryLocalEuler));
                }
                lastGripHandlePosition = gripHandle.localPosition;
                lastGripHandleRotation = gripHandle.localRotation;
            }

            if (lookHandle != null && Prop != null && Profile != null)
            {
                if (idle &&
                    (lookHandle.localPosition - lastLookHandlePosition).sqrMagnitude >
                        HandleMoveEpsilonMeters * HandleMoveEpsilonMeters)
                {
                    Profile.lookTargetLocalPosition = lookHandle.localPosition;
                    profileChanged = true;
                }
                else
                {
                    lookHandle.localPosition = Profile.lookTargetLocalPosition;
                }
                lastLookHandlePosition = lookHandle.localPosition;
            }

            if (profileChanged)
            {
                Prop.Configure(Profile);
                Debug.Log(
                    $"[Echo Lab] '{InteractionId}' sockets re-authored: grip " +
                    $"{Profile.gripPrimaryLocalPosition} / {Profile.gripPrimaryLocalEuler}, look " +
                    $"{Profile.lookTargetLocalPosition}.");
            }
        }

        private void UpdateCameraTarget()
        {
            if (cameraHandle == null)
            {
                return;
            }

            if ((cameraHandle.position - lastCameraHandlePosition).sqrMagnitude >
                HandleMoveEpsilonMeters * HandleMoveEpsilonMeters)
            {
                CameraFollowsAction = false;
                lastCameraHandlePosition = cameraHandle.position;
                return;
            }

            if (CameraFollowsAction)
            {
                float blend = 1f - Mathf.Exp(-CameraFocusSharpness * Time.deltaTime);
                cameraHandle.position = Vector3.Lerp(
                    cameraHandle.position,
                    ResolveActionFocus(),
                    blend);
            }
            lastCameraHandlePosition = cameraHandle.position;
        }

        private Vector3 ResolveActionFocus()
        {
            Vector3 focus = transform.position;
            if (Prop != null)
            {
                focus = Prop.LookTarget != null ? Prop.LookTarget.position : Prop.transform.position;
            }

            if (Rig != null && Rig.IsBuilt && Rig.EyeAnchor != null && IsInteractionRunning)
            {
                focus = Vector3.Lerp(focus, Rig.EyeAnchor.position, 0.4f);
            }
            return focus;
        }

        private void ApplyCameraPose()
        {
            if (labCamera == null)
            {
                return;
            }

            // While the framing camera is easing in, holding or easing out it owns
            // the transform outright; two scripts never write it in the same frame.
            if (FramingCamera != null && FramingCamera.enabled && FramingCamera.IsFraming)
            {
                return;
            }

            Quaternion orbit = Quaternion.Euler(cameraPitch, cameraYaw, 0f);
            Vector3 target = CameraTarget;
            labCamera.transform.SetPositionAndRotation(
                target - orbit * Vector3.forward * cameraDistance,
                orbit);
        }

        private void SyncHandlesToScene()
        {
            if (standHandle != null && CharacterRoot != null)
            {
                standHandle.SetPositionAndRotation(CharacterRoot.position, CharacterRoot.rotation);
                lastStandHandlePosition = standHandle.position;
                lastStandHandleRotation = standHandle.rotation;
            }

            if (Profile != null)
            {
                if (gripHandle != null)
                {
                    gripHandle.SetLocalPositionAndRotation(
                        Profile.gripPrimaryLocalPosition,
                        Quaternion.Euler(Profile.gripPrimaryLocalEuler));
                    lastGripHandlePosition = gripHandle.localPosition;
                    lastGripHandleRotation = gripHandle.localRotation;
                }
                if (lookHandle != null)
                {
                    lookHandle.localPosition = Profile.lookTargetLocalPosition;
                    lastLookHandlePosition = lookHandle.localPosition;
                }
            }

            if (cameraHandle != null)
            {
                cameraHandle.position = ResolveActionFocus();
                lastCameraHandlePosition = cameraHandle.position;
            }
        }

        private static bool HasMoved(
            Vector3 current,
            Vector3 previous,
            Quaternion currentRotation,
            Quaternion previousRotation)
        {
            return (current - previous).sqrMagnitude >
                    HandleMoveEpsilonMeters * HandleMoveEpsilonMeters ||
                Quaternion.Angle(currentRotation, previousRotation) > HandleTurnEpsilonDegrees;
        }

        private static Quaternion LevelYaw(Quaternion rotation)
        {
            Vector3 forward = rotation * Vector3.forward;
            forward.y = 0f;
            if (forward.sqrMagnitude < 0.0001f)
            {
                return Quaternion.identity;
            }
            return Quaternion.LookRotation(forward.normalized, Vector3.up);
        }

        private void ApplyTimeScale()
        {
            ownsTimeScale = true;
            Time.timeScale = paused ? 0f : playbackRate;
        }

        private void OnDisable()
        {
            ReleaseTimeScale();
        }

        private void OnDestroy()
        {
            if (Coordinator != null)
            {
                Coordinator.StateChanged -= HandleStateChanged;
            }
            ReleaseTimeScale();
        }

        private void ReleaseTimeScale()
        {
            if (!ownsTimeScale)
            {
                return;
            }

            Time.timeScale = 1f;
            ownsTimeScale = false;
            paused = false;
        }

        private string BuildReadout()
        {
            readoutBuilder.Clear();
            if (Coordinator == null)
            {
                readoutBuilder.AppendLine("COORDINATOR  missing — the lab has no character rig.");
                return readoutBuilder.ToString();
            }

            EchoInteractionProfile profile = Profile;
            readoutBuilder.AppendLine(
                $"STATE    {Coordinator.State}  ({Coordinator.PhaseProgress * 100f:0}%)");
            readoutBuilder.AppendLine(
                $"GRIP     {FormatMillimetres(Coordinator.GripPositionErrorMeters)} / " +
                $"{FormatDegrees(Coordinator.GripAngleErrorDegrees)}   budget " +
                $"{(profile != null ? profile.gripToleranceMeters * 1000f : 0f):0.0} mm / " +
                $"{(profile != null ? profile.gripAngleToleranceDegrees : 0f):0.0}°");
            readoutBuilder.AppendLine(
                $"IK       primary {Coordinator.PrimaryHandWeight:0.00}   secondary " +
                $"{Coordinator.SecondaryHandWeight:0.00}   look {Coordinator.LookWeight:0.00}");
            readoutBuilder.AppendLine(
                $"FEET     {FormatMillimetres(Coordinator.FootErrorMeters)}   budget 20.0 mm");
            readoutBuilder.AppendLine(
                $"PROP     {(Prop != null && Prop.IsAttached ? "attached" : "on support")}   " +
                $"collision {(Coordinator.IsColliding ? Coordinator.CollisionBlockerName : "clear")}");
            readoutBuilder.AppendLine(
                $"FRAMES   attach {Coordinator.AttachFrameIndex}   release " +
                $"{Coordinator.ReleaseFrameIndex}");
            readoutBuilder.AppendLine(
                $"CAMERA   yaw {cameraYaw:0.0}°  pitch {cameraPitch:0.0}°  " +
                $"distance {cameraDistance:0.00} m");
            readoutBuilder.AppendLine(
                $"TIME     {(paused ? "paused" : $"{playbackRate:0.00}x")}   " +
                $"frame {Time.frameCount}");
            return readoutBuilder.ToString();
        }

        private static string FormatMillimetres(float meters)
        {
            if (float.IsNaN(meters) || float.IsInfinity(meters))
            {
                return "n/a";
            }
            return $"{meters * 1000f:0.0} mm";
        }

        private static string FormatDegrees(float degrees)
        {
            if (float.IsNaN(degrees) || float.IsInfinity(degrees))
            {
                return "n/a";
            }
            return $"{degrees:0.0}°";
        }

        private void OnGUI()
        {
            if (!ShowOverlay)
            {
                return;
            }

            EnsureStyles();
            float scale = Mathf.Clamp(Screen.height / 900f, 0.8f, 1.35f);
            Matrix4x4 previousMatrix = GUI.matrix;
            GUI.matrix = Matrix4x4.Scale(new Vector3(scale, scale, 1f));

            GUILayout.BeginArea(new Rect(16f, 16f, 400f, 470f), GUI.skin.box);
            GUILayout.Label($"ECHO INTERACTION LAB — {CharacterId} / {InteractionId}", headerStyle);

            GUILayout.BeginHorizontal();
            if (GUILayout.Button("Rest"))
            {
                ResetToRest();
            }
            if (GUILayout.Button("Reach"))
            {
                RunToPhase(EchoInteractionState.Reach);
            }
            if (GUILayout.Button("Contact"))
            {
                RunToPhase(EchoInteractionState.Contact);
            }
            GUILayout.EndHorizontal();

            GUILayout.BeginHorizontal();
            if (GUILayout.Button("Hold"))
            {
                RunToPhase(EchoInteractionState.Hold);
            }
            if (GUILayout.Button("Return"))
            {
                RunToPhase(EchoInteractionState.Return);
            }
            if (GUILayout.Button("Restore"))
            {
                RunToPhase(EchoInteractionState.Support);
            }
            GUILayout.EndHorizontal();

            GUILayout.BeginHorizontal();
            if (GUILayout.Button("Play 1x"))
            {
                SetPlaybackRate(1f);
            }
            if (GUILayout.Button("0.25x"))
            {
                SetPlaybackRate(SlowMotionRate);
            }
            if (GUILayout.Button(paused ? "Resume" : "Pause"))
            {
                if (paused)
                {
                    Resume();
                }
                else
                {
                    Pause();
                }
            }
            if (GUILayout.Button("Step"))
            {
                StepFrame();
            }
            GUILayout.EndHorizontal();

            GUILayout.Label($"Camera yaw {cameraYaw:0.0}°");
            float yaw = GUILayout.HorizontalSlider(cameraYaw, -180f, 180f);
            GUILayout.Label($"Camera pitch {cameraPitch:0.0}°");
            float pitch = GUILayout.HorizontalSlider(cameraPitch, -20f, 70f);
            GUILayout.Label($"Camera distance {cameraDistance:0.00} m");
            float distance = GUILayout.HorizontalSlider(cameraDistance, 0.5f, 5f);
            SetCameraPose(yaw, pitch, distance);

            GUILayout.BeginHorizontal();
            ShowHandles = GUILayout.Toggle(ShowHandles, "Handles");
            CameraFollowsAction = GUILayout.Toggle(CameraFollowsAction, "Follow action");
            UseFramingCamera = GUILayout.Toggle(UseFramingCamera, "Framing cam");
            GUILayout.EndHorizontal();

            GUILayout.Label(ReadoutText, readoutStyle);
            GUILayout.Label(
                "Gizmos: X red, Y green, Z blue. Palm +Z is the palm normal and must " +
                "meet the grip socket's +Z.",
                readoutStyle);
            GUILayout.EndArea();

            GUI.matrix = previousMatrix;
        }

        private void EnsureStyles()
        {
            if (headerStyle != null)
            {
                return;
            }

            headerStyle = new GUIStyle(GUI.skin.label)
            {
                fontStyle = FontStyle.Bold,
                fontSize = 13
            };
            readoutStyle = new GUIStyle(GUI.skin.label)
            {
                fontSize = 12,
                wordWrap = true
            };
        }

        /// <summary>
        /// Draws every socket as three coloured axis lines — X red, Y green, Z blue —
        /// plus the arm's reach sphere and the station's approach ring, so a socket
        /// that is merely turned the wrong way is visible instead of only wrong-looking.
        /// </summary>
        private void OnDrawGizmos()
        {
            if (!ShowGizmos)
            {
                return;
            }

            if (Prop != null)
            {
                DrawSocketAxes(Prop.GripPrimary, SocketAxisLengthMeters);
                DrawSocketAxes(Prop.GripSecondary, SocketAxisLengthMeters);
                DrawSocketAxes(Prop.SupportPose, SocketAxisLengthMeters);
                DrawSocketAxes(Prop.InspectPivot, SocketAxisLengthMeters * 0.7f);
                if (Prop.LookTarget != null)
                {
                    Gizmos.color = new Color(0.98f, 0.85f, 0.2f);
                    Gizmos.DrawWireSphere(Prop.LookTarget.position, 0.012f);
                }
            }

            if (Rig != null && Rig.IsBuilt)
            {
                DrawSocketAxes(Rig.PalmSocket(EchoHand.Right), PalmAxisLengthMeters);
                DrawSocketAxes(Rig.PalmSocket(EchoHand.Left), PalmAxisLengthMeters);
                DrawSocketAxes(Rig.EyeAnchor, PalmAxisLengthMeters);
                DrawReachSphere();
            }

            DrawStationGizmos();
            DrawHandleGizmos();
        }

        private static void DrawSocketAxes(Transform socket, float length)
        {
            if (socket == null)
            {
                return;
            }

            Vector3 origin = socket.position;
            Gizmos.color = Color.red;
            Gizmos.DrawLine(origin, origin + socket.right * length);
            Gizmos.color = Color.green;
            Gizmos.DrawLine(origin, origin + socket.up * length);
            Gizmos.color = Color.blue;
            Gizmos.DrawLine(origin, origin + socket.forward * length);
            Gizmos.color = new Color(1f, 1f, 1f, 0.6f);
            Gizmos.DrawWireSphere(origin, length * 0.12f);
        }

        private void DrawReachSphere()
        {
            if (characterAnimator == null || !characterAnimator.isHuman || Profile == null)
            {
                return;
            }

            Transform shoulder = characterAnimator.GetBoneTransform(
                Profile.PrimaryHand == EchoHand.Left
                    ? HumanBodyBones.LeftUpperArm
                    : HumanBodyBones.RightUpperArm);
            if (shoulder == null)
            {
                return;
            }

            Gizmos.color = new Color(0.25f, 0.85f, 0.95f, 0.5f);
            Gizmos.DrawWireSphere(shoulder.position, Rig.Calibration.reachMeters);
        }

        private void DrawStationGizmos()
        {
            if (Station == null || Profile == null || Prop == null)
            {
                return;
            }

            Vector3 floorPoint = Prop.transform.position -
                Vector3.up * Profile.stationHeightMeters;
            Gizmos.color = new Color(0.4f, 0.9f, 0.5f, 0.8f);
            DrawCircle(floorPoint, Profile.stationDistanceMeters);

            Vector3 reference = Prop.SupportPose != null ? Prop.SupportPose.forward : Vector3.forward;
            reference.y = 0f;
            if (reference.sqrMagnitude < 0.0001f)
            {
                reference = Prop.SupportPose != null ? Prop.SupportPose.up : Vector3.forward;
                reference.y = 0f;
            }
            if (reference.sqrMagnitude < 0.0001f)
            {
                reference = Vector3.forward;
            }
            reference.Normalize();

            foreach (float yaw in Profile.approachYawDegrees)
            {
                Vector3 direction = Quaternion.AngleAxis(yaw, Vector3.up) * reference;
                Gizmos.DrawLine(
                    floorPoint,
                    floorPoint + direction * Profile.stationDistanceMeters);
            }

            Gizmos.color = new Color(0.4f, 0.9f, 0.5f);
            Gizmos.DrawWireSphere(Station.StandPoint, 0.05f);
        }

        private void DrawHandleGizmos()
        {
            DrawSocketAxes(standHandle, PalmAxisLengthMeters);
            DrawSocketAxes(gripHandle, SocketAxisLengthMeters);
            if (cameraHandle != null)
            {
                Gizmos.color = Color.white;
                Gizmos.DrawWireSphere(cameraHandle.position, 0.04f);
                if (labCamera != null)
                {
                    Gizmos.DrawLine(cameraHandle.position, labCamera.transform.position);
                }
            }
        }

        private static void DrawCircle(Vector3 centre, float radius)
        {
            Vector3 previous = centre + new Vector3(radius, 0f, 0f);
            for (int index = 1; index <= GizmoCircleSegments; index++)
            {
                float angle = index * Mathf.PI * 2f / GizmoCircleSegments;
                Vector3 next = centre + new Vector3(
                    Mathf.Cos(angle) * radius,
                    0f,
                    Mathf.Sin(angle) * radius);
                Gizmos.DrawLine(previous, next);
                previous = next;
            }
        }

        private GameObject CreatePrimitive(
            PrimitiveType type,
            string primitiveName,
            Transform parent,
            Vector3 localPosition,
            Vector3 localScale,
            Material material,
            bool keepCollider)
        {
            GameObject created = GameObject.CreatePrimitive(type);
            created.name = primitiveName;
            created.transform.SetParent(parent, false);
            created.transform.SetLocalPositionAndRotation(localPosition, Quaternion.identity);
            created.transform.localScale = localScale;

            Renderer createdRenderer = created.GetComponent<Renderer>();
            createdRenderer.sharedMaterial = material;
            createdRenderer.shadowCastingMode = ShadowCastingMode.On;
            createdRenderer.receiveShadows = true;

            if (!keepCollider)
            {
                // Immediate, not deferred: EchoHeroProp.Configure inspects the prop's
                // children for a collider during this same frame, and a collider that
                // is merely scheduled for destruction would make it skip building the
                // one collider the prop is supposed to carry.
                DestroyImmediate(created.GetComponent<Collider>());
            }
            return created;
        }
    }
}
