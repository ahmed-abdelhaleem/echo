using System;
using System.Collections.Generic;
using UnityEngine;

namespace Echo.FreePrototype
{
    /// <summary>
    /// The ordered phases of a hero-prop interaction. The order in this enum is
    /// the order the coordinator walks, and nothing skips ahead: every phase is
    /// entered from the one above it and left for the one below it, with
    /// <see cref="Idle"/> closing the loop after <see cref="Recover"/>.
    /// </summary>
    public enum EchoInteractionState
    {
        /// <summary>Nothing is running; locomotion belongs to the player.</summary>
        Idle,

        /// <summary>Profile, prop, station, path and reachability are being checked.</summary>
        Validate,

        /// <summary>The prop and station are claimed and their rest poses recorded.</summary>
        Reserve,

        /// <summary>Player locomotion and further interactions are shut off.</summary>
        LockLocomotion,

        /// <summary>The character turns and steps onto a legal approach pose.</summary>
        Align,

        /// <summary>The hand travels to the stationary prop; the prop does not move.</summary>
        Reach,

        /// <summary>Arm IK finishes ramping to full weight and the grip error is checked.</summary>
        RampIkIn,

        /// <summary>The prop is attached to the palm and settles into the inspected pose.</summary>
        Contact,

        /// <summary>The inspected pose is held.</summary>
        Hold,

        /// <summary>The hand carries the prop back onto its support pose.</summary>
        Return,

        /// <summary>The prop is released and restored to its captured support pose.</summary>
        Support,

        /// <summary>Arm and gaze IK ramp back out to the animated pose.</summary>
        RampIkOut,

        /// <summary>Locomotion is handed back and the interaction is cleared.</summary>
        Recover
    }

    /// <summary>
    /// The two moments an interaction has to be told about rather than guess:
    /// the frame the hand actually meets the prop, and the frame the prop
    /// actually meets its support again.
    /// </summary>
    public enum EchoContactEvent
    {
        /// <summary>The hand has arrived on the grip and may take the prop.</summary>
        ReachContact,

        /// <summary>The prop is back on its support and may be released.</summary>
        SupportContact
    }

    /// <summary>
    /// The seam between the interaction state machine and whatever knows when
    /// contact happens. Today that is the authored profile timings
    /// (<see cref="EchoTimedContactSignal"/>); once real clips with animation
    /// events exist it becomes <see cref="EchoAnimationEventContactSignal"/>
    /// without the state machine changing at all.
    /// </summary>
    public interface IEchoContactSignal
    {
        /// <summary>
        /// True once the armed contact moment has happened. Meaningless until
        /// <see cref="Arm"/> has been called.
        /// </summary>
        bool HasFired { get; }

        /// <summary>
        /// Best available estimate of how far the current phase has progressed,
        /// in 0..1. Used to shape the IK ramp and to report a HUD value; it is
        /// never what decides that contact happened.
        /// </summary>
        float Progress { get; }

        /// <summary>
        /// Prepares the signal for one contact moment and clears any earlier fire.
        /// </summary>
        /// <param name="profile">The profile being played, for its timings.</param>
        /// <param name="expectedEvent">Which contact moment is being waited on.</param>
        void Arm(EchoInteractionProfile profile, EchoContactEvent expectedEvent);

        /// <summary>Cancels the wait and clears every pending fire.</summary>
        void Disarm();

        /// <summary>
        /// Advances the signal by one frame. Implementations that fire on an
        /// external event still use this to keep <see cref="Progress"/> honest.
        /// </summary>
        /// <param name="deltaTime">Seconds since the previous tick.</param>
        void Tick(float deltaTime);
    }

    /// <summary>
    /// Fires contact purely from the authored profile timings. This is what the
    /// prototype runs on, because no authored clip carries contact events yet.
    /// It is a plain class, not a component: it has no scene presence.
    /// </summary>
    public sealed class EchoTimedContactSignal : IEchoContactSignal
    {
        private const float FallbackDurationSeconds = 0.5f;

        private float duration;
        private float elapsed;
        private bool armed;

        /// <inheritdoc />
        public bool HasFired
        {
            get { return armed && elapsed >= duration; }
        }

        /// <inheritdoc />
        public float Progress
        {
            get
            {
                if (!armed)
                {
                    return 0f;
                }
                if (duration <= 0f)
                {
                    return 1f;
                }
                return Mathf.Clamp01(elapsed / duration);
            }
        }

        /// <inheritdoc />
        public void Arm(EchoInteractionProfile profile, EchoContactEvent expectedEvent)
        {
            duration = DurationFor(profile, expectedEvent);
            elapsed = 0f;
            armed = true;
        }

        /// <inheritdoc />
        public void Disarm()
        {
            armed = false;
            elapsed = 0f;
            duration = 0f;
        }

        /// <inheritdoc />
        public void Tick(float deltaTime)
        {
            if (!armed)
            {
                return;
            }
            elapsed += Mathf.Max(0f, deltaTime);
        }

        /// <summary>
        /// The authored duration of the phase that leads up to a contact moment.
        /// </summary>
        /// <param name="profile">The profile being played; null yields a safe default.</param>
        /// <param name="expectedEvent">Which contact moment is being waited on.</param>
        /// <returns>Seconds the phase is expected to take.</returns>
        internal static float DurationFor(
            EchoInteractionProfile profile,
            EchoContactEvent expectedEvent)
        {
            if (profile == null)
            {
                return FallbackDurationSeconds;
            }
            return expectedEvent == EchoContactEvent.ReachContact
                ? Mathf.Max(0.01f, profile.reachSeconds)
                : Mathf.Max(0.01f, profile.returnSeconds);
        }
    }

    /// <summary>
    /// Fires contact from AnimationEvents on the character's own clips. Add this
    /// component next to the Animator and point the events at
    /// <see cref="OnReachContact"/> and <see cref="OnSupportContact"/> by name.
    ///
    /// Progress is still estimated from the profile timings so the IK ramp has
    /// something to follow, but it is never what fires the signal. A watchdog
    /// fires anyway once the phase has run several times longer than authored,
    /// so a clip that is missing its event stalls the look of the interaction
    /// rather than deadlocking the state machine.
    /// </summary>
    [DisallowMultipleComponent]
    public sealed class EchoAnimationEventContactSignal : MonoBehaviour, IEchoContactSignal
    {
        private const float WatchdogMultiplier = 3f;

        private EchoContactEvent expectedEvent;
        private float expectedDuration;
        private float elapsed;
        private bool armed;
        private bool reachFired;
        private bool supportFired;
        private bool watchdogReported;

        /// <inheritdoc />
        public bool HasFired
        {
            get
            {
                if (!armed)
                {
                    return false;
                }
                if (expectedEvent == EchoContactEvent.ReachContact ? reachFired : supportFired)
                {
                    return true;
                }
                return HasWatchdogExpired();
            }
        }

