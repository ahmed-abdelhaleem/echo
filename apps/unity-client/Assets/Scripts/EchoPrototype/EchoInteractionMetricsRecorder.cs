using System;
using System.Globalization;
using System.Text;
using UnityEngine;

namespace Echo.FreePrototype
{
    /// <summary>
    /// Measures one interaction take and emits the acceptance numbers the review
    /// gate in <c>docs/15_Interaction_Benchmark.md</c> is written against.
    ///
    /// Every sample is taken from <see cref="EchoCharacterInteractionRig.RigEvaluated"/>,
    /// which fires at the very end of the rig's post-evaluation pass. Sampling in
    /// <c>Update</c> instead would describe the previous frame's pose, and the
    /// grip error would read as a frame of lag rather than as a rig error.
    ///
    /// The recorder never corrects anything it observes. A metric outside its
    /// bound has to fail the gate loudly; clamping or smoothing here would turn a
    /// broken take into a passing one.
    /// </summary>
    [DisallowMultipleComponent]
    public sealed class EchoInteractionMetricsRecorder : MonoBehaviour
    {
        /// <summary>Version of the <c>metrics.json</c> document this recorder writes.</summary>
        public const int SchemaVersion = 1;

        /// <summary>
        /// Foot error above this, at any point in the take, means a foot left the
        /// ground and <c>bothFeetGrounded</c> reports false.
        /// </summary>
        public const float FootGroundedToleranceMeters = 0.02f;

        /// <summary>How far below the support patch the resting surface is searched for.</summary>
        private const float SupportProbeMeters = 0.25f;

        /// <summary>Height above the support patch the resting-surface probe starts at.</summary>
        private const float SupportProbeLiftMeters = 0.05f;

        /// <summary>
        /// Substituted for a non-finite measurement. JSON has no infinity, and a
        /// silently dropped key reads to the gate exactly like a passing take, so
        /// an unmeasurable value is emitted as a number far outside every bound.
        /// </summary>
        private const float NonFiniteSentinel = 999f;

        /// <summary>Fixed decimal format so two identical runs produce identical bytes.</summary>
        private const string MetricFormat = "0.000000";

        private EchoInteractionCoordinator coordinator;
        private EchoHeroProp prop;
        private EchoCharacterInteractionRig rig;
        private EchoCharacterInteractionRig subscribedRig;
        private Collider[] propColliders = Array.Empty<Collider>();
        private Collider restSupportCollider;

        private string takeId = string.Empty;
        private string interactionId = string.Empty;
        private string archetype = string.Empty;
        private float frameDeltaSecondsOverride;

        private Vector3 restWorldPosition;
        private Vector3 previousPropPosition;
        private bool hasPreviousPropPosition;

        private float maxGripPositionErrorMeters;
        private float maxGripAngleErrorDegrees;
        private float maxFootErrorMeters;
        private float maxPropPenetrationMeters;
        private float maxPropSpeedMetersPerSecond;
        private float propMovementBeforeContactMeters;
        private float releasedRestoreErrorMeters;
        private float finalRestoreErrorMeters;

        /// <summary>True between <see cref="BeginTake"/> and <see cref="EndTake"/>.</summary>
        public bool IsRecording { get; private set; }

        /// <summary>The take id this recorder is measuring; empty before the first take.</summary>
        public string TakeId
        {
            get { return takeId; }
        }

        /// <summary>How many rig evaluations were sampled, i.e. how long the take ran.</summary>
        public int FrameCount { get; private set; }

        /// <summary>
        /// Index within this take of the frame the prop attached to the palm, or -1
        /// when it never attached. Take-relative rather than <c>Time.frameCount</c>,
        /// so it indexes the rendered <c>frame_%05d.png</c> sequence directly.
        /// </summary>
        public int AttachFrame { get; private set; } = -1;

        /// <summary>
        /// Index within this take of the frame the prop was released back onto its
        /// support, or -1 when it was never released.
        /// </summary>
        public int ReleaseFrame { get; private set; } = -1;

        /// <summary>Worst palm-to-grip distance seen while the hand owned the prop.</summary>
        public float GripPositionErrorMeters
        {
            get { return maxGripPositionErrorMeters; }
        }

        /// <summary>Worst palm-to-grip angle seen while the hand owned the prop.</summary>
        public float GripAngleErrorDegrees
        {
            get { return maxGripAngleErrorDegrees; }
        }

