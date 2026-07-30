using UnityEngine;
using UnityEngine.InputSystem;

namespace Echo.FreePrototype
{
    /// <summary>
    /// Frames a hero-prop interaction and turns arrow input into a point of view.
    ///
    /// <para>
    /// The decision this component encodes: while a prop is in hand the arrow keys
    /// <em>orbit the camera</em> around it and the grip stays exactly where the rig
    /// put it. The hands and the prop do not rotate with the input, because a grip
    /// that turns with the player's camera input is a grip that no longer matches
    /// the hand that is holding it. The alternative — a separate inspect mode where
    /// the arrows turn the object and the camera holds still — is implemented too
    /// and is one flag away: set <see cref="OrbitCameraOnInput"/> to false and the
    /// input is forwarded to
    /// <see cref="EchoInteractionCoordinator.SetInspectOffset"/> instead, which
    /// turns the prop about its inspect pivot after the grip has solved.
    /// </para>
    /// <para>
    /// While it frames, this component owns the camera outright and suspends the
    /// scene's own camera rig, so two scripts never write the same transform in the
    /// same frame. It eases in from, and back out to, the pose that rig last
    /// produced, expressed in the character's frame — which is stable because
    /// locomotion is locked for the whole interaction.
    /// </para>
    /// </summary>
    [DisallowMultipleComponent]
    public sealed class EchoInteractionCamera : MonoBehaviour
    {
        private const float EaseInSeconds = 0.55f;
        private const float EaseOutSeconds = 0.7f;

        /// <summary>Clearance kept around the framed triangle, in metres.</summary>
        private const float FramingMarginMeters = 0.14f;

        private const float MinimumFramingDistanceMeters = 0.55f;
        private const float MaximumFramingDistanceMeters = 3.2f;

        /// <summary>Three-quarter default so the framing sees the face, not the back of the head.</summary>
        private const float DefaultOrbitYawDegrees = 24f;

        private const float DefaultOrbitPitchDegrees = 10f;
        private const float OrbitYawSpeedDegreesPerSecond = 72f;
        private const float OrbitPitchSpeedDegreesPerSecond = 46f;
        private const float OrbitYawLimitDegrees = 120f;
        private const float MinimumOrbitPitchDegrees = -28f;
        private const float MaximumOrbitPitchDegrees = 52f;

        private const float InspectYawSpeedDegreesPerSecond = 80f;
        private const float InspectPitchSpeedDegreesPerSecond = 55f;
        private const float InspectYawLimitDegrees = 150f;
        private const float InspectPitchLimitDegrees = 60f;
        private const float InspectDecayDegreesPerSecond = 180f;

        private const float FocusSharpness = 9f;
        private const float OcclusionProbeRadiusMeters = 0.12f;
        private const float OcclusionMinimumDistanceMeters = 0.35f;

        private Camera framingCamera;
        private EchoInteractionCoordinator coordinator;
        private Behaviour suspendedRig;
        private bool suspendedRigWasEnabled;
        private bool hasSuspendedRig;

        private float blend;
        private float orbitYaw = DefaultOrbitYawDegrees;
        private float orbitPitch = DefaultOrbitPitchDegrees;
        private float inspectYaw;
        private float inspectPitch;

        private Vector3 restoreLocalPosition;
        private Quaternion restoreLocalRotation = Quaternion.identity;
        private bool hasRestorePose;

        private Vector3 smoothedFocus;
        private float smoothedRadius;
        private bool hasSmoothedFocus;

        private Vector3 lastFramingPosition;
        private Quaternion lastFramingRotation = Quaternion.identity;
        private bool hasLastFraming;
        private bool inputEnabled = true;

        /// <summary>
        /// True (the default) to orbit the camera around the held prop on arrow
        /// input while the grip stays fixed. False to switch to the inspect mode
        /// where the arrows turn the prop about its inspect pivot and the camera
        /// holds its framing.
        /// </summary>
        public bool OrbitCameraOnInput { get; set; } = true;

