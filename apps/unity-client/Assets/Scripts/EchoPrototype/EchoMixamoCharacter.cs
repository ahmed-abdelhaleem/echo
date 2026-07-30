using UnityEngine;
using UnityEngine.Animations;
using UnityEngine.Playables;

namespace Echo.FreePrototype
{
    /// <summary>
    /// Plays an imported Mixamo clip without requiring an authored Animator Controller.
    /// This keeps the free asset pipeline deterministic while scenes are still prototypes.
    /// </summary>
    /// <remarks>
    /// The graph runs in <see cref="DirectorUpdateMode.Manual"/> and is evaluated from a
    /// single <c>LateUpdate</c> that owns the whole frame ordering. An optional
    /// <see cref="IEchoRigHook"/> writes its scene inputs immediately before the
    /// evaluation and reads the solved pose immediately after it, so a rig appended to
    /// this graph never lags the animation by a frame.
    /// </remarks>
    public sealed class EchoMixamoCharacter : MonoBehaviour
    {
        private PlayableGraph graph;
        private AnimationMixerPlayable locomotionMixer;
        private AnimationMixerPlayable idlePoseMixer;
        private AnimationClipPlayable idlePlayable;
        private AnimationClipPlayable idleMirrorPlayable;
        private AnimationClipPlayable walkPlayable;
        private AnimationClip idleClip;
        private AnimationClip walkClip;
        private Transform visualRoot;
        private IEchoRigHook rigHook;
        private float targetLocomotion;
        private float currentLocomotion;

        /// <summary>
        /// The manually evaluated animation graph. Rigs append their own outputs to this
        /// graph rather than creating a second one that would fight for the Animator.
        /// </summary>
        public PlayableGraph Graph => graph;

        /// <summary>True once <see cref="Configure"/> has produced a usable graph.</summary>
        public bool IsGraphValid => graph.IsValid();

        /// <summary>
        /// Registers the single hook that participates in graph evaluation, or clears it
        /// with null. Registering a hook also switches this component off the legacy
        /// renderer-based visual grounding, because the hook is expected to ground the
        /// feet properly with IK.
        /// </summary>
        /// <param name="hook">The hook to drive, or null to detach.</param>
        public void SetRigHook(IEchoRigHook hook)
        {
            rigHook = hook;
        }

        public bool Configure(Animator animator, AnimationClip animationClip, float normalizedStartTime)
        {
            return Configure(animator, null, animationClip, normalizedStartTime);
        }

        public bool Configure(
            Animator animator,
            AnimationClip dedicatedIdleClip,
            AnimationClip animationClip,
            float normalizedStartTime)
        {
            if (animator == null || animationClip == null || animationClip.length <= 0f)
            {
                return false;
            }

            if (graph.IsValid())
            {
                graph.Destroy();
            }

            walkClip = animationClip;
            idleClip = dedicatedIdleClip != null && dedicatedIdleClip.length > 0f
                ? dedicatedIdleClip
                : animationClip;
            visualRoot = animator.transform;
            while (visualRoot.parent != null && visualRoot.parent != transform)
            {
                visualRoot = visualRoot.parent;
            }
            graph = PlayableGraph.Create("EchoMixamoCharacter");
            // Manual evaluation is what lets a rig hook bracket the evaluation; Unity no
            // longer advances this graph on its own.
            graph.SetTimeUpdateMode(DirectorUpdateMode.Manual);
            AnimationPlayableOutput output = AnimationPlayableOutput.Create(graph, "Animation", animator);
            locomotionMixer = AnimationMixerPlayable.Create(graph, 2);
            idlePoseMixer = AnimationMixerPlayable.Create(graph, 2);
            idlePlayable = AnimationClipPlayable.Create(graph, idleClip);
            idleMirrorPlayable = AnimationClipPlayable.Create(graph, idleClip);
            walkPlayable = AnimationClipPlayable.Create(graph, walkClip);
            idlePoseMixer.ConnectInput(0, idlePlayable, 0);
            idlePoseMixer.ConnectInput(1, idleMirrorPlayable, 0);
            locomotionMixer.ConnectInput(0, idlePoseMixer, 0);
            locomotionMixer.ConnectInput(1, walkPlayable, 0);
            idlePoseMixer.SetInputWeight(0, 1f);
            idlePoseMixer.SetInputWeight(1, 0f);
            locomotionMixer.SetInputWeight(0, 1f);
            locomotionMixer.SetInputWeight(1, 0f);
            output.SetSourcePlayable(locomotionMixer);

            idlePlayable.SetApplyFootIK(true);
            idlePlayable.SetApplyPlayableIK(false);
            idleMirrorPlayable.SetApplyFootIK(true);
            idleMirrorPlayable.SetApplyPlayableIK(false);
            walkPlayable.SetApplyFootIK(true);
            walkPlayable.SetApplyPlayableIK(false);
            walkPlayable.SetTime(Mathf.Clamp01(normalizedStartTime) * walkClip.length);
            walkPlayable.SetSpeed(0.72f);

            if (dedicatedIdleClip != null)
            {
                idlePlayable.SetSpeed(1f);
                idleMirrorPlayable.SetSpeed(1f);
            }
            else
            {
                // Average opposite contact phases into a centered stance when the
                // free asset set does not include a dedicated idle animation.
                idlePlayable.SetTime(0f);
                idleMirrorPlayable.SetTime(idleClip.length * 0.5f);
                idlePlayable.SetSpeed(0f);
                idleMirrorPlayable.SetSpeed(0f);
                idlePoseMixer.SetInputWeight(0, 0.5f);
                idlePoseMixer.SetInputWeight(1, 0.5f);
            }

            currentLocomotion = 0f;
            targetLocomotion = 0f;
            // Play still matters under manual evaluation: it puts every playable into the
            // Playing state so their local time advances when the graph is evaluated.
            graph.Play();
            return graph.IsValid();
        }