        /// <summary>Worst foot-to-ground error seen over the whole take.</summary>
        public float FootErrorMeters
        {
            get { return maxFootErrorMeters; }
        }

        /// <summary>Deepest measured intersection of the prop with foreign geometry.</summary>
        public float PropPenetrationMeters
        {
            get { return maxPropPenetrationMeters; }
        }

        /// <summary>Fastest the prop travelled, in metres per second.</summary>
        public float MaxPropSpeedMetersPerSecond
        {
            get { return maxPropSpeedMetersPerSecond; }
        }

        /// <summary>
        /// Total distance the prop travelled before the hand reached it. This is the
        /// regression gate for the old floating behaviour: the prop is stationary
        /// until contact, so anything but zero here means the object started moving
        /// on a timer instead of because a hand arrived.
        /// </summary>
        public float PropMovementBeforeContactMeters
        {
            get { return propMovementBeforeContactMeters; }
        }

        /// <summary>
        /// How far the prop ended up from the pose it was picked up off. Measured as
        /// the worse of the pose the hand let go at and the pose the take ended on,
        /// because the release path snaps the prop back onto the captured rest pose
        /// and the end-of-take distance alone would therefore always read zero.
        /// </summary>
        public float SupportRestoreErrorMeters
        {
            get { return Mathf.Max(releasedRestoreErrorMeters, finalRestoreErrorMeters); }
        }

        /// <summary>True when the foot error stayed inside its tolerance all take.</summary>
        public bool BothFeetGrounded
        {
            get { return maxFootErrorMeters <= FootGroundedToleranceMeters; }
        }

        /// <summary>
        /// Clears every accumulator and starts sampling. Call it once the
        /// coordinator has been configured against the rig and the prop is sitting
        /// still on its support, but before the interaction begins: the pose the
        /// prop holds now is the rest pose every restore metric is measured from,
        /// and the first frame of movement is measured from it too.
        ///
        /// Call order matters. The coordinator subscribes to
        /// <see cref="EchoCharacterInteractionRig.RigEvaluated"/> in its own
        /// <c>Configure</c>, so subscribing after it means the coordinator has
        /// already driven the prop from the palm by the time this recorder samples.
        /// </summary>
        /// <param name="interactionCoordinator">The coordinator running the take.</param>
        /// <param name="heroProp">The prop being handled.</param>
        /// <param name="characterRig">The rig whose evaluation drives sampling.</param>
        /// <param name="takeIdentifier">Take id, echoed into the emitted document.</param>
        /// <param name="frameDeltaSeconds">
        /// Seconds per captured frame. Pass the capture's fixed step so the speed
        /// metric is independent of how fast the editor actually ran; pass zero to
        /// fall back to <c>Time.captureDeltaTime</c> and then <c>Time.deltaTime</c>.
        /// </param>
        public void BeginTake(
            EchoInteractionCoordinator interactionCoordinator,
            EchoHeroProp heroProp,
            EchoCharacterInteractionRig characterRig,
            string takeIdentifier,
            float frameDeltaSeconds)
        {
            EndTake();
            ResetAccumulators();
            takeId = takeIdentifier ?? string.Empty;

            if (interactionCoordinator == null || heroProp == null || characterRig == null)
            {
                Debug.LogError(
                    $"[Echo Capture] Take '{takeId}' cannot be measured: it needs a coordinator, " +
                    "a hero prop and a built interaction rig.");
                return;
            }

            if (heroProp.Profile == null)
            {
                Debug.LogError(
                    $"[Echo Capture] Take '{takeId}' cannot be measured: {heroProp.name} has no " +
                    "profile. Call EchoHeroProp.Configure before starting a take.");
                return;
            }

            coordinator = interactionCoordinator;
            prop = heroProp;
            rig = characterRig;
            interactionId = heroProp.Profile.interactionId ?? string.Empty;
            archetype = heroProp.Profile.archetype ?? string.Empty;
            frameDeltaSecondsOverride = Mathf.Max(0f, frameDeltaSeconds);

            propColliders = heroProp.GetComponentsInChildren<Collider>(true);
            restSupportCollider = ResolveSupportCollider();
            restWorldPosition = heroProp.transform.position;
            previousPropPosition = restWorldPosition;
            hasPreviousPropPosition = true;

            Subscribe();
            IsRecording = true;
        }