        /// <summary>True while this component is writing the camera transform.</summary>
        public bool IsFraming
        {
            get { return blend > 0f; }
        }

        /// <summary>How far the framing has eased in, in 0..1.</summary>
        public float FramingBlend
        {
            get { return blend; }
        }

        /// <summary>Current orbit yaw about the character's forward axis, in degrees.</summary>
        public float OrbitYawDegrees
        {
            get { return orbitYaw; }
        }

        /// <summary>Current orbit pitch above the framed triangle, in degrees.</summary>
        public float OrbitPitchDegrees
        {
            get { return orbitPitch; }
        }

        /// <summary>The inspect turn this camera has requested, as (yaw, pitch) degrees.</summary>
        public Vector2 InspectOffsetDegrees
        {
            get { return new Vector2(inspectYaw, inspectPitch); }
        }

        /// <summary>
        /// Binds the framing camera and the coordinator whose interaction it frames.
        /// </summary>
        /// <param name="cameraComponent">The camera to drive during an interaction.</param>
        /// <param name="interactionCoordinator">The coordinator to watch.</param>
        /// <param name="cameraRigToSuspend">
        /// The scene camera rig to switch off while framing. Null auto-detects an
        /// <see cref="EchoThirdPersonCamera"/> or <see cref="EchoOrbitCamera"/> on
        /// the same GameObject, which is what the bootstrap builds.
        /// </param>
        public void Configure(
            Camera cameraComponent,
            EchoInteractionCoordinator interactionCoordinator,
            Behaviour cameraRigToSuspend = null)
        {
            EndFraming();
            framingCamera = cameraComponent;
            coordinator = interactionCoordinator;
            suspendedRig = cameraRigToSuspend != null
                ? cameraRigToSuspend
                : ResolveSuspendableRig(cameraComponent);
            ResetView();
        }

        /// <summary>
        /// Turns arrow and stick reading on or off without giving the camera back;
        /// used while a vignette owns the input for dialogue.
        /// </summary>
        /// <param name="value">True to read input.</param>
        public void SetInputEnabled(bool value)
        {
            inputEnabled = value;
        }

        /// <summary>Returns the orbit and the inspect turn to their defaults.</summary>
        public void ResetView()
        {
            orbitYaw = DefaultOrbitYawDegrees;
            orbitPitch = DefaultOrbitPitchDegrees;
            inspectYaw = 0f;
            inspectPitch = 0f;
            hasSmoothedFocus = false;
            hasLastFraming = false;
        }

        /// <summary>
        /// Applies one frame of look input directly, so a test can drive the camera
        /// without a keyboard. The same path the live input uses.
        /// </summary>
        /// <param name="input">(x) yaw axis and (y) pitch axis, each in -1..1.</param>
        /// <param name="deltaTime">Seconds to apply the input over.</param>
        public void ApplyInputForTest(Vector2 input, float deltaTime)
        {
            ApplyInput(Vector2.ClampMagnitude(input, 1f), Mathf.Max(0f, deltaTime));
        }

        private void OnDisable()
        {
            EndFraming();
        }

        private void LateUpdate()
        {
            if (framingCamera == null || coordinator == null)
            {
                return;
            }

            float deltaTime = Time.unscaledDeltaTime;
            bool wantsFraming = ShouldFrame(coordinator.State);
            if (wantsFraming && !hasRestorePose)
            {
                BeginFraming();
            }

            float rate = 1f / (wantsFraming ? EaseInSeconds : EaseOutSeconds);
            blend = Mathf.MoveTowards(blend, wantsFraming ? 1f : 0f, rate * deltaTime);
            if (blend <= 0f)
            {
                if (hasRestorePose || hasSuspendedRig)
                {
                    EndFraming();
                }
                return;
            }

            ApplyInput(inputEnabled ? ReadInput() : Vector2.zero, deltaTime);
            ResolveFraming(deltaTime, out Vector3 framedPosition, out Quaternion framedRotation);
            ResolveRestorePose(out Vector3 restorePosition, out Quaternion restoreRotation);

            float eased = Mathf.SmoothStep(0f, 1f, blend);
            framingCamera.transform.SetPositionAndRotation(
                Vector3.Lerp(restorePosition, framedPosition, eased),
                Quaternion.Slerp(restoreRotation, framedRotation, eased));
        }