        /// <inheritdoc />
        public float Progress
        {
            get
            {
                if (!armed)
                {
                    return 0f;
                }
                if (expectedEvent == EchoContactEvent.ReachContact ? reachFired : supportFired)
                {
                    return 1f;
                }
                if (expectedDuration <= 0f)
                {
                    return 1f;
                }
                return Mathf.Clamp01(elapsed / expectedDuration);
            }
        }

        /// <summary>
        /// Called by an AnimationEvent on the frame the reaching hand touches the
        /// prop. Safe to call when nothing is armed; the flag is cleared by the
        /// next <see cref="Arm"/>.
        /// </summary>
        public void OnReachContact()
        {
            reachFired = true;
        }

        /// <summary>
        /// Called by an AnimationEvent on the frame the prop settles back onto its
        /// support and may be released.
        /// </summary>
        public void OnSupportContact()
        {
            supportFired = true;
        }

        /// <inheritdoc />
        public void Arm(EchoInteractionProfile profile, EchoContactEvent contactEvent)
        {
            expectedEvent = contactEvent;
            expectedDuration = EchoTimedContactSignal.DurationFor(profile, contactEvent);
            elapsed = 0f;
            armed = true;
            reachFired = false;
            supportFired = false;
            watchdogReported = false;
        }

        /// <inheritdoc />
        public void Disarm()
        {
            armed = false;
            elapsed = 0f;
            reachFired = false;
            supportFired = false;
        }

        /// <inheritdoc />
        public void Tick(float deltaTime)
        {
            if (!armed)
            {
                return;
            }
            elapsed += Mathf.Max(0f, deltaTime);
        }

        private bool HasWatchdogExpired()
        {
            if (expectedDuration <= 0f || elapsed < expectedDuration * WatchdogMultiplier)
            {
                return false;
            }

            if (!watchdogReported)
            {
                watchdogReported = true;
                Debug.LogWarning(
                    $"[Echo Interaction] No {expectedEvent} animation event arrived on " +
                    $"'{name}' within {expectedDuration * WatchdogMultiplier:0.00}s. The " +
                    "interaction continued on the watchdog; add the event to the clip.");
            }
            return true;
        }
    }

    /// <summary>
    /// The single authoritative state machine for hero-prop interactions.
    ///
    /// <para>
    /// The rules it exists to enforce, in order of how easy they are to break:
    /// the hand moves to a stationary prop and never the other way round; the
    /// prop starts following the palm only once contact has been declared; that
    /// following happens inside <see cref="EchoCharacterInteractionRig.RigEvaluated"/>,
    /// after the animation graph and every constraint have solved for the frame,
    /// so the prop is never a frame behind the hand; the prop is released only
    /// once it is back on its captured support pose; and locomotion plus repeat
    /// input stay locked from <see cref="EchoInteractionState.Reserve"/> until
    /// <see cref="EchoInteractionState.Recover"/> completes.
    /// </para>
    /// <para>
    /// The machine is driven from <c>Update</c> on purpose. Every IK goal it
    /// writes has to be in place before <see cref="EchoMixamoCharacter"/>
    /// evaluates the graph in <c>LateUpdate</c>, and Unity guarantees Update
    /// ordering against LateUpdate without needing a script execution order asset.
    /// Targets are therefore authored from last frame's bone poses, which is
    /// correct: they are goals, not results. The prop's own pose is solved after
    /// the evaluation and carries no lag at all.
    /// </para>
    /// </summary>
    [DisallowMultipleComponent]
    public sealed class EchoInteractionCoordinator : MonoBehaviour
    {
        /// <summary>What one interaction id resolves to in the scene.</summary>
        private sealed class Registration
        {
            public EchoHeroProp Prop;
            public EchoInteractionStation Station;
        }

        /// <summary>Weight the arm reaches at the end of <see cref="EchoInteractionState.Reach"/>.</summary>
        private const float ReachEndWeight = 0.9f;

        /// <summary>Seconds spent finishing the arm weight once the hand is on the grip.</summary>
        private const float RampIkInSeconds = 0.15f;

        /// <summary>How long the grip is allowed to keep settling before it is accepted anyway.</summary>
        private const float GripSettleTimeoutSeconds = 0.5f;

        /// <summary>How long the body is allowed to keep settling after the align travel.</summary>
        private const float AlignSettleTimeoutSeconds = 0.6f;

        /// <summary>Foot error that still counts as "the character has settled".</summary>
        private const float AlignSettleFootToleranceMeters = 0.05f;

        /// <summary>Distance from the stand point that counts as arrived.</summary>
        private const float StandPositionToleranceMeters = 0.06f;

        /// <summary>Facing error that counts as arrived.</summary>
        private const float StandAngleToleranceDegrees = 7f;

        /// <summary>Per-frame root motion under which the body counts as still.</summary>
        private const float StillnessToleranceMeters = 0.004f;

        /// <summary>Travel below which the approach sweep is skipped as a no-op.</summary>
        private const float MinimumApproachTravelMeters = 0.05f;

        /// <summary>Gap left between the swept capsule and whatever stopped it.</summary>
        private const float SweepContactOffsetMeters = 0.03f;

        /// <summary>
        /// How much farther than planned an obstructed approach may leave the
        /// character standing before the interaction is refused outright.
        /// </summary>
        private const float ApproachSlackMeters = 0.12f;

        /// <summary>Rise of the hand's approach arc, so it does not scrape the surface.</summary>
        private const float ReachArcMeters = 0.03f;

        /// <summary>Yaw budget for turning a prop that never leaves its support.</summary>
        private const float SupportedTurnLimitDegrees = 14f;

        /// <summary>Yaw budget for turning a prop that is held in the hand.</summary>
        private const float HeldTurnLimitDegrees = 150f;

        /// <summary>Pitch budget for tipping a held prop that has no world-up rule.</summary>
        private const float HeldPitchLimitDegrees = 60f;

        /// <summary>Capsule radius used when the character has no CharacterController.</summary>
        private const float FallbackSweepRadiusMeters = 0.28f;

        private const int SweepBufferSize = 12;

        private readonly Dictionary<string, Registration> registrations = new();
        private readonly RaycastHit[] sweepBuffer = new RaycastHit[SweepBufferSize];

        private EchoCharacterInteractionRig rig;
        private EchoCharacterInteractionRig subscribedRig;
        private Transform characterRoot;
        private CharacterController characterCollision;
        private EchoThirdPersonController locomotion;
        private IEchoContactSignal contactSignal = new EchoTimedContactSignal();
        private bool locomotionWasEnabled = true;

        private EchoHeroProp activeProp;
        private EchoInteractionStation activeStation;
        private EchoInteractionProfile activeProfile;
        private EchoHand primaryHand;
        private EchoHand secondaryHand;

        private Vector3 alignStartPosition;
        private Quaternion alignStartRotation = Quaternion.identity;
        private Vector3 alignTargetPosition;
        private Quaternion alignTargetRotation = Quaternion.identity;
        private Vector3 previousRootPosition;