        /// <summary>
        /// Stops sampling and freezes the take's numbers. The distance between the
        /// prop's pose right now and its captured rest pose folds into
        /// <see cref="SupportRestoreErrorMeters"/>. Safe to call more than once.
        /// </summary>
        public void EndTake()
        {
            if (!IsRecording)
            {
                Unsubscribe();
                return;
            }

            if (prop != null)
            {
                finalRestoreErrorMeters =
                    Vector3.Distance(prop.transform.position, restWorldPosition);
            }

            Unsubscribe();
            IsRecording = false;
        }

        /// <summary>
        /// Serialises the take as the <c>metrics.json</c> document the capture gate
        /// in <c>tools/capture/encode_interaction_capture.py</c> reads. Every key it
        /// gates on is always present: a missing key there fails the take, which is
        /// the correct outcome for a take nobody measured.
        ///
        /// Numbers are written with a fixed invariant format so two runs of the same
        /// capture produce byte-identical files.
        /// </summary>
        /// <returns>A JSON object with a trailing newline.</returns>
        public string ToJson()
        {
            StringBuilder builder = new();
            builder.Append("{\n");
            AppendInt(builder, "schemaVersion", SchemaVersion);
            AppendString(builder, "takeId", takeId);
            AppendString(builder, "interactionId", interactionId);
            AppendString(builder, "archetype", archetype);
            AppendInt(builder, "frameCount", FrameCount);
            AppendFloat(builder, "gripPositionErrorMeters", maxGripPositionErrorMeters);
            AppendFloat(builder, "gripAngleErrorDegrees", maxGripAngleErrorDegrees);
            AppendFloat(builder, "footErrorMeters", maxFootErrorMeters);
            AppendFloat(builder, "propPenetrationMeters", maxPropPenetrationMeters);
            AppendFloat(builder, "supportRestoreErrorMeters", SupportRestoreErrorMeters);
            AppendFloat(builder, "maxPropSpeedMetersPerSecond", maxPropSpeedMetersPerSecond);
            AppendFloat(
                builder,
                "propMovementBeforeContactMeters",
                propMovementBeforeContactMeters);
            AppendInt(builder, "attachFrame", AttachFrame);
            AppendInt(builder, "releaseFrame", ReleaseFrame);
            AppendBool(builder, "bothFeetGrounded", BothFeetGrounded, true);
            builder.Append("}\n");
            return builder.ToString();
        }

        private void OnDisable()
        {
            EndTake();
        }

        private void OnDestroy()
        {
            Unsubscribe();
        }

        /// <summary>
        /// One sample, taken after the rig solved and after the coordinator drove
        /// the prop from the palm for this frame.
        /// </summary>
        private void HandleRigEvaluated()
        {
            if (!IsRecording || prop == null || coordinator == null || rig == null)
            {
                return;
            }

            Physics.SyncTransforms();

            int frameIndex = FrameCount;
            FrameCount++;

            SampleContactFrames(frameIndex);
            SamplePropMotion();
            SampleGrip();
            SampleFoot();
            SamplePenetration();
            SampleReleasedRestore();
        }

        /// <summary>
        /// Converts the coordinator's <c>Time.frameCount</c> markers into indices
        /// within this take, so they line up with the rendered PNG sequence.
        /// </summary>
        private void SampleContactFrames(int frameIndex)
        {
            if (AttachFrame < 0 && coordinator.AttachFrameIndex >= 0)
            {
                AttachFrame = frameIndex;
            }
            if (ReleaseFrame < 0 && coordinator.ReleaseFrameIndex >= 0)
            {
                ReleaseFrame = frameIndex;
            }
        }

        /// <summary>
        /// Accumulates how far the prop travelled this frame. The before-contact
        /// total is a running sum rather than a start-to-attach snapshot, so a prop
        /// that wanders away and comes back is still caught.
        /// </summary>
        private void SamplePropMotion()
        {
            Vector3 position = prop.transform.position;
            if (!hasPreviousPropPosition)
            {
                previousPropPosition = position;
                hasPreviousPropPosition = true;
                return;
            }

            float travelled = Vector3.Distance(position, previousPropPosition);
            previousPropPosition = position;

            float delta = ResolveFrameDeltaSeconds();
            if (delta > 0f)
            {
                maxPropSpeedMetersPerSecond =
                    Mathf.Max(maxPropSpeedMetersPerSecond, travelled / delta);
            }

            // The attach frame itself already belongs to contact: the palm owns the
            // prop by the time this runs, so its snap onto the grip is not counted
            // as movement the hand had not yet caused.
            if (!HasContacted())
            {
                propMovementBeforeContactMeters += travelled;
            }
        }