        /// <summary>
        /// The window the interaction owns the camera for: from the moment the hand
        /// leaves for the prop until the moment the prop is back on its support.
        /// </summary>
        private static bool ShouldFrame(EchoInteractionState state)
        {
            switch (state)
            {
                case EchoInteractionState.Reach:
                case EchoInteractionState.RampIkIn:
                case EchoInteractionState.Contact:
                case EchoInteractionState.Hold:
                case EchoInteractionState.Return:
                case EchoInteractionState.Support:
                    return true;
                default:
                    return false;
            }
        }

        private void BeginFraming()
        {
            Transform root = coordinator.CharacterRoot;
            Transform cameraTransform = framingCamera.transform;
            if (root != null)
            {
                restoreLocalPosition = root.InverseTransformPoint(cameraTransform.position);
                restoreLocalRotation = Quaternion.Inverse(root.rotation) * cameraTransform.rotation;
            }
            else
            {
                restoreLocalPosition = cameraTransform.position;
                restoreLocalRotation = cameraTransform.rotation;
            }
            hasRestorePose = true;

            if (suspendedRig != null && !hasSuspendedRig)
            {
                suspendedRigWasEnabled = suspendedRig.enabled;
                suspendedRig.enabled = false;
                hasSuspendedRig = true;
            }

            ResetView();
        }

        private void EndFraming()
        {
            blend = 0f;
            hasRestorePose = false;
            hasSmoothedFocus = false;
            hasLastFraming = false;
            if (inspectYaw != 0f || inspectPitch != 0f)
            {
                inspectYaw = 0f;
                inspectPitch = 0f;
                coordinator?.SetInspectOffset(0f, 0f);
            }

            if (hasSuspendedRig && suspendedRig != null)
            {
                suspendedRig.enabled = suspendedRigWasEnabled;
            }
            hasSuspendedRig = false;
        }

        private void ResolveRestorePose(out Vector3 position, out Quaternion rotation)
        {
            Transform root = coordinator.CharacterRoot;
            if (!hasRestorePose)
            {
                framingCamera.transform.GetPositionAndRotation(out position, out rotation);
                return;
            }

            if (root == null)
            {
                position = restoreLocalPosition;
                rotation = restoreLocalRotation;
                return;
            }

            position = root.TransformPoint(restoreLocalPosition);
            rotation = root.rotation * restoreLocalRotation;
        }

        /// <summary>
        /// Builds the framing pose around the eye anchor, the active hand or hands
        /// and the prop. The three are treated as one volume so none of them can
        /// leave the frame while the camera orbits.
        /// </summary>
        private void ResolveFraming(
            float deltaTime,
            out Vector3 position,
            out Quaternion rotation)
        {
            if (!TryGatherFramedVolume(out Bounds framed))
            {
                // The interaction has already cleared itself; hold the last framing
                // so the ease-out has something continuous to blend away from.
                position = hasLastFraming ? lastFramingPosition : framingCamera.transform.position;
                rotation = hasLastFraming ? lastFramingRotation : framingCamera.transform.rotation;
                return;
            }

            float radius = framed.extents.magnitude + FramingMarginMeters;
            if (hasSmoothedFocus)
            {
                float lerp = 1f - Mathf.Exp(-FocusSharpness * deltaTime);
                smoothedFocus = Vector3.Lerp(smoothedFocus, framed.center, lerp);
                smoothedRadius = Mathf.Lerp(smoothedRadius, radius, lerp);
            }
            else
            {
                smoothedFocus = framed.center;
                smoothedRadius = radius;
                hasSmoothedFocus = true;
            }

            Transform root = coordinator.CharacterRoot;
            Vector3 forward = root != null ? root.forward : framingCamera.transform.forward;
            forward.y = 0f;
            if (forward.sqrMagnitude < 0.0001f)
            {
                forward = Vector3.forward;
            }

            Quaternion orbit = Quaternion.LookRotation(forward.normalized, Vector3.up) *
                Quaternion.Euler(orbitPitch, orbitYaw, 0f);
            Vector3 viewDirection = orbit * Vector3.forward;
            float distance = ResolveDistance(smoothedRadius);
            position = ResolveOcclusion(smoothedFocus, smoothedFocus - viewDirection * distance);

            Vector3 toFocus = smoothedFocus - position;
            rotation = toFocus.sqrMagnitude > 0.0001f
                ? Quaternion.LookRotation(toFocus.normalized, Vector3.up)
                : orbit;

            lastFramingPosition = position;
            lastFramingRotation = rotation;
            hasLastFraming = true;
        }

