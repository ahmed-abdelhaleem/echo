using System;
using UnityEngine;
using UnityEngine.Animations.Rigging;

namespace Echo.FreePrototype
{
    /// <summary>
    /// Lets a component take part in a character's manually evaluated animation
    /// graph. <see cref="EchoMixamoCharacter"/> owns the ordering: the hook writes
    /// its scene inputs in <see cref="BeforeGraphEvaluate"/>, the graph evaluates
    /// locomotion and then the rig layers in the same frame, and the hook reads the
    /// solved pose back in <see cref="AfterGraphEvaluate"/>. Nothing here lags a frame.
    /// </summary>
    public interface IEchoRigHook
    {
        /// <summary>
        /// Called immediately before the character graph is evaluated. Implementations
        /// must push every scene-side value the graph will read during this call.
        /// </summary>
        /// <param name="deltaTime">The time the graph is about to be advanced by.</param>
        void BeforeGraphEvaluate(float deltaTime);

        /// <summary>
        /// Called immediately after the character graph has been evaluated, when the
        /// bone transforms already hold the solved pose for this frame.
        /// </summary>
        void AfterGraphEvaluate();
    }

    /// <summary>
    /// Per-character measurements the interaction rig needs but cannot safely guess.
    /// Kept as a plain serializable class with public fields so it can be authored in
    /// JSON through <see cref="JsonUtility"/> exactly like the scale profiles.
    /// </summary>
    [Serializable]
    public sealed class EchoCharacterCalibration
    {
        /// <summary>Identifier of the character this calibration was authored for.</summary>
        public string characterId;

        /// <summary>Standing height in metres, sole to crown.</summary>
        public float heightMeters;

        /// <summary>Comfortable arm reach in metres, shoulder joint to palm centre.</summary>
        public float reachMeters;

        /// <summary>
        /// Direction in hand-bone local space that points from the wrist toward the
        /// fingertips. Used to orient the palm socket when finger bones are absent.
        /// </summary>
        public Vector3 palmForwardLocal;

        /// <summary>
        /// Direction in hand-bone local space that points away from the palm, i.e. out
        /// of the back of the hand. Mirrored across local X for the left hand.
        /// </summary>
        public Vector3 palmUpLocal;

        /// <summary>Distance in metres from the ankle bone down to the sole of the foot.</summary>
        public float soleOffsetMeters;

        /// <summary>
        /// Hard limit in metres on how far the hips may be lowered to let the lower foot
        /// reach the ground. An unclamped drop is how characters end up doing the splits.
        /// </summary>
        public float pelvisMaxDropMeters;
    }

    /// <summary>
    /// Builds a complete Animation Rigging setup for a Mixamo-style humanoid entirely
    /// in code — arm IK, gaze, leg IK with pelvis compensation, palm sockets and an eye
    /// anchor — and drives it from inside the character's own PlayableGraph.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The generated <see cref="RigBuilder"/> is deliberately built through
    /// <c>RigBuilder.Build(PlayableGraph)</c> rather than <c>RigBuilder.Build()</c>: the
    /// parameterless overload creates a second PlayableGraph on the Animator that would
    /// fight <see cref="EchoMixamoCharacter"/>'s hand-built graph for the animation
    /// output. Building into the existing graph appends one rig output per layer with
    /// sorting order 1000, so the rig always evaluates after locomotion in the same frame.
    /// The cost of that overload is that the RigBuilder's own update loop is inert, so
    /// <see cref="RigBuilder.SyncLayers"/> is called here before every evaluation.
    /// </para>
    /// <para>
    /// Do not disable and re-enable the generated RigBuilder component. Its
    /// <c>OnEnable</c> would call the parameterless <c>Build()</c> and take the character
    /// over with a rival graph.
    /// </para>
    /// </remarks>
    public sealed class EchoCharacterInteractionRig : MonoBehaviour, IEchoRigHook
    {
        private const int RightIndex = 0;
        private const int LeftIndex = 1;
        private const int GroundProbeBufferSize = 8;
        private const float PelvisDropMetersPerSecond = 0.9f;
        private const float ChestGazeShare = 0.45f;