        private void SampleGrip()
        {
            if (!IsHandOnGrip())
            {
                return;
            }

            Transform palm = rig.PalmSocket(coordinator.ActiveHand);
            if (palm == null)
            {
                return;
            }

            maxGripPositionErrorMeters = Mathf.Max(
                maxGripPositionErrorMeters,
                prop.GripPositionErrorMeters(palm));
            maxGripAngleErrorDegrees = Mathf.Max(
                maxGripAngleErrorDegrees,
                prop.GripAngleErrorDegrees(palm));
        }

        private void SampleFoot()
        {
            maxFootErrorMeters = Mathf.Max(maxFootErrorMeters, rig.FootErrorMeters);
        }

        /// <summary>
        /// Measures how deeply the prop is inside foreign geometry rather than only
        /// whether it touches any. A bool answers "is this take broken"; a depth
        /// answers "by how much", which is what a reviewer needs to triage it.
        ///
        /// The prop's own colliders and the surface it rests on are excluded: a prop
        /// standing on a table shares a face with the table by construction.
        /// </summary>
        private void SamplePenetration()
        {
            foreach (Collider own in propColliders)
            {
                if (own == null || own.isTrigger || !own.enabled)
                {
                    continue;
                }

                Bounds bounds = own.bounds;
                Collider[] candidates = Physics.OverlapBox(
                    bounds.center,
                    bounds.extents,
                    Quaternion.identity,
                    Physics.AllLayers,
                    QueryTriggerInteraction.Ignore);
                foreach (Collider other in candidates)
                {
                    if (!IsForeignCollider(other))
                    {
                        continue;
                    }

                    if (Physics.ComputePenetration(
                            own,
                            own.transform.position,
                            own.transform.rotation,
                            other,
                            other.transform.position,
                            other.transform.rotation,
                            out Vector3 _,
                            out float depth))
                    {
                        maxPropPenetrationMeters = Mathf.Max(maxPropPenetrationMeters, depth);
                    }
                }
            }
        }

        /// <summary>
        /// Records how far the prop was from its rest pose on the last frame the
        /// hand still owned it. The coordinator restores the captured pose exactly
        /// when it releases, so this is the only frame on which the restore error is
        /// still a measurement of the hand's motion rather than of an assignment.
        /// </summary>
        private void SampleReleasedRestore()
        {
            if (!prop.IsAttached)
            {
                return;
            }

            releasedRestoreErrorMeters = Vector3.Distance(
                prop.transform.position,
                restWorldPosition);
        }

        /// <summary>
        /// True once the hand has met the prop. A <c>staysSupported</c> prop is
        /// never attached to a palm at all, so its contact is read off the phase the
        /// coordinator is in instead.
        /// </summary>
        private bool HasContacted()
        {
            if (coordinator.AttachFrameIndex >= 0 || prop.IsAttached)
            {
                return true;
            }
            return IsSupportedContactPhase();
        }

        /// <summary>
        /// True while the palm is expected to be sitting on the grip, which is the
        /// window the grip error is an acceptance metric over.
        /// </summary>
        private bool IsHandOnGrip()
        {
            return prop.IsAttached || IsSupportedContactPhase();
        }

        private bool IsSupportedContactPhase()
        {
            EchoInteractionProfile profile = prop.Profile;
            if (profile == null || !profile.staysSupported)
            {
                return false;
            }

            EchoInteractionState state = coordinator.State;
            return state == EchoInteractionState.Contact ||
                state == EchoInteractionState.Hold ||
                state == EchoInteractionState.Return;
        }

        private bool IsForeignCollider(Collider candidate)
        {
            if (candidate == null || candidate.isTrigger || candidate == restSupportCollider)
            {
                return false;
            }
            if (prop == null)
            {
                return false;
            }
            return candidate.transform != prop.transform &&
                !candidate.transform.IsChildOf(prop.transform);
        }

