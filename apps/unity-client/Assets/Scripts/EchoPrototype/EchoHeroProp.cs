using UnityEngine;

namespace Echo.FreePrototype
{
    /// <summary>
    /// The runtime half of an <see cref="EchoInteractionProfile"/>: it turns the
    /// authored local poses into real socket transforms, drives the prop from the
    /// hand that holds it, and measures how well the hand and the grip actually
    /// line up.
    ///
    /// The prop is never reparented to the hand. Reparenting under an animated
    /// bone makes the prop inherit skinning jitter and non-uniform bone scale,
    /// and it hides errors instead of exposing them. Instead the rig evaluates,
    /// then <see cref="FollowAttachment"/> solves the prop's world pose from the
    /// palm socket, so <see cref="GripPositionErrorMeters"/> and
    /// <see cref="GripAngleErrorDegrees"/> stay honest measurements of the rig.
    /// </summary>
    [DisallowMultipleComponent]
    public sealed class EchoHeroProp : MonoBehaviour
    {
        private const string GripPrimaryName = "GripPrimary";
        private const string GripSecondaryName = "GripSecondary";
        private const string SupportPoseName = "SupportPose";
        private const string LookTargetName = "LookTarget";
        private const string InspectPivotName = "InspectPivot";

        /// <summary>
        /// Shrinks the overlap box so that merely resting on a surface, or
        /// touching a neighbour, does not read as a collision.
        /// </summary>
        private const float OverlapSkinMeters = 0.004f;

        /// <summary>How far below the support patch the resting surface is searched for.</summary>
        private const float SupportProbeMeters = 0.25f;

        /// <summary>Vertical slack tolerated before a grounded-pivot prop is corrected.</summary>
        private const float GroundPinEpsilonMeters = 0.0005f;

        private Transform attachedPalmSocket;
        private float groundContactHeightMeters;
        private Vector3 gripPrimaryLocalPosition;
        private Quaternion gripPrimaryLocalRotation = Quaternion.identity;
        private Transform restParent;
        private Vector3 restLocalPosition;
        private Quaternion restLocalRotation = Quaternion.identity;
        private Vector3 restWorldPosition;
        private Quaternion restWorldRotation = Quaternion.identity;
        private bool hasRestPose;
        private Collider restSupportCollider;

        /// <summary>The authored data this prop was configured from.</summary>
        public EchoInteractionProfile Profile { get; private set; }

        /// <summary>Where the primary hand's palm sits while the prop is held.</summary>
        public Transform GripPrimary { get; private set; }

        /// <summary>The second hand's contact, or null when the profile uses one hand.</summary>
        public Transform GripSecondary { get; private set; }

        /// <summary>The patch where the prop meets the surface it rests on.</summary>
        public Transform SupportPose { get; private set; }

        /// <summary>The point the character's eyes track.</summary>
        public Transform LookTarget { get; private set; }

        /// <summary>The point the prop turns about while it is inspected.</summary>
        public Transform InspectPivot { get; private set; }

        /// <summary>True while the prop is resting on its support surface.</summary>
        public bool IsSupported { get; private set; }

        /// <summary>True while a palm socket owns the prop's pose.</summary>
        public bool IsAttached { get; private set; }