        private bool TryGatherFramedVolume(out Bounds framed)
        {
            framed = new Bounds(Vector3.zero, Vector3.zero);
            EchoCharacterInteractionRig rig = coordinator.Rig;
            EchoHeroProp prop = coordinator.ActiveProp;
            if (rig == null || !rig.IsBuilt || prop == null)
            {
                return false;
            }

            framed = new Bounds(prop.transform.position, Vector3.zero);
            Collider propCollider = prop.GetComponentInChildren<Collider>();
            if (propCollider != null)
            {
                framed.Encapsulate(propCollider.bounds);
            }
            if (prop.LookTarget != null)
            {
                framed.Encapsulate(prop.LookTarget.position);
            }
            if (rig.EyeAnchor != null)
            {
                framed.Encapsulate(rig.EyeAnchor.position);
            }

            Transform primaryPalm = rig.PalmSocket(coordinator.ActiveHand);
            if (primaryPalm != null)
            {
                framed.Encapsulate(primaryPalm.position);
            }

            EchoInteractionProfile profile = coordinator.ActiveProfile;
            if (profile != null && profile.usesSecondaryHand)
            {
                EchoHand secondary = coordinator.ActiveHand == EchoHand.Right
                    ? EchoHand.Left
                    : EchoHand.Right;
                Transform secondaryPalm = rig.PalmSocket(secondary);
                if (secondaryPalm != null)
                {
                    framed.Encapsulate(secondaryPalm.position);
                }
            }
            return true;
        }

        /// <summary>
        /// The distance at which a sphere of the given radius fits inside the frame
        /// on both axes, so a wide window does not crop the top of the triangle.
        /// </summary>
        private float ResolveDistance(float radius)
        {
            float halfVertical = framingCamera.fieldOfView * 0.5f * Mathf.Deg2Rad;
            float verticalDistance = radius / Mathf.Max(0.05f, Mathf.Tan(halfVertical));
            float halfHorizontal = Mathf.Atan(
                Mathf.Tan(halfVertical) * Mathf.Max(0.1f, framingCamera.aspect));
            float horizontalDistance = radius / Mathf.Max(0.05f, Mathf.Tan(halfHorizontal));
            return Mathf.Clamp(
                Mathf.Max(verticalDistance, horizontalDistance),
                MinimumFramingDistanceMeters,
                MaximumFramingDistanceMeters);
        }

        private Vector3 ResolveOcclusion(Vector3 focus, Vector3 desiredPosition)
        {
            Vector3 offset = desiredPosition - focus;
            float distance = offset.magnitude;
            if (distance < 0.01f)
            {
                return desiredPosition;
            }

            Vector3 direction = offset / distance;
            RaycastHit[] hits = Physics.SphereCastAll(
                focus,
                OcclusionProbeRadiusMeters,
                direction,
                distance,
                Physics.DefaultRaycastLayers,
                QueryTriggerInteraction.Ignore);

            Transform root = coordinator.CharacterRoot;
            Transform prop = coordinator.ActiveProp != null
                ? coordinator.ActiveProp.transform
                : null;
            float nearest = distance;
            foreach (RaycastHit hit in hits)
            {
                if (hit.collider == null)
                {
                    continue;
                }
                Transform hitTransform = hit.collider.transform;
                if (root != null && hitTransform.IsChildOf(root))
                {
                    continue;
                }
                if (prop != null && hitTransform.IsChildOf(prop))
                {
                    continue;
                }
                nearest = Mathf.Min(nearest, hit.distance);
            }

            if (nearest >= distance)
            {
                return desiredPosition;
            }
            return focus + direction * Mathf.Max(OcclusionMinimumDistanceMeters, nearest - 0.06f);
        }