        private Vector3 restPropPosition;
        private Quaternion restPropRotation = Quaternion.identity;
        private Vector3 restGripPosition;
        private Quaternion restGripRotation = Quaternion.identity;

        private Vector3 reachStartPalmPosition;
        private Quaternion reachStartPalmRotation = Quaternion.identity;
        private Vector3 contactPalmPosition;
        private Quaternion contactPalmRotation = Quaternion.identity;
        private Vector3 holdPropLocalPosition;
        private Quaternion holdPropLocalRotation = Quaternion.identity;
        private Vector3 returnStartPalmPosition;
        private Quaternion returnStartPalmRotation = Quaternion.identity;

        private float inspectYawDegrees;
        private float inspectPitchDegrees;
        private float returnStartInspectYaw;
        private float returnStartInspectPitch;

        private float phaseElapsed;
        private float lookWeight;
        private float primaryWeight;
        private float secondaryWeight;
        private float gripPositionError = float.PositiveInfinity;
        private float gripAngleError = float.PositiveInfinity;

        /// <summary>
        /// Raised every time the machine enters a new phase, including the
        /// instantaneous phases that complete inside <see cref="TryBegin"/>.
        /// </summary>
        public event Action<EchoInteractionState> StateChanged;

        /// <summary>The phase the machine is in right now.</summary>
        public EchoInteractionState State { get; private set; } = EchoInteractionState.Idle;

        /// <summary>The interaction id being played, or an empty string when idle.</summary>
        public string ActiveInteractionId { get; private set; } = string.Empty;

        /// <summary>
        /// True from the moment <see cref="TryBegin"/> reserves an interaction until
        /// <see cref="EchoInteractionState.Recover"/> completes. Locomotion is locked
        /// and further <see cref="TryBegin"/> calls are refused for exactly this window.
        /// </summary>
        public bool IsBusy
        {
            get { return State != EchoInteractionState.Idle; }
        }

        /// <summary>The profile of the running interaction, or null when idle.</summary>
        public EchoInteractionProfile ActiveProfile
        {
            get { return activeProfile; }
        }

        /// <summary>The prop of the running interaction, or null when idle.</summary>
        public EchoHeroProp ActiveProp
        {
            get { return activeProp; }
        }

        /// <summary>The station of the running interaction, or null when idle.</summary>
        public EchoInteractionStation ActiveStation
        {
            get { return activeStation; }
        }

        /// <summary>The hand that owns the grip of the running interaction.</summary>
        public EchoHand ActiveHand
        {
            get { return primaryHand; }
        }

        /// <summary>The rig this coordinator drives; null until <see cref="Configure"/>.</summary>
        public EchoCharacterInteractionRig Rig
        {
            get { return rig; }
        }

        /// <summary>The character root this coordinator moves; null until <see cref="Configure"/>.</summary>
        public Transform CharacterRoot
        {
            get { return characterRoot; }
        }

        /// <summary>
        /// The signal that decides when contact happens. Swapping it changes how
        /// phases advance without touching the state machine; it is refused while
        /// an interaction is running so a swap cannot corrupt a live phase.
        /// </summary>
        public IEchoContactSignal ContactSignal
        {
            get { return contactSignal; }
            set
            {
                if (IsBusy)
                {
                    Debug.LogWarning(
                        "[Echo Interaction] The contact signal cannot be swapped while " +
                        $"'{ActiveInteractionId}' is running; the request was ignored.");
                    return;
                }
                contactSignal = value ?? new EchoTimedContactSignal();
            }
        }

        /// <summary>
        /// Distance in metres between the palm socket and the primary grip socket,
        /// measured after the rig solved this frame. Infinity while idle.
        /// </summary>
        public float GripPositionErrorMeters
        {
            get { return gripPositionError; }
        }

        /// <summary>
        /// Angle in degrees between the palm socket and the primary grip socket,
        /// measured after the rig solved this frame. Infinity while idle.
        /// </summary>
        public float GripAngleErrorDegrees
        {
            get { return gripAngleError; }
        }

        /// <summary>Worst foot-to-ground error reported by the rig this frame.</summary>
        public float FootErrorMeters
        {
            get { return rig != null ? rig.FootErrorMeters : 0f; }
        }

        /// <summary>Live arm IK weight of the hand that owns the grip.</summary>
        public float PrimaryHandWeight
        {
            get { return rig != null && rig.IsBuilt ? rig.GetHandWeight(primaryHand) : primaryWeight; }
        }

        /// <summary>Live arm IK weight of the supporting hand.</summary>
        public float SecondaryHandWeight
        {
            get { return rig != null && rig.IsBuilt ? rig.GetHandWeight(secondaryHand) : secondaryWeight; }
        }

        /// <summary>Live gaze weight.</summary>
        public float LookWeight
        {
            get { return lookWeight; }
        }

        /// <summary>
        /// True when the prop currently intersects something other than itself and
        /// the surface it rests on, sampled after the rig solved this frame.
        /// </summary>
        public bool IsColliding { get; private set; }

        /// <summary>Name of the first collider behind <see cref="IsColliding"/>; empty when clear.</summary>
        public string CollisionBlockerName { get; private set; } = string.Empty;

        /// <summary>Progress through the current phase in 0..1; zero while idle.</summary>
        public float PhaseProgress { get; private set; }

        /// <summary>
        /// <c>Time.frameCount</c> of the frame the prop was attached to the palm, or
        /// -1 when no attach has happened. A <c>staysSupported</c> profile never
        /// attaches, so it keeps -1 for the whole interaction by design.
        /// </summary>
        public int AttachFrameIndex { get; private set; } = -1;

        /// <summary>
        /// <c>Time.frameCount</c> of the frame the prop was released back onto its
        /// support, or -1 when no release has happened.
        /// </summary>
        public int ReleaseFrameIndex { get; private set; } = -1;

        /// <summary>
        /// True while the machine will act on <see cref="SetInspectOffset"/>, i.e.
        /// while the prop is in contact with the hand and not yet released.
        /// </summary>
        public bool AcceptsInspectInput
        {
            get
            {
                return activeProp != null &&
                    (State == EchoInteractionState.Contact ||
                        State == EchoInteractionState.Hold ||
                        State == EchoInteractionState.Return);
            }
        }

        /// <summary>The inspect turn currently applied to the prop, as (yaw, pitch) degrees.</summary>
        public Vector2 InspectOffsetDegrees
        {
            get { return new Vector2(inspectYawDegrees, inspectPitchDegrees); }
        }

        /// <summary>
        /// Binds the coordinator to the character it drives. Safe to call again to
        /// rebind; it re-subscribes to the rig's post-evaluation event.
        /// </summary>
        /// <param name="characterRig">The built interaction rig.</param>
        /// <param name="root">The character root transform that is moved during align.</param>
        /// <param name="playerLocomotion">Player controller to lock, or null in a lab scene.</param>
        /// <param name="signal">Contact signal to use; null selects <see cref="EchoTimedContactSignal"/>.</param>
        public void Configure(
            EchoCharacterInteractionRig characterRig,
            Transform root,
            EchoThirdPersonController playerLocomotion,
            IEchoContactSignal signal)
        {
            CancelAll();
            Unsubscribe();

            rig = characterRig;
            characterRoot = root;
            characterCollision = root != null ? root.GetComponent<CharacterController>() : null;
            locomotion = playerLocomotion;
            contactSignal = signal ?? new EchoTimedContactSignal();
            Subscribe();
        }