        /// <summary>
        /// Builds the five sockets from the profile, guarantees the prop has a
        /// collider that travels with it, and captures the current pose as the
        /// support pose the prop must return to.
        /// </summary>
        /// <param name="profile">The authored profile for this prop.</param>
        public void Configure(EchoInteractionProfile profile)
        {
            if (profile == null)
            {
                Debug.LogError($"[Echo Interaction] {name} was configured with a null profile.");
                return;
            }

            if (!profile.Validate(out string reason))
            {
                Debug.LogError(
                    $"[Echo Interaction] {name} rejected profile " +
                    $"'{profile.interactionId}': {reason}");
                return;
            }

            Profile = profile;
            GripPrimary = EnsureSocket(
                GripPrimaryName,
                profile.gripPrimaryLocalPosition,
                profile.gripPrimaryLocalEuler);
            if (profile.usesSecondaryHand)
            {
                GripSecondary = EnsureSocket(
                    GripSecondaryName,
                    profile.gripSecondaryLocalPosition,
                    profile.gripSecondaryLocalEuler);
            }
            else
            {
                DestroySocket(transform.Find(GripSecondaryName));
                GripSecondary = null;
            }
            SupportPose = EnsureSocket(
                SupportPoseName,
                profile.supportPoseLocalPosition,
                profile.supportPoseLocalEuler);
            LookTarget = EnsureSocket(LookTargetName, profile.lookTargetLocalPosition, Vector3.zero);
            InspectPivot = EnsureSocket(
                InspectPivotName,
                profile.inspectPivotLocalPosition,
                Vector3.zero);

            // The live socket transform moves with the prop, so the follow solve
            // reads the authored local pose instead of the socket's world pose.
            gripPrimaryLocalPosition = profile.gripPrimaryLocalPosition;
            gripPrimaryLocalRotation = Quaternion.Euler(profile.gripPrimaryLocalEuler);

            EnsureCollider(profile);
            WarnAboutStrayCollision();

            attachedPalmSocket = null;
            IsAttached = false;
            IsSupported = true;
            CaptureRestPose();
        }

        /// <summary>
        /// Records the palm socket that will drive the prop. It deliberately
        /// does not reparent or snap the prop: the reach animation is still
        /// closing the gap, and snapping would hide a bad grip alignment.
        /// </summary>
        /// <param name="palmSocket">The rig's palm socket for the primary hand.</param>
        public void AttachTo(Transform palmSocket)
        {
            if (palmSocket == null)
            {
                Debug.LogError($"[Echo Interaction] {name} cannot attach to a null palm socket.");
                return;
            }

            attachedPalmSocket = palmSocket;
            IsAttached = true;
            IsSupported = false;
        }

        /// <summary>
        /// Clears the attachment and leaves the prop exactly on the support pose
        /// captured by <see cref="CaptureRestPose"/>.
        /// </summary>
        public void Detach()
        {
            attachedPalmSocket = null;
            IsAttached = false;
            IsSupported = true;
            RestoreRestPose();
        }

        /// <summary>
        /// Solves the prop's world pose from the palm socket. Call it after the
        /// rig has evaluated for this frame, otherwise the prop lags the hand by
        /// a frame and the grip error reads as jitter.
        ///
        /// A profile marked <c>staysSupported</c> is pinned to its support pose
        /// no matter what the director does, so props like the tip jar cannot
        /// leave the counter.
        /// </summary>
        public void FollowAttachment()
        {
            if (!IsAttached || attachedPalmSocket == null || Profile == null)
            {
                return;
            }

            if (Profile.staysSupported)
            {
                RestoreRestPose();
                return;
            }

            Quaternion rotation =
                attachedPalmSocket.rotation * Quaternion.Inverse(gripPrimaryLocalRotation);
            if (Profile.keepWorldUp)
            {
                rotation = ClampTiltToWorldUp(rotation, Profile.maxTiltDegrees);
            }

            Vector3 scaledGrip = Vector3.Scale(gripPrimaryLocalPosition, transform.lossyScale);
            Vector3 position = attachedPalmSocket.position - rotation * scaledGrip;
            transform.SetPositionAndRotation(position, rotation);

            if (Profile.groundedPivot)
            {
                PinBaseToGround();
            }
        }

        /// <summary>
        /// Holds a grounded-pivot prop's lowest point on the floor it started on.
        /// The suitcase is carried by its handle and tilts about its base edge,
        /// but it never lifts clear of the ground and never sinks through it.
        /// Applied after the palm-driven pose so the hand still leads the motion;
        /// only the vertical component is corrected, which keeps the grip error
        /// on the tolerated axes rather than fighting the solver.
        /// </summary>
        private void PinBaseToGround()
        {
            if (!TryGetPropBounds(out Bounds bounds))
            {
                return;
            }

            float drop = groundContactHeightMeters - bounds.min.y;
            if (Mathf.Abs(drop) > GroundPinEpsilonMeters)
            {
                transform.position += Vector3.up * drop;
            }
        }