        public void SetPlaybackSpeed(float speed)
        {
            SetLocomotion(speed);
        }

        public void SetLocomotion(float normalizedSpeed)
        {
            targetLocomotion = Mathf.Clamp01(normalizedSpeed);
        }

        private void LateUpdate()
        {
            if (!IsPlayableSetValid())
            {
                return;
            }

            float deltaTime = Time.deltaTime;
            AdvanceLocomotion(deltaTime);
            WrapLoopingClips();

            rigHook?.BeforeGraphEvaluate(deltaTime);
            graph.Evaluate(deltaTime);
            rigHook?.AfterGraphEvaluate();

            if (rigHook == null)
            {
                ApplyLegacyVisualGrounding();
            }
        }

        private bool IsPlayableSetValid()
        {
            return graph.IsValid() && locomotionMixer.IsValid() &&
                idlePoseMixer.IsValid() && idlePlayable.IsValid() &&
                idleMirrorPlayable.IsValid() && walkPlayable.IsValid();
        }

        private void AdvanceLocomotion(float deltaTime)
        {
            currentLocomotion = Mathf.MoveTowards(
                currentLocomotion,
                targetLocomotion,
                deltaTime * 5.5f);
            float walkWeight = Mathf.SmoothStep(0f, 1f, currentLocomotion);
            locomotionMixer.SetInputWeight(0, 1f - walkWeight);
            locomotionMixer.SetInputWeight(1, walkWeight);
            walkPlayable.SetSpeed(Mathf.Lerp(0.72f, 1.05f, currentLocomotion));
        }

        private void WrapLoopingClips()
        {
            LoopClip(idlePlayable, idleClip);
            LoopClip(idleMirrorPlayable, idleClip);
            LoopClip(walkPlayable, walkClip);
        }

        /// <summary>
        /// Legacy path for un-rigged characters. NPCs and crowd pedestrians use this
        /// component without an interaction rig, and their imported walk clips can lift
        /// the skinned mesh above an otherwise correctly grounded CharacterController.
        /// Offsetting only the visual root keeps them planted. Characters that do have a
        /// rig ground their feet with real IK instead and must never run this.
        /// </summary>
        private void ApplyLegacyVisualGrounding()
        {
            if (visualRoot == null)
            {
                return;
            }

            Renderer[] renderers = visualRoot.GetComponentsInChildren<Renderer>(true);
            if (renderers.Length == 0)
            {
                return;
            }

            float lowestVisiblePoint = float.PositiveInfinity;
            foreach (Renderer visiblePart in renderers)
            {
                lowestVisiblePoint = Mathf.Min(lowestVisiblePoint, visiblePart.bounds.min.y);
            }
            if (float.IsPositiveInfinity(lowestVisiblePoint))
            {
                return;
            }

            float correction = transform.position.y - lowestVisiblePoint;
            if (Mathf.Abs(correction) > 0.0005f)
            {
                visualRoot.position += Vector3.up * correction;
            }
        }

        private static void LoopClip(AnimationClipPlayable playable, AnimationClip animationClip)
        {
            if (animationClip == null || animationClip.length <= 0f)
            {
                return;
            }

            double currentTime = playable.GetTime();
            if (currentTime >= animationClip.length)
            {
                playable.SetTime(currentTime % animationClip.length);
                playable.SetDone(false);
            }
        }

        private void OnDestroy()
        {
            if (graph.IsValid())
            {
                graph.Destroy();
            }
        }
    }
}