        /// <summary>
        /// Points an interaction id at the prop and station that serve it.
        /// </summary>
        /// <param name="interactionId">The vignette interaction id, e.g. "photograph".</param>
        /// <param name="prop">The configured hero prop.</param>
        /// <param name="station">The configured station in front of it.</param>
        /// <returns>False when the arguments cannot be used.</returns>
        public bool Register(string interactionId, EchoHeroProp prop, EchoInteractionStation station)
        {
            if (string.IsNullOrEmpty(interactionId) || prop == null || station == null)
            {
                Debug.LogError(
                    "[Echo Interaction] Register needs a non-empty id, a prop and a station " +
                    $"(got '{interactionId}').");
                return false;
            }

            registrations[interactionId] = new Registration { Prop = prop, Station = station };
            return true;
        }

        /// <summary>True when an interaction id has a prop and station bound to it.</summary>
        /// <param name="interactionId">The vignette interaction id.</param>
        /// <returns>True when <see cref="TryBegin"/> could resolve the id.</returns>
        public bool IsRegistered(string interactionId)
        {
            return !string.IsNullOrEmpty(interactionId) && registrations.ContainsKey(interactionId);
        }

        /// <summary>
        /// Drops every registration. Cancels a running interaction first so no prop
        /// is left off its support.
        /// </summary>
        public void ClearRegistrations()
        {
            CancelAll();
            registrations.Clear();
        }

        /// <summary>
        /// Validates, reserves and starts an interaction. Validation, reservation
        /// and the locomotion lock all complete inside this call — the machine has
        /// left <see cref="EchoInteractionState.Idle"/> before it returns, so no
        /// second call can slip in between checking and claiming. Observers still
        /// see Validate, Reserve and LockLocomotion through <see cref="StateChanged"/>.
        /// </summary>
        /// <param name="interactionId">The vignette interaction id to play.</param>
        /// <returns>
        /// False when the machine is busy, the data is missing, the rig is not
        /// built, no legal approach exists, or the path is blocked badly enough
        /// that the prop would be out of reach.
        /// </returns>
        public bool TryBegin(string interactionId)
        {
            if (IsBusy)
            {
                return false;
            }

            SetState(EchoInteractionState.Validate);
            if (!TryValidate(interactionId, out Registration registration,
                    out EchoInteractionProfile profile, out Vector3 standPosition,
                    out Quaternion standRotation))
            {
                SetState(EchoInteractionState.Idle);
                return false;
            }

            Reserve(interactionId, registration, profile, standPosition, standRotation);
            LockLocomotion();
            EnterAlign();
            return true;
        }

        /// <summary>
        /// Aborts whatever is running and returns to a clean idle: the prop is put
        /// back on its captured support pose, every IK weight is zero, the inspect
        /// turn is cleared and locomotion is handed back. Safe from any phase and
        /// safe to call repeatedly.
        /// </summary>
        public void CancelAll()
        {
            if (State == EchoInteractionState.Idle && activeProp == null)
            {
                return;
            }

            if (activeProp != null)
            {
                inspectYawDegrees = 0f;
                inspectPitchDegrees = 0f;
                activeProp.Detach();
                activeProp.RestoreRestPose();
            }

            contactSignal?.Disarm();
            ApplyWeights(0f, 0f);
            DriveLook(0f);
            UnlockLocomotion();

            activeProp = null;
            activeStation = null;
            activeProfile = null;
            ActiveInteractionId = string.Empty;
            PhaseProgress = 0f;
            gripPositionError = float.PositiveInfinity;
            gripAngleError = float.PositiveInfinity;
            IsColliding = false;
            CollisionBlockerName = string.Empty;
            SetState(EchoInteractionState.Idle);
        }

        /// <summary>
        /// Turns the prop in place about its inspect pivot. The turn is expressed
        /// as an absolute offset, not a delta, so repeated calls cannot accumulate
        /// drift, and it is re-applied after the prop has followed the palm each
        /// frame so it never fights the grip.
        ///
        /// The yaw budget is small for a prop that never leaves its support, and
        /// pitch is refused outright for a prop that has to stay level, because a
        /// pure yaw about world up cannot change the prop's tilt.
        /// </summary>
        /// <param name="yawDegrees">Turn about world up, in degrees.</param>
        /// <param name="pitchDegrees">Tip about the character's right axis, in degrees.</param>
        public void SetInspectOffset(float yawDegrees, float pitchDegrees)
        {
            if (!AcceptsInspectInput || activeProfile == null)
            {
                return;
            }

            float yawLimit = activeProfile.staysSupported
                ? SupportedTurnLimitDegrees
                : HeldTurnLimitDegrees;
            float pitchLimit = activeProfile.staysSupported || activeProfile.keepWorldUp
                ? 0f
                : HeldPitchLimitDegrees;
            inspectYawDegrees = Mathf.Clamp(yawDegrees, -yawLimit, yawLimit);
            inspectPitchDegrees = Mathf.Clamp(pitchDegrees, -pitchLimit, pitchLimit);
        }

        private void OnEnable()
        {
            Subscribe();
        }

        private void OnDisable()
        {
            CancelAll();
            Unsubscribe();
        }

        /// <summary>
        /// Advances the interaction machine by one frame delta.
        /// </summary>
        /// <param name="deltaTime">Seconds to advance by.</param>
        public void Tick(float deltaTime)
        {
            if (State == EchoInteractionState.Idle)
            {
                return;
            }

            if (!IsInteractionStillUsable())
            {
                Debug.LogWarning(
                    $"[Echo Interaction] '{ActiveInteractionId}' lost its rig or prop mid-phase " +
                    $"({State}); the interaction was cancelled.");
                CancelAll();
                return;
            }

            float clampedDeltaTime = Mathf.Max(0f, deltaTime);
            phaseElapsed += clampedDeltaTime;
            contactSignal.Tick(clampedDeltaTime);

            switch (State)
            {
                case EchoInteractionState.Align:
                    TickAlign(clampedDeltaTime);
                    break;
                case EchoInteractionState.Reach:
                    TickReach();
                    break;
                case EchoInteractionState.RampIkIn:
                    TickRampIkIn();
                    break;
                case EchoInteractionState.Contact:
                    TickContact();
                    break;
                case EchoInteractionState.Hold:
                    TickHold();
                    break;
                case EchoInteractionState.Return:
                    TickReturn();
                    break;
                case EchoInteractionState.Support:
                    TickSupport();
                    break;
                case EchoInteractionState.RampIkOut:
                    TickRampIkOut();
                    break;
                case EchoInteractionState.Recover:
                    TickRecover();
                    break;
            }

            PhaseProgress = ComputePhaseProgress();
            previousRootPosition = characterRoot.position;
        }