        /// <summary>
        /// Remembers the pose the prop must be returned to, and which collider it
        /// is currently resting on.
        /// </summary>
        public void CaptureRestPose()
        {
            restParent = transform.parent;
            restLocalPosition = transform.localPosition;
            restLocalRotation = transform.localRotation;
            transform.GetPositionAndRotation(out restWorldPosition, out restWorldRotation);
            hasRestPose = true;
            restSupportCollider = ResolveSupportCollider();

            // The floor height a grounded-pivot prop is pinned to is whatever it
            // was actually resting on when the scene was authored, not world zero:
            // the suitcase may sit on a rug rather than bare floor.
            groundContactHeightMeters = TryGetPropBounds(out Bounds restBounds)
                ? restBounds.min.y
                : transform.position.y;
        }

        /// <summary>
        /// Puts the prop back on its captured support pose, position and
        /// rotation both exact. Restoring through the local pose keeps the prop
        /// welded to its scene parent even if the parent has since moved.
        /// </summary>
        public void RestoreRestPose()
        {
            if (!hasRestPose)
            {
                return;
            }

            if (restParent != null && transform.parent == restParent)
            {
                transform.SetLocalPositionAndRotation(restLocalPosition, restLocalRotation);
                return;
            }
            transform.SetPositionAndRotation(restWorldPosition, restWorldRotation);
        }

        /// <summary>
        /// Distance in metres between the live primary grip socket and the palm
        /// socket. This is the acceptance metric, so it measures the real
        /// transforms rather than the pose the solver intended.
        /// </summary>
        /// <param name="palmSocket">The rig's palm socket for the primary hand.</param>
        /// <returns>Metres, or infinity when either socket is missing.</returns>
        public float GripPositionErrorMeters(Transform palmSocket)
        {
            if (palmSocket == null || GripPrimary == null)
            {
                return float.PositiveInfinity;
            }
            return Vector3.Distance(GripPrimary.position, palmSocket.position);
        }

        /// <summary>
        /// Angle in degrees between the live primary grip socket and the palm
        /// socket.
        /// </summary>
        /// <param name="palmSocket">The rig's palm socket for the primary hand.</param>
        /// <returns>Degrees, or infinity when either socket is missing.</returns>
        public float GripAngleErrorDegrees(Transform palmSocket)
        {
            if (palmSocket == null || GripPrimary == null)
            {
                return float.PositiveInfinity;
            }
            return Quaternion.Angle(GripPrimary.rotation, palmSocket.rotation);
        }

        /// <summary>
        /// Reports whether the prop currently intersects scene geometry other
        /// than itself, a trigger volume, or the surface it rests on. The
        /// interaction gate uses this to refuse a reach that would push the prop
        /// through a wall or a neighbouring object.
        /// </summary>
        /// <param name="blockingName">The first blocking collider's name; empty when clear.</param>
        /// <returns>True when something is in the way.</returns>
        public bool OverlapsIgnoringSupport(out string blockingName)
        {
            blockingName = string.Empty;
            if (!TryGetPropBounds(out Bounds bounds))
            {
                return false;
            }

            if (restSupportCollider == null)
            {
                restSupportCollider = ResolveSupportCollider();
            }

            Vector3 extents = bounds.extents - new Vector3(
                OverlapSkinMeters,
                OverlapSkinMeters,
                OverlapSkinMeters);
            extents = Vector3.Max(extents, Vector3.zero);
            Collider[] hits = Physics.OverlapBox(
                bounds.center,
                extents,
                Quaternion.identity,
                Physics.AllLayers,
                QueryTriggerInteraction.Ignore);
            foreach (Collider hit in hits)
            {
                if (hit == null || hit.isTrigger || hit == restSupportCollider)
                {
                    continue;
                }
                if (hit.transform == transform || hit.transform.IsChildOf(transform))
                {
                    continue;
                }

                blockingName = hit.name;
                return true;
            }
            return false;
        }