        private readonly TwoBoneIKConstraint[] armConstraints = new TwoBoneIKConstraint[2];
        private readonly TwoBoneIKConstraint[] legConstraints = new TwoBoneIKConstraint[2];
        private readonly Transform[] handTargets = new Transform[2];
        private readonly Transform[] footTargets = new Transform[2];
        private readonly Transform[] palmSockets = new Transform[2];
        private readonly Transform[] handBones = new Transform[2];
        private readonly Transform[] footBones = new Transform[2];
        private readonly float[] handWeights = new float[2];
        private readonly bool[] footGrounded = new bool[2];
        private readonly Vector3[] footGroundPoints = new Vector3[2];
        private readonly Vector3[] footGroundNormals = new Vector3[2];
        private readonly RaycastHit[] groundProbeBuffer = new RaycastHit[GroundProbeBufferSize];

        private Animator animator;
        private EchoMixamoCharacter character;
        private Transform characterRoot;
        private Transform rigRoot;
        private Transform hipsBone;
        private Transform headBone;
        private Transform lookTarget;
        private Rig rig;
        private RigBuilder rigBuilder;
        private OverrideTransform pelvisGrounding;
        private MultiAimConstraint headAim;
        private MultiAimConstraint chestAim;
        private LayerMask groundMask = Physics.DefaultRaycastLayers;
        private string missingBoneName;
        private float lookWeight;
        private float appliedPelvisDrop;
        private bool footGroundingEnabled = true;

        /// <summary>
        /// Raised at the very end of <see cref="AfterGraphEvaluate"/>, once the solved
        /// pose and <see cref="FootErrorMeters"/> are both up to date for this frame.
        /// </summary>
        public event Action RigEvaluated;

        /// <summary>True once <see cref="Build"/> has produced a working rig.</summary>
        public bool IsBuilt { get; private set; }

        /// <summary>
        /// Largest vertical distance in metres between a foot bone and where that foot
        /// should sit on the probed ground, measured after the last evaluation. Feet with
        /// no ground beneath them are excluded; the value is zero when neither foot
        /// found ground. This is an acceptance metric, so it is measured honestly and is
        /// never clamped or hidden while foot grounding is switched off.
        /// </summary>
        public float FootErrorMeters { get; private set; }

        /// <summary>Transform at eye height under the head bone, for framing and gaze debug.</summary>
        public Transform EyeAnchor { get; private set; }

        /// <summary>The calibration this rig was built with.</summary>
        public EchoCharacterCalibration Calibration { get; private set; }

        /// <summary>
        /// Layers the downward foot probe accepts as ground. Colliders belonging to the
        /// character's own hierarchy are rejected regardless of this mask.
        /// </summary>
        public LayerMask GroundMask
        {
            get => groundMask;
            set => groundMask = value;
        }