        /// <summary>
        /// Reads the same devices the rest of the prototype reads: the new Input
        /// System's keyboard arrows and the gamepad's right stick.
        /// </summary>
        private static Vector2 ReadInput()
        {
            Vector2 input = Vector2.zero;
            Keyboard keyboard = Keyboard.current;
            if (keyboard != null)
            {
                if (keyboard.leftArrowKey.isPressed) input.x -= 1f;
                if (keyboard.rightArrowKey.isPressed) input.x += 1f;
                if (keyboard.upArrowKey.isPressed) input.y += 1f;
                if (keyboard.downArrowKey.isPressed) input.y -= 1f;
            }

            Gamepad gamepad = Gamepad.current;
            if (gamepad != null)
            {
                Vector2 stick = gamepad.rightStick.ReadValue();
                if (stick.sqrMagnitude > input.sqrMagnitude)
                {
                    input = stick;
                }
            }
            return Vector2.ClampMagnitude(input, 1f);
        }

        private void ApplyInput(Vector2 input, float deltaTime)
        {
            if (OrbitCameraOnInput)
            {
                orbitYaw = Mathf.Clamp(
                    orbitYaw + input.x * OrbitYawSpeedDegreesPerSecond * deltaTime,
                    -OrbitYawLimitDegrees,
                    OrbitYawLimitDegrees);
                orbitPitch = Mathf.Clamp(
                    orbitPitch + input.y * OrbitPitchSpeedDegreesPerSecond * deltaTime,
                    MinimumOrbitPitchDegrees,
                    MaximumOrbitPitchDegrees);
                DecayInspectTurn(deltaTime);
                return;
            }

            // Inspect mode: the camera holds the framing it already has and the
            // arrows turn the prop instead. The coordinator applies the turn after
            // the grip has solved, so the hand still owns the prop.
            inspectYaw = Mathf.Clamp(
                inspectYaw + input.x * InspectYawSpeedDegreesPerSecond * deltaTime,
                -InspectYawLimitDegrees,
                InspectYawLimitDegrees);
            inspectPitch = Mathf.Clamp(
                inspectPitch + input.y * InspectPitchSpeedDegreesPerSecond * deltaTime,
                -InspectPitchLimitDegrees,
                InspectPitchLimitDegrees);
            if (coordinator != null)
            {
                coordinator.SetInspectOffset(inspectYaw, inspectPitch);
            }
        }

        /// <summary>
        /// Unwinds any turn left over from inspect mode when the flag is switched
        /// back mid-hold, so the prop is never abandoned at an angle.
        /// </summary>
        private void DecayInspectTurn(float deltaTime)
        {
            if (inspectYaw == 0f && inspectPitch == 0f)
            {
                return;
            }

            float step = InspectDecayDegreesPerSecond * deltaTime;
            inspectYaw = Mathf.MoveTowards(inspectYaw, 0f, step);
            inspectPitch = Mathf.MoveTowards(inspectPitch, 0f, step);
            coordinator.SetInspectOffset(inspectYaw, inspectPitch);
        }

        private static Behaviour ResolveSuspendableRig(Camera cameraComponent)
        {
            if (cameraComponent == null)
            {
                return null;
            }

            EchoThirdPersonCamera follow = cameraComponent.GetComponent<EchoThirdPersonCamera>();
            if (follow != null)
            {
                return follow;
            }
            return cameraComponent.GetComponent<EchoOrbitCamera>();
        }
    }
}