        private Transform EnsureSocket(string socketName, Vector3 localPosition, Vector3 localEuler)
        {
            Transform socket = transform.Find(socketName);
            if (socket == null)
            {
                socket = new GameObject(socketName).transform;
                socket.SetParent(transform, false);
            }

            socket.localScale = Vector3.one;
            socket.SetLocalPositionAndRotation(localPosition, Quaternion.Euler(localEuler));
            return socket;
        }

        private static void DestroySocket(Transform socket)
        {
            if (socket == null)
            {
                return;
            }

            if (Application.isPlaying)
            {
                Destroy(socket.gameObject);
            }
            else
            {
                DestroyImmediate(socket.gameObject);
            }
        }

        /// <summary>
        /// Guarantees the prop owns a collider. It is added to the prop itself so
        /// it travels with the prop while it is held; collision is never parked
        /// on a scene object that would stay behind.
        /// </summary>
        private void EnsureCollider(EchoInteractionProfile profile)
        {
            if (GetComponentInChildren<Collider>(true) != null)
            {
                return;
            }

            Vector3 scale = transform.lossyScale;
            Vector3 localSize = new(
                SafeDivide(profile.dimensionsMeters.x, scale.x),
                SafeDivide(profile.dimensionsMeters.y, scale.y),
                SafeDivide(profile.dimensionsMeters.z, scale.z));
            BoxCollider box = gameObject.AddComponent<BoxCollider>();
            box.size = localSize;
            // The profile's origin is the centre of the prop's bottom face.
            box.center = new Vector3(0f, localSize.y * 0.5f, 0f);
        }

        /// <summary>
        /// The scale normalization pass parks an auto collider next to the prop
        /// rather than under it. That is fine for static furniture and wrong for
        /// a prop that gets picked up, so say so loudly once at configure time.
        /// </summary>
        private void WarnAboutStrayCollision()
        {
            if (transform.parent == null)
            {
                return;
            }

            Transform stray = transform.parent.Find($"{name}_AutoCollider");
            if (stray != null)
            {
                Debug.LogWarning(
                    $"[Echo Interaction] {name} has a sibling collider '{stray.name}' that will " +
                    "stay behind when the prop is lifted. Build hero prop collision as a child " +
                    "of the prop instead.");
            }
        }

        private Collider ResolveSupportCollider()
        {
            Transform probeFrom = SupportPose != null ? SupportPose : transform;
            Vector3 origin = probeFrom.position + Vector3.up * 0.05f;
            if (Physics.Raycast(
                    origin,
                    Vector3.down,
                    out RaycastHit hit,
                    SupportProbeMeters,
                    Physics.AllLayers,
                    QueryTriggerInteraction.Ignore) &&
                !hit.transform.IsChildOf(transform))
            {
                return hit.collider;
            }
            return null;
        }

        private bool TryGetPropBounds(out Bounds bounds)
        {
            Collider[] colliders = GetComponentsInChildren<Collider>(true);
            bool found = false;
            bounds = new Bounds(transform.position, Vector3.zero);
            foreach (Collider collider in colliders)
            {
                if (collider.isTrigger)
                {
                    continue;
                }

                if (!found)
                {
                    bounds = collider.bounds;
                    found = true;
                }
                else
                {
                    bounds.Encapsulate(collider.bounds);
                }
            }
            return found;
        }

        /// <summary>
        /// Keeps the prop's own up axis within a tilt budget of world up, so a
        /// mug stays drinkable while the wrist rotates underneath it.
        /// </summary>
        private static Quaternion ClampTiltToWorldUp(Quaternion rotation, float maxTiltDegrees)
        {
            Vector3 propUp = rotation * Vector3.up;
            float tilt = Vector3.Angle(propUp, Vector3.up);
            float budget = Mathf.Max(0f, maxTiltDegrees);
            if (tilt <= budget)
            {
                return rotation;
            }

            Vector3 clampedUp = Vector3.RotateTowards(
                Vector3.up,
                propUp,
                budget * Mathf.Deg2Rad,
                0f);
            return Quaternion.FromToRotation(propUp, clampedUp) * rotation;
        }

        private static float SafeDivide(float value, float divisor)
        {
            return Mathf.Abs(divisor) < 0.0001f ? value : value / divisor;
        }
    }
}