        /// <summary>
        /// Returns calibration defaults for the free prototype's characters. Both shipped
        /// characters are Mixamo humanoids authored against the project's 1.78 m reference
        /// player height. "YBot" is tested before "Noor" because the fallback player visual
        /// is named "Noor_YBotVisual" and is in fact a YBot.
        /// </summary>
        /// <param name="characterId">Character identifier, GameObject name or resource path.</param>
        /// <returns>A calibration that is always non-null.</returns>
        public static EchoCharacterCalibration DefaultCalibration(string characterId)
        {
            string id = characterId ?? string.Empty;
            if (id.IndexOf("YBot", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return new EchoCharacterCalibration
                {
                    characterId = "YBot",
                    heightMeters = 1.78f,
                    reachMeters = 0.72f,
                    // Mixamo joint convention: the bone's local +Y runs down the chain
                    // toward the children, so +Y leaves the wrist toward the fingertips.
                    palmForwardLocal = new Vector3(0f, 1f, 0f),
                    palmUpLocal = new Vector3(0f, 0f, 1f),
                    soleOffsetMeters = 0.085f,
                    pelvisMaxDropMeters = 0.18f
                };
            }

            if (id.IndexOf("Noor", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return new EchoCharacterCalibration
                {
                    characterId = "Noor",
                    heightMeters = 1.78f,
                    reachMeters = 0.68f,
                    palmForwardLocal = new Vector3(0f, 1f, 0f),
                    palmUpLocal = new Vector3(0f, 0f, 1f),
                    soleOffsetMeters = 0.085f,
                    pelvisMaxDropMeters = 0.18f
                };
            }

            return new EchoCharacterCalibration
            {
                characterId = string.IsNullOrEmpty(id) ? "neutral" : id,
                heightMeters = 1.78f,
                reachMeters = 0.70f,
                // Neutral humanoids are assumed to follow Unity's own axis convention.
                palmForwardLocal = new Vector3(0f, 0f, 1f),
                palmUpLocal = new Vector3(0f, 1f, 0f),
                soleOffsetMeters = 0.09f,
                pelvisMaxDropMeters = 0.15f
            };
        }

        /// <summary>
        /// Generates the whole rig hierarchy and appends it to the character's graph.
        /// </summary>
        /// <param name="targetAnimator">Humanoid animator to rig.</param>
        /// <param name="targetCharacter">The character that owns the manually evaluated graph.</param>
        /// <param name="calibration">Per-character measurements; null falls back to <see cref="DefaultCalibration"/>.</param>
        /// <returns>
        /// True when the rig is live. False leaves the character animating normally and
        /// logs exactly one warning naming what was missing.
        /// </returns>
        public bool Build(
            Animator targetAnimator,
            EchoMixamoCharacter targetCharacter,
            EchoCharacterCalibration calibration)
        {
            if (IsBuilt)
            {
                return true;
            }

            if (targetAnimator == null || targetCharacter == null)
            {
                Debug.LogWarning(
                    "[Echo Rig] Build needs both an Animator and an EchoMixamoCharacter; " +
                    "the character keeps animating without an interaction rig.");
                return false;
            }

            if (!targetAnimator.isHuman)
            {
                Debug.LogWarning(
                    $"[Echo Rig] Animator '{targetAnimator.name}' is not a humanoid avatar, " +
                    "so no interaction rig was built. Re-import the FBX as Humanoid.");
                return false;
            }

            if (!targetCharacter.IsGraphValid)
            {
                Debug.LogWarning(
                    $"[Echo Rig] '{targetCharacter.name}' has no valid animation graph yet. " +
                    "Call EchoMixamoCharacter.Configure before building the interaction rig.");
                return false;
            }

            animator = targetAnimator;
            character = targetCharacter;
            characterRoot = targetCharacter.transform;
            Calibration = calibration ?? DefaultCalibration(targetAnimator.name);

            missingBoneName = null;
            hipsBone = RequireBone(HumanBodyBones.Hips);
            headBone = RequireBone(HumanBodyBones.Head);
            handBones[RightIndex] = RequireBone(HumanBodyBones.RightHand);
            handBones[LeftIndex] = RequireBone(HumanBodyBones.LeftHand);
            footBones[RightIndex] = RequireBone(HumanBodyBones.RightFoot);
            footBones[LeftIndex] = RequireBone(HumanBodyBones.LeftFoot);
            Transform rightUpperArm = RequireBone(HumanBodyBones.RightUpperArm);
            Transform rightLowerArm = RequireBone(HumanBodyBones.RightLowerArm);
            Transform leftUpperArm = RequireBone(HumanBodyBones.LeftUpperArm);
            Transform leftLowerArm = RequireBone(HumanBodyBones.LeftLowerArm);
            Transform rightUpperLeg = RequireBone(HumanBodyBones.RightUpperLeg);
            Transform rightLowerLeg = RequireBone(HumanBodyBones.RightLowerLeg);
            Transform leftUpperLeg = RequireBone(HumanBodyBones.LeftUpperLeg);
            Transform leftLowerLeg = RequireBone(HumanBodyBones.LeftLowerLeg);
            if (missingBoneName != null)
            {
                Debug.LogWarning(
                    $"[Echo Rig] '{targetAnimator.name}' is missing the required humanoid bone " +
                    $"'{missingBoneName}', so no interaction rig was built. The character keeps " +
                    "playing its clips untouched.");
                Clear();
                return false;
            }

            Transform torsoBone = FirstAvailableBone(
                HumanBodyBones.UpperChest,
                HumanBodyBones.Chest,
                HumanBodyBones.Spine) ?? hipsBone;

            rigRoot = CreateChild(animator.transform, "EchoInteractionRig");
            rig = rigRoot.gameObject.AddComponent<Rig>();
            rig.weight = 1f;

            // Constraint order inside a Rig is the child hierarchy order, so the pelvis
            // drop has to be created before the legs that must reach the ground with it,
            // and the chest has to aim before the head it carries.
            BuildPelvisGrounding();
            BuildLegIk(RightIndex, "LegIK_Right", rightUpperLeg, rightLowerLeg, footBones[RightIndex], 1f);
            BuildLegIk(LeftIndex, "LegIK_Left", leftUpperLeg, leftLowerLeg, footBones[LeftIndex], -1f);
            BuildArmIk(RightIndex, "ArmIK_Right", rightUpperArm, rightLowerArm, handBones[RightIndex], torsoBone, 1f);
            BuildArmIk(LeftIndex, "ArmIK_Left", leftUpperArm, leftLowerArm, handBones[LeftIndex], torsoBone, -1f);
            BuildGaze(torsoBone);
            BuildPalmSocket(RightIndex, EchoHand.Right, HumanBodyBones.RightMiddleProximal);
            BuildPalmSocket(LeftIndex, EchoHand.Left, HumanBodyBones.LeftMiddleProximal);
            BuildEyeAnchor();

            rigBuilder = animator.gameObject.GetComponent<RigBuilder>();
            if (rigBuilder == null)
            {
                rigBuilder = animator.gameObject.AddComponent<RigBuilder>();
            }
            rigBuilder.layers.Clear();
            rigBuilder.layers.Add(new RigLayer(rig, true));

            character.SetRigHook(this);
            if (!rigBuilder.Build(character.Graph))
            {
                Debug.LogWarning(
                    $"[Echo Rig] RigBuilder refused to append '{rigRoot.name}' to the graph of " +
                    $"'{character.name}'; the character keeps animating without an interaction rig.");
                character.SetRigHook(null);
                Clear();
                return false;
            }

            IsBuilt = true;
            Debug.Log(
                $"[Echo Rig] Built '{rigRoot.name}' on {animator.name} " +
                $"({Calibration.characterId}, {Calibration.heightMeters:0.00}m, " +
                $"reach {Calibration.reachMeters:0.00}m).");
            return true;
        }

        /// <summary>
        /// The transform props attach to when they are held in the given hand. It sits at
        /// the palm centre of the hand bone and is null until <see cref="Build"/> succeeds.
        /// </summary>
        /// <param name="hand">Which hand to query.</param>
        /// <returns>The palm socket transform, or null when the rig is not built.</returns>
        public Transform PalmSocket(EchoHand hand)
        {
            return IsBuilt ? palmSockets[HandIndex(hand)] : null;
        }

        /// <summary>
        /// Places the IK goal for one arm. Safe to call before <see cref="Build"/>.
        /// </summary>
        /// <param name="hand">Which arm to drive.</param>
        /// <param name="worldPosition">World position the palm should reach.</param>
        /// <param name="worldRotation">World rotation the palm should adopt.</param>
        public void SetHandTarget(EchoHand hand, Vector3 worldPosition, Quaternion worldRotation)
        {
            Transform target = IsBuilt ? handTargets[HandIndex(hand)] : null;
            if (target == null)
            {
                return;
            }

            target.SetPositionAndRotation(worldPosition, worldRotation);
        }

        /// <summary>
        /// Sets how strongly one arm follows its IK goal. Ramping is the caller's job;
        /// this is a plain clamped setter that is safe to call before <see cref="Build"/>.
        /// </summary>
        /// <param name="hand">Which arm to weight.</param>
        /// <param name="weight">Blend weight, clamped to 0..1.</param>
        public void SetHandWeight(EchoHand hand, float weight)
        {
            handWeights[HandIndex(hand)] = Mathf.Clamp01(weight);
        }

        /// <summary>Reads back the weight last given to <see cref="SetHandWeight"/>.</summary>
        /// <param name="hand">Which arm to query.</param>
        /// <returns>The stored blend weight in 0..1.</returns>
        public float GetHandWeight(EchoHand hand)
        {
            return handWeights[HandIndex(hand)];
        }

        /// <summary>
        /// Moves the point the head and chest aim at. Safe to call before <see cref="Build"/>.
        /// </summary>
        /// <param name="worldPosition">World position to look at.</param>
        public void SetLookTarget(Vector3 worldPosition)
        {
            if (lookTarget == null)
            {
                return;
            }

            lookTarget.position = worldPosition;
        }

        /// <summary>
        /// Sets how strongly the gaze follows its target. The chest takes a fraction of
        /// the head weight so the torso turns with the look instead of only the neck.
        /// </summary>
        /// <param name="weight">Blend weight, clamped to 0..1.</param>
        public void SetLookWeight(float weight)
        {
            lookWeight = Mathf.Clamp01(weight);
        }

        /// <summary>
        /// Turns the leg IK and pelvis compensation on or off. Ground probing and
        /// <see cref="FootErrorMeters"/> keep running either way so the metric stays honest.
        /// </summary>
        /// <param name="grounded">True to keep the feet planted on the probed surface.</param>
        public void SetFootGroundingEnabled(bool grounded)
        {
            footGroundingEnabled = grounded;
        }

        /// <inheritdoc />
        public void BeforeGraphEvaluate(float deltaTime)
        {
            if (!IsBuilt)
            {
                return;
            }

            ProbeGround();
            UpdateFootTargets(deltaTime);
            PushConstraintWeights();

            // The RigBuilder's own Update never runs for a rig appended to a foreign
            // graph, so nothing else pushes scene values into the animation stream.
            rigBuilder.SyncLayers();
        }

        /// <inheritdoc />
        public void AfterGraphEvaluate()
        {
            if (!IsBuilt)
            {
                return;
            }

            MeasureFootError();
            RigEvaluated?.Invoke();
        }

        private void OnDestroy()
        {
            if (character != null)
            {
                character.SetRigHook(null);
            }
            IsBuilt = false;
        }

        private static int HandIndex(EchoHand hand)
        {
            return hand == EchoHand.Left ? LeftIndex : RightIndex;
        }

        private static Transform CreateChild(Transform parent, string childName)
        {
            GameObject created = new(childName);
            created.transform.SetParent(parent, false);
            created.transform.SetLocalPositionAndRotation(Vector3.zero, Quaternion.identity);
            created.transform.localScale = Vector3.one;
            return created.transform;
        }

        private static Vector3 MirrorForLeftHand(Vector3 localDirection, EchoHand hand)
        {
            // Humanoid hand bones are mirrored across the character's YZ plane, so the
            // calibrated palm axes are authored for the right hand and reflected here.
            return hand == EchoHand.Left
                ? new Vector3(-localDirection.x, localDirection.y, localDirection.z)
                : localDirection;
        }

        private static MultiAimConstraintData.Axis DominantAxis(Transform bone, Vector3 worldDirection)
        {
            Vector3 local = Quaternion.Inverse(bone.rotation) * worldDirection;
            float absoluteX = Mathf.Abs(local.x);
            float absoluteY = Mathf.Abs(local.y);
            float absoluteZ = Mathf.Abs(local.z);
            if (absoluteX >= absoluteY && absoluteX >= absoluteZ)
            {
                return local.x >= 0f
                    ? MultiAimConstraintData.Axis.X
                    : MultiAimConstraintData.Axis.X_NEG;
            }
            if (absoluteY >= absoluteZ)
            {
                return local.y >= 0f
                    ? MultiAimConstraintData.Axis.Y
                    : MultiAimConstraintData.Axis.Y_NEG;
            }
            return local.z >= 0f
                ? MultiAimConstraintData.Axis.Z
                : MultiAimConstraintData.Axis.Z_NEG;
        }

        private static bool SharesComponent(
            MultiAimConstraintData.Axis first,
            MultiAimConstraintData.Axis second)
        {
            return (int)first / 2 == (int)second / 2;
        }

        private Transform RequireBone(HumanBodyBones bone)
        {
            Transform resolved = animator.GetBoneTransform(bone);
            if (resolved == null && missingBoneName == null)
            {
                missingBoneName = bone.ToString();
            }
            return resolved;
        }

        private Transform FirstAvailableBone(params HumanBodyBones[] candidates)
        {
            foreach (HumanBodyBones bone in candidates)
            {
                Transform resolved = animator.GetBoneTransform(bone);
                if (resolved != null)
                {
                    return resolved;
                }
            }
            return null;
        }

        private void BuildPelvisGrounding()
        {
            Transform holder = CreateChild(rigRoot, "PelvisGrounding");
            pelvisGrounding = holder.gameObject.AddComponent<OverrideTransform>();
            pelvisGrounding.data.constrainedObject = hipsBone;
            pelvisGrounding.data.sourceObject = null;
            // Pivot space adds the override onto the animated pose instead of replacing
            // it, so the hips keep every bit of their authored motion and only sink.
            pelvisGrounding.data.space = OverrideTransformData.Space.Pivot;
            pelvisGrounding.data.position = Vector3.zero;
            pelvisGrounding.data.rotation = Vector3.zero;
            pelvisGrounding.data.positionWeight = 1f;
            pelvisGrounding.data.rotationWeight = 0f;
            pelvisGrounding.weight = 1f;
        }

        private void BuildArmIk(
            int index,
            string constraintName,
            Transform upperArm,
            Transform lowerArm,
            Transform hand,
            Transform hintParent,
            float sideSign)
        {
            float reach = Mathf.Max(0.2f, Calibration.reachMeters);
            Vector3 hintPosition =
                lowerArm.position -
                animator.transform.forward * (reach * 0.45f) +
                animator.transform.right * (sideSign * reach * 0.18f);

            TwoBoneIKConstraint constraint = CreateTwoBoneIk(
                constraintName,
                upperArm,
                lowerArm,
                hand,
                hintParent,
                hintPosition,
                hand.position,
                hand.rotation,
                out Transform target);
            constraint.data.targetPositionWeight = 1f;
            constraint.data.targetRotationWeight = 1f;
            constraint.data.hintWeight = 0.85f;
            constraint.weight = 0f;

            armConstraints[index] = constraint;
            handTargets[index] = target;
        }

        private void BuildLegIk(
            int index,
            string constraintName,
            Transform upperLeg,
            Transform lowerLeg,
            Transform foot,
            float sideSign)
        {
            float reach = Mathf.Max(0.2f, Calibration.reachMeters);
            Vector3 hintPosition =
                lowerLeg.position +
                animator.transform.forward * (reach * 0.6f) +
                animator.transform.right * (sideSign * reach * 0.1f);

            TwoBoneIKConstraint constraint = CreateTwoBoneIk(
                constraintName,
                upperLeg,
                lowerLeg,
                foot,
                hipsBone,
                hintPosition,
                foot.position,
                foot.rotation,
                out Transform target);
            constraint.data.targetPositionWeight = 1f;
            // Position only. Re-aiming the ankle from its own solved rotation every frame
            // accumulates the ground tilt into the pose, so the foot keeps the rotation
            // the clip authored and only its height is corrected.
            constraint.data.targetRotationWeight = 0f;
            constraint.data.hintWeight = 1f;
            constraint.weight = 1f;

            legConstraints[index] = constraint;
            footTargets[index] = target;
        }

        private TwoBoneIKConstraint CreateTwoBoneIk(
            string constraintName,
            Transform root,
            Transform mid,
            Transform tip,
            Transform hintParent,
            Vector3 hintWorldPosition,
            Vector3 targetWorldPosition,
            Quaternion targetWorldRotation,
            out Transform target)
        {
            Transform holder = CreateChild(rigRoot, constraintName);
            target = CreateChild(holder, $"{constraintName}_Target");
            target.SetPositionAndRotation(targetWorldPosition, targetWorldRotation);

            // The hint rides the torso or the hips rather than the limb itself, so both
            // limbs keep bending the same way instead of flipping as the arm swings.
            Transform hint = CreateChild(hintParent, $"{constraintName}_Hint");
            hint.position = hintWorldPosition;

            TwoBoneIKConstraint constraint = holder.gameObject.AddComponent<TwoBoneIKConstraint>();
            constraint.data.root = root;
            constraint.data.mid = mid;
            constraint.data.tip = tip;
            constraint.data.target = target;
            constraint.data.hint = hint;
            constraint.data.maintainTargetPositionOffset = false;
            constraint.data.maintainTargetRotationOffset = false;
            return constraint;
        }

        private void BuildGaze(Transform torsoBone)
        {
            lookTarget = CreateChild(rigRoot, "LookTarget");
            lookTarget.position = headBone.position + animator.transform.forward * 2f;

            chestAim = CreateAim("ChestAim", torsoBone, 40f);
            headAim = CreateAim("HeadAim", headBone, 70f);
        }

        private MultiAimConstraint CreateAim(string constraintName, Transform bone, float limitDegrees)
        {
            Transform holder = CreateChild(rigRoot, constraintName);
            MultiAimConstraint constraint = holder.gameObject.AddComponent<MultiAimConstraint>();

            WeightedTransformArray sources = new(0);
            sources.Add(new WeightedTransform(lookTarget, 1f));

            MultiAimConstraintData.Axis aimAxis = DominantAxis(bone, animator.transform.forward);
            MultiAimConstraintData.Axis upAxis = DominantAxis(bone, animator.transform.up);
            if (SharesComponent(aimAxis, upAxis))
            {
                upAxis = MultiAimConstraintData.Axis.Y;
                if (SharesComponent(aimAxis, upAxis))
                {
                    upAxis = MultiAimConstraintData.Axis.Z;
                }
            }

            constraint.data.constrainedObject = bone;
            constraint.data.sourceObjects = sources;
            constraint.data.aimAxis = aimAxis;
            constraint.data.upAxis = upAxis;
            constraint.data.worldUpType = MultiAimConstraintData.WorldUpType.SceneUp;
            constraint.data.maintainOffset = false;
            constraint.data.constrainedXAxis = true;
            constraint.data.constrainedYAxis = true;
            constraint.data.constrainedZAxis = true;
            constraint.data.limits = new Vector2(-limitDegrees, limitDegrees);
            constraint.weight = 0f;
            return constraint;
        }

        private void BuildPalmSocket(int index, EchoHand hand, HumanBodyBones middleProximal)
        {
            Transform handBone = handBones[index];
            Transform socket = CreateChild(
                handBone,
                hand == EchoHand.Left ? "PalmSocket_Left" : "PalmSocket_Right");

            Vector3 fingerDirection;
            Vector3 palmCentre;
            Transform knuckle = animator.GetBoneTransform(middleProximal);
            if (knuckle != null && (knuckle.position - handBone.position).sqrMagnitude > 1e-8f)
            {
                fingerDirection = (knuckle.position - handBone.position).normalized;
                palmCentre = Vector3.Lerp(handBone.position, knuckle.position, 0.45f);
            }
            else
            {
                fingerDirection = handBone.TransformDirection(
                    MirrorForLeftHand(Calibration.palmForwardLocal, hand)).normalized;
                float palmReach = Mathf.Max(0.02f, Calibration.reachMeters * 0.06f);
                palmCentre = handBone.position + fingerDirection * palmReach;
            }

            if (fingerDirection.sqrMagnitude < 1e-8f)
            {
                Debug.LogWarning(
                    $"[Echo Rig] Palm forward axis for {socket.name} was degenerate; " +
                    "the socket falls back to the hand bone orientation. Check " +
                    "EchoCharacterCalibration.palmForwardLocal.");
                palmSockets[index] = socket;
                return;
            }

            Vector3 palmNormal = Vector3.ProjectOnPlane(
                handBone.TransformDirection(MirrorForLeftHand(Calibration.palmUpLocal, hand)),
                fingerDirection);
            if (palmNormal.sqrMagnitude < 1e-8f)
            {
                palmNormal = Vector3.ProjectOnPlane(animator.transform.up, fingerDirection);
            }
            if (palmNormal.sqrMagnitude < 1e-8f)
            {
                palmNormal = Vector3.ProjectOnPlane(animator.transform.forward, fingerDirection);
            }

            socket.SetPositionAndRotation(
                palmCentre,
                Quaternion.LookRotation(fingerDirection, palmNormal.normalized));
            palmSockets[index] = socket;
        }

        private void BuildEyeAnchor()
        {
            EyeAnchor = CreateChild(headBone, "EyeAnchor");
            Transform leftEye = animator.GetBoneTransform(HumanBodyBones.LeftEye);
            Transform rightEye = animator.GetBoneTransform(HumanBodyBones.RightEye);
            if (leftEye != null && rightEye != null)
            {
                EyeAnchor.SetPositionAndRotation(
                    Vector3.Lerp(leftEye.position, rightEye.position, 0.5f),
                    Quaternion.LookRotation(animator.transform.forward, animator.transform.up));
                return;
            }

            float headScale = Mathf.Max(0.01f, Calibration.heightMeters / 1.78f);
            EyeAnchor.SetPositionAndRotation(
                headBone.position + animator.transform.up * (0.08f * headScale) +
                animator.transform.forward * (0.09f * headScale),
                Quaternion.LookRotation(animator.transform.forward, animator.transform.up));
        }

        private void ProbeGround()
        {
            float probeAbove = Mathf.Max(0.05f, Calibration.heightMeters * 0.15f);
            float probeBelow = Mathf.Max(0.2f, Calibration.heightMeters * 0.5f);
            for (int index = 0; index < footBones.Length; index++)
            {
                Vector3 footPosition = footBones[index].position;
                Vector3 origin = footPosition + Vector3.up * probeAbove;
                footGrounded[index] = TryProbeGround(
                    origin,
                    probeAbove + probeBelow,
                    out Vector3 point,
                    out Vector3 normal);
                footGroundPoints[index] = point;
                footGroundNormals[index] = normal;
            }
        }

        private bool TryProbeGround(
            Vector3 origin,
            float distance,
            out Vector3 point,
            out Vector3 normal)
        {
            point = Vector3.zero;
            normal = Vector3.up;
            int hitCount = Physics.RaycastNonAlloc(
                new Ray(origin, Vector3.down),
                groundProbeBuffer,
                distance,
                groundMask,
                QueryTriggerInteraction.Ignore);

            float nearest = float.PositiveInfinity;
            bool found = false;
            for (int index = 0; index < hitCount; index++)
            {
                RaycastHit hit = groundProbeBuffer[index];
                if (hit.collider == null || hit.distance >= nearest)
                {
                    continue;
                }
                // The character's own capsule and any collider on its visual would
                // otherwise be the first thing the foot probe finds.
                if (characterRoot != null && hit.collider.transform.IsChildOf(characterRoot))
                {
                    continue;
                }

                nearest = hit.distance;
                point = hit.point;
                normal = hit.normal;
                found = true;
            }
            return found;
        }

        private void UpdateFootTargets(float deltaTime)
        {
            float soleOffset = Calibration.soleOffsetMeters;
            float requestedDrop = 0f;
            for (int index = 0; index < footTargets.Length; index++)
            {
                if (!footGrounded[index])
                {
                    continue;
                }

                Vector3 desired = footGroundPoints[index] + footGroundNormals[index] * soleOffset;
                footTargets[index].position = desired;

                float reachDown = footBones[index].position.y - desired.y;
                if (reachDown > requestedDrop)
                {
                    requestedDrop = reachDown;
                }
            }

            // Hard clamp. An unclamped drop is exactly how a character ends up doing the
            // splits on a step or sinking through the floor on a slope.
            float clampedDrop = Mathf.Clamp(
                requestedDrop,
                0f,
                Mathf.Max(0f, Calibration.pelvisMaxDropMeters));
            if (!footGroundingEnabled)
            {
                clampedDrop = 0f;
            }
            appliedPelvisDrop = Mathf.MoveTowards(
                appliedPelvisDrop,
                clampedDrop,
                Mathf.Max(0f, deltaTime) * PelvisDropMetersPerSecond);

            float hipsScale = hipsBone.parent != null ? hipsBone.parent.lossyScale.y : 1f;
            if (Mathf.Abs(hipsScale) < 0.0001f)
            {
                hipsScale = 1f;
            }
            // Pivot space adds hipsLocalRotation * position onto the animated local
            // position, so the world drop has to come back through both the bone
            // rotation and the parent's scale to stay measured in metres.
            pelvisGrounding.data.position =
                Quaternion.Inverse(hipsBone.rotation) * (Vector3.down * (appliedPelvisDrop / hipsScale));
        }

        private void PushConstraintWeights()
        {
            armConstraints[RightIndex].weight = handWeights[RightIndex];
            armConstraints[LeftIndex].weight = handWeights[LeftIndex];
            headAim.weight = lookWeight;
            chestAim.weight = lookWeight * ChestGazeShare;
            pelvisGrounding.weight = footGroundingEnabled ? 1f : 0f;
            for (int index = 0; index < legConstraints.Length; index++)
            {
                // A foot with nothing under it keeps the animated pose rather than being
                // dragged toward a stale target.
                legConstraints[index].weight =
                    footGroundingEnabled && footGrounded[index] ? 1f : 0f;
            }
        }

        private void MeasureFootError()
        {
            float soleOffset = Calibration.soleOffsetMeters;
            float largest = 0f;
            for (int index = 0; index < footBones.Length; index++)
            {
                if (!footGrounded[index])
                {
                    continue;
                }

                float error = Mathf.Abs(
                    footBones[index].position.y - (footGroundPoints[index].y + soleOffset));
                if (error > largest)
                {
                    largest = error;
                }
            }
            FootErrorMeters = largest;
        }

        private void Clear()
        {
            if (rigRoot != null)
            {
                Destroy(rigRoot.gameObject);
            }
            // Palm sockets and the eye anchor live under bones, not under the rig root,
            // so they have to be cleaned up by hand.
            if (EyeAnchor != null)
            {
                Destroy(EyeAnchor.gameObject);
            }
            foreach (Transform socket in palmSockets)
            {
                if (socket != null)
                {
                    Destroy(socket.gameObject);
                }
            }
            rigRoot = null;
            rig = null;
            pelvisGrounding = null;
            headAim = null;
            chestAim = null;
            lookTarget = null;
            EyeAnchor = null;
            for (int index = 0; index < 2; index++)
            {
                armConstraints[index] = null;
                legConstraints[index] = null;
                handTargets[index] = null;
                footTargets[index] = null;
                palmSockets[index] = null;
            }
            IsBuilt = false;
        }
    }
}