        /// <summary>
        /// Finds the collider the prop is resting on, the same way
        /// <see cref="EchoHeroProp"/> does, by probing straight down from the
        /// support patch. Resolved once at the start of the take, while the prop is
        /// guaranteed to still be on its support.
        /// </summary>
        private Collider ResolveSupportCollider()
        {
            Transform probeFrom = prop.SupportPose != null ? prop.SupportPose : prop.transform;
            Vector3 origin = probeFrom.position + Vector3.up * SupportProbeLiftMeters;
            if (Physics.Raycast(
                    origin,
                    Vector3.down,
                    out RaycastHit hit,
                    SupportProbeMeters,
                    Physics.AllLayers,
                    QueryTriggerInteraction.Ignore) &&
                !hit.transform.IsChildOf(prop.transform))
            {
                return hit.collider;
            }
            return null;
        }

        private float ResolveFrameDeltaSeconds()
        {
            if (frameDeltaSecondsOverride > 0f)
            {
                return frameDeltaSecondsOverride;
            }
            if (Time.captureDeltaTime > 0f)
            {
                return Time.captureDeltaTime;
            }
            return Time.deltaTime;
        }

        private void ResetAccumulators()
        {
            coordinator = null;
            prop = null;
            rig = null;
            propColliders = Array.Empty<Collider>();
            restSupportCollider = null;
            takeId = string.Empty;
            interactionId = string.Empty;
            archetype = string.Empty;
            frameDeltaSecondsOverride = 0f;
            restWorldPosition = Vector3.zero;
            previousPropPosition = Vector3.zero;
            hasPreviousPropPosition = false;
            FrameCount = 0;
            AttachFrame = -1;
            ReleaseFrame = -1;
            maxGripPositionErrorMeters = 0f;
            maxGripAngleErrorDegrees = 0f;
            maxFootErrorMeters = 0f;
            maxPropPenetrationMeters = 0f;
            maxPropSpeedMetersPerSecond = 0f;
            propMovementBeforeContactMeters = 0f;
            releasedRestoreErrorMeters = 0f;
            finalRestoreErrorMeters = 0f;
        }

        private void Subscribe()
        {
            if (rig == null || subscribedRig == rig)
            {
                return;
            }

            rig.RigEvaluated += HandleRigEvaluated;
            subscribedRig = rig;
        }

        private void Unsubscribe()
        {
            if (subscribedRig == null)
            {
                return;
            }

            subscribedRig.RigEvaluated -= HandleRigEvaluated;
            subscribedRig = null;
        }

        private static void AppendInt(StringBuilder builder, string key, int value)
        {
            builder.Append("  \"").Append(key).Append("\": ")
                .Append(value.ToString(CultureInfo.InvariantCulture))
                .Append(",\n");
        }

        private static void AppendBool(StringBuilder builder, string key, bool value, bool isLast)
        {
            builder.Append("  \"").Append(key).Append("\": ")
                .Append(value ? "true" : "false")
                .Append(isLast ? "\n" : ",\n");
        }

        private static void AppendString(StringBuilder builder, string key, string value)
        {
            builder.Append("  \"").Append(key).Append("\": \"").Append(Escape(value))
                .Append("\",\n");
        }

        private static void AppendFloat(StringBuilder builder, string key, float value)
        {
            bool measurable = !float.IsNaN(value) && !float.IsInfinity(value);
            float finite = measurable ? value : NonFiniteSentinel;
            builder.Append("  \"").Append(key).Append("\": ")
                .Append(finite.ToString(MetricFormat, CultureInfo.InvariantCulture))
                .Append(",\n");
        }

        private static string Escape(string value)
        {
            if (string.IsNullOrEmpty(value))
            {
                return string.Empty;
            }

            StringBuilder escaped = new(value.Length);
            foreach (char character in value)
            {
                switch (character)
                {
                    case '"':
                        escaped.Append("\\\"");
                        break;
                    case '\\':
                        escaped.Append("\\\\");
                        break;
                    case '\n':
                        escaped.Append("\\n");
                        break;
                    case '\r':
                        escaped.Append("\\r");
                        break;
                    case '\t':
                        escaped.Append("\\t");
                        break;
                    default:
                        escaped.Append(character);
                        break;
                }
            }
            return escaped.ToString();
        }
    }
}