        private void Update()
        {
            Tick(Time.deltaTime);
        }

        /// <summary>
        /// The only place the prop is allowed to be driven from the hand. It runs
        /// at the end of the rig's own post-evaluation callback, so the bone pose it
        /// reads is this frame's solved pose and the prop never trails the palm.
        /// </summary>
        private void HandleRigEvaluated()
        {
            if (activeProp == null)
            {
                return;
            }

            activeProp.FollowAttachment();
            ApplyInspectOffset();
            MeasureGrip();
        }

        private void Subscribe()
        {
            if (rig == null || subscribedRig == rig || !isActiveAndEnabled)
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

        private bool TryValidate(
            string interactionId,
            out Registration registration,
            out EchoInteractionProfile profile,
            out Vector3 standPosition,
            out Quaternion standRotation)
        {
            registration = null;
            profile = null;
            standPosition = Vector3.zero;
            standRotation = Quaternion.identity;

            if (rig == null || !rig.IsBuilt || characterRoot == null)
            {
                Debug.LogWarning(
                    $"[Echo Interaction] '{interactionId}' was refused: the character has no " +
                    "built interaction rig.");
                return false;
            }

            if (string.IsNullOrEmpty(interactionId) ||
                !registrations.TryGetValue(interactionId, out registration) ||
                registration.Prop == null ||
                registration.Station == null)
            {
                Debug.LogWarning(
                    $"[Echo Interaction] '{interactionId}' was refused: no prop and station are " +
                    "registered for it.");
                return false;
            }

            profile = registration.Prop.Profile ?? EchoInteractionProfileCatalog.Find(interactionId);
            if (profile == null)
            {
                Debug.LogWarning(
                    $"[Echo Interaction] '{interactionId}' was refused: the prop has no profile " +
                    "and the catalog has no entry for the id.");
                return false;
            }

            if (registration.Prop.GripPrimary == null ||
                (profile.usesSecondaryHand && registration.Prop.GripSecondary == null))
            {
                Debug.LogWarning(
                    $"[Echo Interaction] '{interactionId}' was refused: the prop's grip sockets " +
                    "are missing. Call EchoHeroProp.Configure before starting an interaction.");
                return false;
            }

            if (!registration.Station.TryResolveStandPose(
                    characterRoot.position,
                    out standPosition,
                    out standRotation))
            {
                Debug.LogWarning(
                    $"[Echo Interaction] '{interactionId}' was refused: the station could not " +
                    "resolve a legal approach pose.");
                return false;
            }

            if (registration.Prop.OverlapsIgnoringSupport(out string restingBlocker))
            {
                Debug.LogWarning(
                    $"[Echo Interaction] '{interactionId}' starts with the prop already " +
                    $"intersecting '{restingBlocker}'. The interaction still runs, but the " +
                    "grip will be measured against a prop that is not cleanly placed.");
            }

            Vector3 gripPosition = registration.Prop.GripPrimary.position;
            float plannedDistance = Vector3.Distance(standPosition, gripPosition);
            if (!TrySweepApproach(
                    characterRoot.position,
                    standPosition,
                    registration.Prop.transform,
                    out Vector3 reachable,
                    out string blocker))
            {
                float shortenedDistance = Vector3.Distance(reachable, gripPosition);
                if (shortenedDistance > plannedDistance + ApproachSlackMeters)
                {
                    Debug.LogWarning(
                        $"[Echo Interaction] '{interactionId}' was refused: '{blocker}' blocks " +
                        $"the approach and leaves the character {shortenedDistance:0.00}m from " +
                        $"the grip instead of {plannedDistance:0.00}m.");
                    return false;
                }

                Debug.Log(
                    $"[Echo Interaction] '{interactionId}' approach shortened by '{blocker}'; " +
                    $"the character stops {shortenedDistance:0.00}m from the grip.");
                standPosition = reachable;
            }

            return true;
        }

        private void Reserve(
            string interactionId,
            Registration registration,
            EchoInteractionProfile profile,
            Vector3 standPosition,
            Quaternion standRotation)
        {
            SetState(EchoInteractionState.Reserve);

            activeProp = registration.Prop;
            activeStation = registration.Station;
            activeProfile = profile;
            ActiveInteractionId = interactionId;
            primaryHand = profile.PrimaryHand;
            secondaryHand = primaryHand == EchoHand.Right ? EchoHand.Left : EchoHand.Right;

            // The prop is stationary at this point, so its live pose is exactly the
            // support pose it has to be returned to, and its grip socket is exactly
            // the pose the hand has to arrive at.
            activeProp.CaptureRestPose();
            activeProp.transform.GetPositionAndRotation(out restPropPosition, out restPropRotation);
            activeProp.GripPrimary.GetPositionAndRotation(out restGripPosition, out restGripRotation);

            alignTargetPosition = standPosition;
            alignTargetRotation = standRotation;
            inspectYawDegrees = 0f;
            inspectPitchDegrees = 0f;
            AttachFrameIndex = -1;
            ReleaseFrameIndex = -1;
            IsColliding = false;
            CollisionBlockerName = string.Empty;
            gripPositionError = float.PositiveInfinity;
            gripAngleError = float.PositiveInfinity;
            previousRootPosition = characterRoot.position;
        }

        private void LockLocomotion()
        {
            SetState(EchoInteractionState.LockLocomotion);
            if (locomotion != null)
            {
                // A vignette may already have taken input away for a beat of
                // dialogue, so the lock remembers what it interrupted instead of
                // handing control back to a scene that did not want it.
                locomotionWasEnabled = locomotion.AcceptsInput;
                locomotion.SetInputEnabled(false);
            }
            rig.SetFootGroundingEnabled(true);
        }

        private void UnlockLocomotion()
        {
            if (locomotion != null && locomotionWasEnabled)
            {
                locomotion.SetInputEnabled(true);
            }
            locomotionWasEnabled = true;
        }

        private void EnterAlign()
        {
            SetState(EchoInteractionState.Align);
            characterRoot.GetPositionAndRotation(out alignStartPosition, out alignStartRotation);
        }

        private void TickAlign(float deltaTime)
        {
            float duration = Mathf.Max(0.01f, activeProfile.alignSeconds);
            float travel = Mathf.SmoothStep(0f, 1f, Mathf.Clamp01(phaseElapsed / duration));
            MoveCharacterTo(Vector3.Lerp(alignStartPosition, alignTargetPosition, travel));
            characterRoot.rotation = Quaternion.Slerp(alignStartRotation, alignTargetRotation, travel);
            DriveLook(travel * 0.6f);

            if (phaseElapsed < duration)
            {
                return;
            }

            // The grip pose is only meaningful once the root, the feet and the pelvis
            // have stopped moving. Reaching from a mid-align pose is what produces a
            // hand that arrives next to the prop instead of on it.
            bool settled = HasCharacterSettled();
            if (!settled && phaseElapsed < duration + AlignSettleTimeoutSeconds)
            {
                return;
            }

            if (!settled)
            {
                Debug.LogWarning(
                    $"[Echo Interaction] '{ActiveInteractionId}' started reaching before the body " +
                    $"settled (foot error {FootErrorMeters:0.000}m, stand error " +
                    $"{Vector3.Distance(characterRoot.position, alignTargetPosition):0.000}m).");
            }
            EnterReach();
        }

        private bool HasCharacterSettled()
        {
            if (Vector3.Distance(characterRoot.position, previousRootPosition) >
                StillnessToleranceMeters)
            {
                return false;
            }

            Vector3 standError = characterRoot.position - alignTargetPosition;
            standError.y = 0f;
            if (standError.magnitude > StandPositionToleranceMeters)
            {
                return false;
            }

            if (Quaternion.Angle(characterRoot.rotation, alignTargetRotation) >
                StandAngleToleranceDegrees)
            {
                return false;
            }

            return FootErrorMeters <= AlignSettleFootToleranceMeters;
        }

        private void EnterReach()
        {
            SetState(EchoInteractionState.Reach);
            Transform palm = rig.PalmSocket(primaryHand);
            if (palm != null)
            {
                palm.GetPositionAndRotation(out reachStartPalmPosition, out reachStartPalmRotation);
            }
            else
            {
                reachStartPalmPosition = restGripPosition;
                reachStartPalmRotation = restGripRotation;
            }
            contactSignal.Arm(activeProfile, EchoContactEvent.ReachContact);
        }

        private void TickReach()
        {
            // The prop is stationary and stays stationary: the grip pose is read
            // live only so that a prop nudged by something else is still met.
            activeProp.GripPrimary.GetPositionAndRotation(
                out Vector3 gripPosition,
                out Quaternion gripRotation);

            float eased = Mathf.SmoothStep(0f, 1f, Mathf.Clamp01(contactSignal.Progress));
            Vector3 palmPosition = Vector3.Lerp(reachStartPalmPosition, gripPosition, eased);
            palmPosition += Vector3.up * (Mathf.Sin(eased * Mathf.PI) * ReachArcMeters);
            Quaternion palmRotation = Quaternion.Slerp(reachStartPalmRotation, gripRotation, eased);

            DriveHand(primaryHand, palmPosition, palmRotation);
            ApplyWeights(eased * ReachEndWeight, 0f);
            DriveLook(Mathf.Lerp(0.6f, 1f, eased));

            if (contactSignal.HasFired)
            {
                EnterRampIkIn();
            }
        }

        private void EnterRampIkIn()
        {
            SetState(EchoInteractionState.RampIkIn);
            contactSignal.Disarm();
        }

        private void TickRampIkIn()
        {
            HoldHandOnGrip();
            float ramp = Mathf.Clamp01(phaseElapsed / RampIkInSeconds);
            ApplyWeights(Mathf.Lerp(ReachEndWeight, 1f, ramp), 0f);
            DriveLook(1f);

            if (ramp < 1f)
            {
                return;
            }

            bool aligned =
                gripPositionError <= activeProfile.gripToleranceMeters &&
                gripAngleError <= activeProfile.gripAngleToleranceDegrees;
            if (!aligned && phaseElapsed < RampIkInSeconds + GripSettleTimeoutSeconds)
            {
                return;
            }

            if (!aligned)
            {
                Debug.LogWarning(
                    $"[Echo Interaction] '{ActiveInteractionId}' took contact with the grip " +
                    $"{gripPositionError * 100f:0.0}cm and {gripAngleError:0.0}deg out of place " +
                    $"(budget {activeProfile.gripToleranceMeters * 100f:0.0}cm / " +
                    $"{activeProfile.gripAngleToleranceDegrees:0.0}deg).");
            }
            EnterContact();
        }

        private void EnterContact()
        {
            SetState(EchoInteractionState.Contact);

            if (!activeProfile.staysSupported)
            {
                activeProp.AttachTo(rig.PalmSocket(primaryHand));
                AttachFrameIndex = Time.frameCount;
            }

            contactPalmPosition = restGripPosition;
            contactPalmRotation = restGripRotation;
            CaptureHoldPose();
        }

        /// <summary>
        /// Freezes the inspected pose in the character root's frame. Anchoring it to
        /// the eye anchor every frame would close a loop — the gaze aims at the prop,
        /// the prop is placed from the gaze — and the pose would creep. The root does
        /// not move while an interaction runs, so the frozen pose stays correct.
        /// </summary>
        private void CaptureHoldPose()
        {
            Transform eye = rig.EyeAnchor;
            Vector3 worldPosition;
            Quaternion worldRotation;
            if (eye != null)
            {
                worldPosition = eye.TransformPoint(activeProfile.holdLocalPositionFromEye);
                worldRotation = eye.rotation * Quaternion.Euler(activeProfile.holdLocalEulerFromEye);
            }
            else
            {
                worldPosition = restPropPosition;
                worldRotation = restPropRotation;
            }

            holdPropLocalPosition = characterRoot.InverseTransformPoint(worldPosition);
            holdPropLocalRotation = Quaternion.Inverse(characterRoot.rotation) * worldRotation;
        }

        private void TickContact()
        {
            float duration = Mathf.Max(0.01f, activeProfile.settleSeconds);
            float eased = Mathf.SmoothStep(0f, 1f, Mathf.Clamp01(phaseElapsed / duration));

            if (activeProfile.staysSupported)
            {
                HoldHandOnGrip();
            }
            else
            {
                ResolveHoldPalmPose(out Vector3 holdPalmPosition, out Quaternion holdPalmRotation);
                DriveHand(
                    primaryHand,
                    Vector3.Lerp(contactPalmPosition, holdPalmPosition, eased),
                    Quaternion.Slerp(contactPalmRotation, holdPalmRotation, eased));
            }

            DriveSecondaryHand();
            ApplyWeights(1f, activeProfile.usesSecondaryHand ? eased : 0f);
            DriveLook(1f);

            if (phaseElapsed >= duration)
            {
                SetState(EchoInteractionState.Hold);
            }
        }

        private void TickHold()
        {
            if (activeProfile.staysSupported)
            {
                HoldHandOnGrip();
            }
            else
            {
                ResolveHoldPalmPose(out Vector3 holdPalmPosition, out Quaternion holdPalmRotation);
                DriveHand(primaryHand, holdPalmPosition, holdPalmRotation);
            }

            DriveSecondaryHand();
            ApplyWeights(1f, activeProfile.usesSecondaryHand ? 1f : 0f);
            DriveLook(1f);

            if (phaseElapsed >= Mathf.Max(0.01f, activeProfile.holdSeconds))
            {
                EnterReturn();
            }
        }

        private void EnterReturn()
        {
            SetState(EchoInteractionState.Return);
            if (activeProfile.staysSupported)
            {
                returnStartPalmPosition = restGripPosition;
                returnStartPalmRotation = restGripRotation;
            }
            else
            {
                ResolveHoldPalmPose(out returnStartPalmPosition, out returnStartPalmRotation);
            }
            returnStartInspectYaw = inspectYawDegrees;
            returnStartInspectPitch = inspectPitchDegrees;
            contactSignal.Arm(activeProfile, EchoContactEvent.SupportContact);
        }

        private void TickReturn()
        {
            float eased = Mathf.SmoothStep(0f, 1f, Mathf.Clamp01(contactSignal.Progress));
            DriveHand(
                primaryHand,
                Vector3.Lerp(returnStartPalmPosition, restGripPosition, eased),
                Quaternion.Slerp(returnStartPalmRotation, restGripRotation, eased));
            DriveSecondaryHand();
            ApplyWeights(1f, activeProfile.usesSecondaryHand ? 1f - eased * 0.35f : 0f);
            DriveLook(1f);

            // The turn has to be gone before the prop is put down, otherwise the
            // restored support pose would not be the pose that was captured.
            inspectYawDegrees = Mathf.Lerp(returnStartInspectYaw, 0f, eased);
            inspectPitchDegrees = Mathf.Lerp(returnStartInspectPitch, 0f, eased);

            if (contactSignal.HasFired)
            {
                EnterSupport();
            }
        }

        private void EnterSupport()
        {
            SetState(EchoInteractionState.Support);
            contactSignal.Disarm();
            inspectYawDegrees = 0f;
            inspectPitchDegrees = 0f;

            // Detach first so nothing can drive the prop from the palm any more,
            // then restore, so the support pose is the captured one bit for bit.
            activeProp.Detach();
            activeProp.RestoreRestPose();
            ReleaseFrameIndex = Time.frameCount;
        }

        private void TickSupport()
        {
            float positionError = Vector3.Distance(activeProp.transform.position, restPropPosition);
            float angleError = Quaternion.Angle(activeProp.transform.rotation, restPropRotation);
            if (positionError > 0.001f || angleError > 0.1f)
            {
                Debug.LogWarning(
                    $"[Echo Interaction] '{ActiveInteractionId}' released the prop " +
                    $"{positionError * 1000f:0.0}mm and {angleError:0.00}deg off its captured " +
                    "support pose; something else is writing the prop transform.");
                activeProp.RestoreRestPose();
            }

            HoldHandOnGrip();
            EnterRampIkOut();
        }

        private void EnterRampIkOut()
        {
            SetState(EchoInteractionState.RampIkOut);
        }

        private void TickRampIkOut()
        {
            float duration = Mathf.Max(0.01f, activeProfile.recoverySeconds);
            float eased = Mathf.SmoothStep(0f, 1f, Mathf.Clamp01(phaseElapsed / duration));
            HoldHandOnGrip();
            ApplyWeights(
                1f - eased,
                activeProfile.usesSecondaryHand ? (1f - eased) * 0.65f : 0f);
            DriveLook(1f - eased);

            if (phaseElapsed >= duration)
            {
                SetState(EchoInteractionState.Recover);
                ApplyWeights(0f, 0f);
                DriveLook(0f);
            }
        }

        private void TickRecover()
        {
            UnlockLocomotion();
            activeProp = null;
            activeStation = null;
            activeProfile = null;
            ActiveInteractionId = string.Empty;
            SetState(EchoInteractionState.Idle);
            PhaseProgress = 0f;
        }

        private void SetState(EchoInteractionState next)
        {
            if (State == next)
            {
                return;
            }

            State = next;
            phaseElapsed = 0f;
            if (next == EchoInteractionState.Idle)
            {
                PhaseProgress = 0f;
            }
            StateChanged?.Invoke(next);
        }

        private float ComputePhaseProgress()
        {
            if (activeProfile == null)
            {
                return 0f;
            }

            switch (State)
            {
                case EchoInteractionState.Align:
                    return Mathf.Clamp01(phaseElapsed / Mathf.Max(0.01f, activeProfile.alignSeconds));
                case EchoInteractionState.Reach:
                case EchoInteractionState.Return:
                    return Mathf.Clamp01(contactSignal.Progress);
                case EchoInteractionState.RampIkIn:
                    return Mathf.Clamp01(phaseElapsed / RampIkInSeconds);
                case EchoInteractionState.Contact:
                    return Mathf.Clamp01(phaseElapsed / Mathf.Max(0.01f, activeProfile.settleSeconds));
                case EchoInteractionState.Hold:
                    return Mathf.Clamp01(phaseElapsed / Mathf.Max(0.01f, activeProfile.holdSeconds));
                case EchoInteractionState.RampIkOut:
                    return Mathf.Clamp01(phaseElapsed / Mathf.Max(0.01f, activeProfile.recoverySeconds));
                case EchoInteractionState.Idle:
                    return 0f;
                default:
                    return 1f;
            }
        }

        private bool IsInteractionStillUsable()
        {
            return rig != null &&
                rig.IsBuilt &&
                characterRoot != null &&
                activeProp != null &&
                activeProfile != null &&
                activeProp.GripPrimary != null;
        }

        private void MoveCharacterTo(Vector3 desiredPosition)
        {
            if (characterCollision != null && characterCollision.enabled)
            {
                // Moving through the controller keeps the collide-and-slide response,
                // so the align step cannot push the character into furniture even if
                // the swept path missed something thin.
                characterCollision.Move(desiredPosition - characterRoot.position);
                return;
            }
            characterRoot.position = desiredPosition;
        }

        private void HoldHandOnGrip()
        {
            if (activeProp.GripPrimary == null)
            {
                return;
            }

            activeProp.GripPrimary.GetPositionAndRotation(
                out Vector3 gripPosition,
                out Quaternion gripRotation);
            DriveHand(primaryHand, gripPosition, gripRotation);
        }

        private void DriveSecondaryHand()
        {
            if (!activeProfile.usesSecondaryHand || activeProp.GripSecondary == null)
            {
                return;
            }

            // The second hand follows the prop; it never drives it. The prop's pose
            // comes from the primary grip alone, so this target is simply wherever
            // the secondary grip socket has ended up.
            activeProp.GripSecondary.GetPositionAndRotation(
                out Vector3 gripPosition,
                out Quaternion gripRotation);
            DriveHand(secondaryHand, gripPosition, gripRotation);
        }

        /// <summary>
        /// Converts a wanted palm-socket pose into the hand-bone pose the rig's IK
        /// target expects. The palm socket is a child of the hand bone, so writing
        /// the palm pose straight into <see cref="EchoCharacterInteractionRig.SetHandTarget"/>
        /// would leave the palm short of the grip by the socket offset.
        /// </summary>
        private void DriveHand(EchoHand hand, Vector3 palmPosition, Quaternion palmRotation)
        {
            Transform palm = rig.PalmSocket(hand);
            Transform handBone = palm != null ? palm.parent : null;
            if (palm == null || handBone == null)
            {
                rig.SetHandTarget(hand, palmPosition, palmRotation);
                return;
            }

            Quaternion palmLocalRotation = Quaternion.Inverse(handBone.rotation) * palm.rotation;
            Vector3 palmLocalPosition = handBone.InverseTransformPoint(palm.position);
            Quaternion targetRotation = palmRotation * Quaternion.Inverse(palmLocalRotation);
            Vector3 targetPosition = palmPosition -
                targetRotation * Vector3.Scale(palmLocalPosition, handBone.lossyScale);
            rig.SetHandTarget(hand, targetPosition, targetRotation);
        }

        /// <summary>
        /// The palm pose that puts the prop on the frozen inspected pose. It is the
        /// exact inverse of <see cref="EchoHeroProp.FollowAttachment"/>, so the prop
        /// lands where it was asked to instead of near it.
        /// </summary>
        private void ResolveHoldPalmPose(out Vector3 palmPosition, out Quaternion palmRotation)
        {
            Vector3 propPosition = characterRoot.TransformPoint(holdPropLocalPosition);
            Quaternion propRotation = characterRoot.rotation * holdPropLocalRotation;
            Quaternion gripLocalRotation = Quaternion.Euler(activeProfile.gripPrimaryLocalEuler);
            Vector3 scaledGrip = Vector3.Scale(
                activeProfile.gripPrimaryLocalPosition,
                activeProp.transform.lossyScale);
            palmRotation = propRotation * gripLocalRotation;
            palmPosition = propPosition + propRotation * scaledGrip;
        }

        private void ApplyWeights(float primary, float secondary)
        {
            primaryWeight = Mathf.Clamp01(primary);
            secondaryWeight = Mathf.Clamp01(secondary);
            if (rig == null)
            {
                return;
            }

            rig.SetHandWeight(primaryHand, primaryWeight);
            rig.SetHandWeight(secondaryHand, secondaryWeight);
        }

        private void DriveLook(float weight)
        {
            lookWeight = Mathf.Clamp01(weight);
            if (rig == null)
            {
                return;
            }

            if (activeProp != null && activeProp.LookTarget != null)
            {
                rig.SetLookTarget(activeProp.LookTarget.position);
            }
            rig.SetLookWeight(lookWeight);
        }

        /// <summary>
        /// Re-applies the inspect turn on top of the pose the prop has just been
        /// solved into. It is rebuilt from a known base pose every frame rather than
        /// accumulated onto the live transform, so holding a key cannot spin the prop
        /// away and releasing it restores the pose exactly.
        /// </summary>
        private void ApplyInspectOffset()
        {
            if (activeProfile == null ||
                (Mathf.Abs(inspectYawDegrees) < 0.01f && Mathf.Abs(inspectPitchDegrees) < 0.01f))
            {
                return;
            }

            Vector3 basePosition;
            Quaternion baseRotation;
            if (activeProp.IsAttached)
            {
                activeProp.transform.GetPositionAndRotation(out basePosition, out baseRotation);
            }
            else
            {
                basePosition = restPropPosition;
                baseRotation = restPropRotation;
            }

            Vector3 pivot = basePosition + baseRotation * Vector3.Scale(
                activeProfile.inspectPivotLocalPosition,
                activeProp.transform.lossyScale);

            Quaternion turn = Quaternion.AngleAxis(inspectYawDegrees, Vector3.up);
            if (Mathf.Abs(inspectPitchDegrees) > 0.01f && characterRoot != null)
            {
                Vector3 pitchAxis = characterRoot.right;
                pitchAxis.y = 0f;
                if (pitchAxis.sqrMagnitude > 0.0001f)
                {
                    turn = Quaternion.AngleAxis(inspectPitchDegrees, pitchAxis.normalized) * turn;
                }
            }

            activeProp.transform.SetPositionAndRotation(
                pivot + turn * (basePosition - pivot),
                turn * baseRotation);
        }

        private void MeasureGrip()
        {
            Transform palm = rig != null ? rig.PalmSocket(primaryHand) : null;
            gripPositionError = activeProp.GripPositionErrorMeters(palm);
            gripAngleError = activeProp.GripAngleErrorDegrees(palm);
            IsColliding = activeProp.OverlapsIgnoringSupport(out string blocker);
            CollisionBlockerName = blocker;
        }

        /// <summary>
        /// Sweeps the character's own capsule along the approach before anyone walks
        /// it. A blocking hit shortens the move to just short of the obstacle rather
        /// than letting the align step slide the character through furniture.
        /// </summary>
        /// <param name="from">Where the character stands now.</param>
        /// <param name="to">The stand point the station asked for.</param>
        /// <param name="prop">The target prop, whose colliders are ignored.</param>
        /// <param name="reachable">The furthest point actually reachable.</param>
        /// <param name="blockerName">The collider that stopped the sweep; empty when clear.</param>
        /// <returns>True when the whole path is clear.</returns>
        private bool TrySweepApproach(
            Vector3 from,
            Vector3 to,
            Transform prop,
            out Vector3 reachable,
            out string blockerName)
        {
            reachable = to;
            blockerName = string.Empty;

            Vector3 travel = to - from;
            travel.y = 0f;
            float distance = travel.magnitude;
            if (distance < MinimumApproachTravelMeters)
            {
                return true;
            }

            Vector3 direction = travel / distance;
            ResolveSweepCapsule(from, out Vector3 bottom, out Vector3 top, out float radius);
            int hitCount = Physics.CapsuleCastNonAlloc(
                bottom,
                top,
                radius,
                direction,
                sweepBuffer,
                distance,
                Physics.DefaultRaycastLayers,
                QueryTriggerInteraction.Ignore);

            float nearest = distance;
            for (int index = 0; index < hitCount; index++)
            {
                RaycastHit hit = sweepBuffer[index];
                if (hit.collider == null || hit.distance >= nearest)
                {
                    continue;
                }
                if (hit.collider.transform.IsChildOf(characterRoot))
                {
                    continue;
                }
                if (prop != null && hit.collider.transform.IsChildOf(prop))
                {
                    continue;
                }

                nearest = hit.distance;
                blockerName = hit.collider.name;
            }

            if (nearest >= distance)
            {
                return true;
            }

            reachable = from + direction * Mathf.Max(0f, nearest - SweepContactOffsetMeters);
            return false;
        }

        private void ResolveSweepCapsule(
            Vector3 origin,
            out Vector3 bottom,
            out Vector3 top,
            out float radius)
        {
            if (characterCollision != null)
            {
                radius = Mathf.Max(0.05f, characterCollision.radius - characterCollision.skinWidth);
                Vector3 centre = origin + characterCollision.center;
                float half = Mathf.Max(radius, characterCollision.height * 0.5f) - radius;
                bottom = centre - Vector3.up * half;
                top = centre + Vector3.up * half;
                return;
            }

            radius = FallbackSweepRadiusMeters;
            bottom = origin + Vector3.up * radius;
            top = origin + Vector3.up * Mathf.Max(radius * 2f, 1.5f);
        }
    }
}
