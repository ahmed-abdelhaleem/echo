using System.Collections;
using System.Collections.Generic;
using UnityEngine;

namespace Echo.FreePrototype
{
    /// <summary>
    /// Plays a short physical response when a vignette interaction resolves,
    /// so noticing something is embodied instead of text-only. Actions are
    /// deterministic, reversible, and never gate story progression: the
    /// vignette state machine advances immediately and the motion follows.
    /// </summary>
    public sealed class EchoInteractionActionDirector : MonoBehaviour
    {
        private abstract class PropAction
        {
            public bool IsRunning { get; set; }
            public int TimesPlayed { get; set; }
        }

        private sealed class FocusAction : PropAction
        {
            public Transform Focus;
        }

        private sealed class PickupAction : PropAction
        {
            public Transform Prop;
            public HumanBodyBones HandBone;
            public Vector3 PositionFromHand;
            public Quaternion RotationFromPlayer;
            public float ReachSeconds;
            public float HoldSeconds;
            public float ReturnSeconds;
            public Vector3 RestPosition;
            public Quaternion RestRotation;
        }

        private sealed class HandleAction : PropAction
        {
            public Transform Prop;
            public float TravelMeters;
            public float TiltDegrees;
            public float ReachSeconds;
            public float HoldSeconds;
            public float ReturnSeconds;
            public Vector3 RestPosition;
            public Quaternion RestRotation;
        }

        private sealed class TransportAction : PropAction
        {
            public Transform Prop;
            public Vector3 TargetLocalPosition;
            public Quaternion TargetLocalRotation;
            public float ArcHeight;
            public Transform SettleTarget;
            public Vector3 RestPosition;
            public Quaternion RestRotation;
        }

        private sealed class SettleAction : PropAction
        {
            public Transform Prop;
            public Quaternion RelaxedRotation;
            public Vector3 RelaxedScale;
            public Quaternion RestRotation;
            public Vector3 RestScale;
        }

        private sealed class TurnNpcAction : PropAction
        {
            public Transform Npc;
            public Quaternion RestRotation;
        }

        private readonly Dictionary<string, List<PropAction>> actions = new();
        private Transform player;

        public int RegisteredActionCount
        {
            get
            {
                int count = 0;
                foreach (List<PropAction> list in actions.Values)
                {
                    count += list.Count;
                }
                return count;
            }
        }

        public bool HasActionFor(string interactionId)
        {
            return actions.ContainsKey(interactionId);
        }

        public int TimesPlayed(string interactionId)
        {
            if (!actions.TryGetValue(interactionId, out List<PropAction> list))
            {
                return 0;
            }
            int most = 0;
            foreach (PropAction action in list)
            {
                most = Mathf.Max(most, action.TimesPlayed);
            }
            return most;
        }

        public bool IsRunning(string interactionId)
        {
            if (!actions.TryGetValue(interactionId, out List<PropAction> list))
            {
                return false;
            }
            foreach (PropAction action in list)
            {
                if (action.IsRunning)
                {
                    return true;
                }
            }
            return false;
        }

        public void ConfigurePlayer(Transform playerTransform)
        {
            player = playerTransform;
        }

        /// <summary>
        /// Turns the playable character toward a supported scene object without
        /// moving the object itself. Until authored hand/contact animation is
        /// available, this is more believable than making props float.
        /// </summary>
        public void RegisterFocus(string interactionId, Transform focus)
        {
            if (focus == null)
            {
                return;
            }

            AddAction(interactionId, new FocusAction { Focus = focus });
        }

        /// <summary>
        /// Slowly lifts a small prop into a pose anchored to one of the
        /// character's hands, follows that hand while it is held, and then
        /// returns it exactly to its authored support pose.
        /// </summary>
        public void RegisterHandPickup(
            string interactionId,
            Transform prop,
            HumanBodyBones handBone,
            Vector3 positionFromHand,
            Vector3 rotationFromPlayer,
            float reachSeconds = 1.15f,
            float holdSeconds = 1.6f,
            float returnSeconds = 1.1f)
        {
            if (prop == null)
            {
                return;
            }

            AddAction(interactionId, new PickupAction
            {
                Prop = prop,
                HandBone = handBone,
                PositionFromHand = positionFromHand,
                RotationFromPlayer = Quaternion.Euler(rotationFromPlayer),
                ReachSeconds = Mathf.Max(0.65f, reachSeconds),
                HoldSeconds = holdSeconds,
                ReturnSeconds = Mathf.Max(0.65f, returnSeconds),
                RestPosition = prop.localPosition,
                RestRotation = prop.localRotation
            });
        }

        /// <summary>
        /// Gives a large grounded prop a small hand-directed pull and tilt
        /// instead of lifting its centre into the air like a handheld object.
        /// </summary>
        public void RegisterGroundedHandle(
            string interactionId,
            Transform prop,
            float travelMeters = 0.18f,
            float tiltDegrees = 5f,
            float reachSeconds = 1.15f,
            float holdSeconds = 0.65f,
            float returnSeconds = 1.05f)
        {
            if (prop == null)
            {
                return;
            }

            AddAction(interactionId, new HandleAction
            {
                Prop = prop,
                TravelMeters = Mathf.Clamp(travelMeters, 0.05f, 0.3f),
                TiltDegrees = Mathf.Clamp(tiltDegrees, 1f, 8f),
                ReachSeconds = Mathf.Max(0.65f, reachSeconds),
                HoldSeconds = Mathf.Max(0.2f, holdSeconds),
                ReturnSeconds = Mathf.Max(0.65f, returnSeconds),
                RestPosition = prop.localPosition,
                RestRotation = prop.localRotation
            });
        }

        /// <summary>
        /// The prop arcs from its rest pose to a destination and stays there —
        /// used for packing the folded clothes into the suitcase. An optional
        /// settle target rocks briefly when the item lands.
        /// </summary>
        public void RegisterTransport(
            string interactionId,
            Transform prop,
            Vector3 targetLocalPosition,
            Quaternion targetLocalRotation,
            float arcHeight = 0.55f,
            Transform settleTarget = null)
        {
            if (prop == null)
            {
                return;
            }

            AddAction(interactionId, new TransportAction
            {
                Prop = prop,
                TargetLocalPosition = targetLocalPosition,
                TargetLocalRotation = targetLocalRotation,
                ArcHeight = arcHeight,
                SettleTarget = settleTarget,
                RestPosition = prop.localPosition,
                RestRotation = prop.localRotation
            });
        }

        /// <summary>
        /// The prop eases from its current crumpled pose to a relaxed pose —
        /// used to smooth the unmade blanket. Replays restore the crumple
        /// first so the action stays observable after a vignette restart.
        /// </summary>
        public void RegisterSettle(
            string interactionId,
            Transform prop,
            Quaternion relaxedRotation,
            Vector3 relaxedScale)
        {
            if (prop == null)
            {
                return;
            }

            AddAction(interactionId, new SettleAction
            {
                Prop = prop,
                RelaxedRotation = relaxedRotation,
                RelaxedScale = relaxedScale,
                RestRotation = prop.localRotation,
                RestScale = prop.localScale
            });
        }

        /// <summary>
        /// A nearby character turns to face the player while they speak.
        /// </summary>
        public void RegisterNpcTurn(string interactionId, Transform npc)
        {
            if (npc == null)
            {
                return;
            }

            AddAction(interactionId, new TurnNpcAction
            {
                Npc = npc,
                RestRotation = npc.localRotation
            });
        }

        public void Play(string interactionId)
        {
            if (!isActiveAndEnabled ||
                !actions.TryGetValue(interactionId, out List<PropAction> list))
            {
                return;
            }

            foreach (PropAction action in list)
            {
                if (action.IsRunning)
                {
                    continue;
                }
                switch (action)
                {
                    case FocusAction focus:
                        StartCoroutine(RunFocus(focus));
                        break;
                    case PickupAction pickup:
                        StartCoroutine(RunPickup(pickup));
                        break;
                    case HandleAction handle:
                        StartCoroutine(RunHandle(handle));
                        break;
                    case TransportAction transport:
                        StartCoroutine(RunTransport(transport));
                        break;
                    case SettleAction settle:
                        StartCoroutine(RunSettle(settle));
                        break;
                    case TurnNpcAction turn:
                        StartCoroutine(RunNpcTurn(turn));
                        break;
                }
            }
        }

        public void ResetActions()
        {
            StopAllCoroutines();
            foreach (List<PropAction> list in actions.Values)
            {
                foreach (PropAction action in list)
                {
                    action.IsRunning = false;
                    switch (action)
                    {
                        case FocusAction:
                            break;
                        case PickupAction pickup when pickup.Prop != null:
                            pickup.Prop.SetLocalPositionAndRotation(
                                pickup.RestPosition,
                                pickup.RestRotation);
                            break;
                        case HandleAction handle when handle.Prop != null:
                            handle.Prop.SetLocalPositionAndRotation(
                                handle.RestPosition,
                                handle.RestRotation);
                            break;
                        case TransportAction transport when transport.Prop != null:
                            transport.Prop.SetLocalPositionAndRotation(
                                transport.RestPosition,
                                transport.RestRotation);
                            break;
                        case SettleAction settle when settle.Prop != null:
                            settle.Prop.localRotation = settle.RestRotation;
                            settle.Prop.localScale = settle.RestScale;
                            break;
                        case TurnNpcAction turn when turn.Npc != null:
                            turn.Npc.localRotation = turn.RestRotation;
                            break;
                    }
                }
            }
        }

        private void AddAction(string interactionId, PropAction action)
        {
            if (!actions.TryGetValue(interactionId, out List<PropAction> list))
            {
                list = new List<PropAction>();
                actions[interactionId] = list;
            }
            list.Add(action);
        }

        private IEnumerator RunFocus(FocusAction action)
        {
            action.IsRunning = true;
            action.TimesPlayed++;
            if (action.Focus != null)
            {
                yield return TurnPlayerToward(action.Focus.position);
            }
            action.IsRunning = false;
        }

        private IEnumerator RunPickup(PickupAction action)
        {
            action.IsRunning = true;
            action.TimesPlayed++;
            Transform prop = action.Prop;
            Vector3 startPosition = prop.position;
            Quaternion startRotation = prop.rotation;

            yield return TurnPlayerToward(startPosition);

            Transform hand = FindHand(action.HandBone);
            yield return MovePropToHand(
                prop,
                hand,
                action,
                startPosition,
                startRotation,
                action.ReachSeconds,
                0.06f);

            float held = 0f;
            while (held < action.HoldSeconds)
            {
                held += Time.deltaTime;
                GetHeldPose(hand, action, out Vector3 heldPosition, out Quaternion heldRotation);
                prop.SetPositionAndRotation(heldPosition, heldRotation);
                yield return null;
            }

            Vector3 restWorldPosition = action.Prop.parent != null
                ? action.Prop.parent.TransformPoint(action.RestPosition)
                : action.RestPosition;
            Quaternion restWorldRotation = action.Prop.parent != null
                ? action.Prop.parent.rotation * action.RestRotation
                : action.RestRotation;
            yield return MoveProp(
                prop,
                prop.position,
                restWorldPosition,
                prop.rotation,
                restWorldRotation,
                action.ReturnSeconds,
                0.04f);
            prop.SetLocalPositionAndRotation(action.RestPosition, action.RestRotation);
            action.IsRunning = false;
        }

        private IEnumerator RunHandle(HandleAction action)
        {
            action.IsRunning = true;
            action.TimesPlayed++;
            Transform prop = action.Prop;
            Vector3 startPosition = prop.position;
            Quaternion startRotation = prop.rotation;

            yield return TurnPlayerToward(startPosition);

            Vector3 towardHand = player != null
                ? player.position - startPosition
                : -prop.forward;
            towardHand.y = 0f;
            if (towardHand.sqrMagnitude < 0.001f)
            {
                towardHand = -prop.forward;
            }
            towardHand.Normalize();
            Vector3 handledPosition = startPosition + towardHand * action.TravelMeters;
            Quaternion handledRotation =
                Quaternion.AngleAxis(action.TiltDegrees, Vector3.Cross(Vector3.up, towardHand)) *
                startRotation;
            yield return MoveProp(
                prop,
                startPosition,
                handledPosition,
                startRotation,
                handledRotation,
                action.ReachSeconds,
                0.025f);

            float held = 0f;
            while (held < action.HoldSeconds)
            {
                held += Time.deltaTime;
                yield return null;
            }

            yield return MoveProp(
                prop,
                prop.position,
                startPosition,
                prop.rotation,
                startRotation,
                action.ReturnSeconds,
                0.02f);
            prop.SetLocalPositionAndRotation(action.RestPosition, action.RestRotation);
            action.IsRunning = false;
        }

        private IEnumerator RunTransport(TransportAction action)
        {
            action.IsRunning = true;
            action.TimesPlayed++;
            Transform prop = action.Prop;
            Vector3 startLocal = prop.localPosition;
            Quaternion startRotation = prop.localRotation;

            yield return TurnPlayerToward(prop.position);

            float duration = 0.85f;
            float elapsed = 0f;
            while (elapsed < duration)
            {
                elapsed += Time.deltaTime;
                float progress = Mathf.SmoothStep(0f, 1f, Mathf.Clamp01(elapsed / duration));
                Vector3 flat = Vector3.Lerp(startLocal, action.TargetLocalPosition, progress);
                flat.y += Mathf.Sin(progress * Mathf.PI) * action.ArcHeight;
                prop.localPosition = flat;
                prop.localRotation = Quaternion.Slerp(startRotation, action.TargetLocalRotation, progress);
                yield return null;
            }
            prop.localPosition = action.TargetLocalPosition;
            prop.localRotation = action.TargetLocalRotation;

            if (action.SettleTarget != null)
            {
                yield return RockOnce(action.SettleTarget, 1.6f);
            }

            // Restore the rest pose only when the vignette restarts: the
            // packed item deliberately stays packed within one playthrough.
            action.IsRunning = false;
        }

        private IEnumerator RunSettle(SettleAction action)
        {
            action.IsRunning = true;
            action.TimesPlayed++;
            Transform prop = action.Prop;

            yield return TurnPlayerToward(prop.position);

            if (action.TimesPlayed > 1)
            {
                // Restore the crumple instantly so a replayed notice still moves.
                prop.localRotation = action.RestRotation;
                prop.localScale = action.RestScale;
            }

            Quaternion crumpled = prop.localRotation;
            Vector3 crumpledScale = prop.localScale;
            float duration = 1.15f;
            float elapsed = 0f;
            while (elapsed < duration)
            {
                elapsed += Time.deltaTime;
                float progress = Mathf.SmoothStep(0f, 1f, Mathf.Clamp01(elapsed / duration));
                prop.localRotation = Quaternion.Slerp(crumpled, action.RelaxedRotation, progress);
                prop.localScale = Vector3.Lerp(crumpledScale, action.RelaxedScale, progress);
                yield return null;
            }
            prop.localRotation = action.RelaxedRotation;
            prop.localScale = action.RelaxedScale;
            action.IsRunning = false;
        }

        private IEnumerator RunNpcTurn(TurnNpcAction action)
        {
            action.IsRunning = true;
            action.TimesPlayed++;
            Transform npc = action.Npc;
            if (player == null)
            {
                action.IsRunning = false;
                yield break;
            }

            Quaternion start = npc.rotation;
            Vector3 toPlayer = player.position - npc.position;
            toPlayer.y = 0f;
            if (toPlayer.sqrMagnitude < 0.001f)
            {
                action.IsRunning = false;
                yield break;
            }

            Quaternion facing = Quaternion.LookRotation(toPlayer.normalized, Vector3.up);
            float duration = 0.45f;
            float elapsed = 0f;
            while (elapsed < duration)
            {
                elapsed += Time.deltaTime;
                npc.rotation = Quaternion.Slerp(start, facing, Mathf.SmoothStep(0f, 1f, elapsed / duration));
                yield return null;
            }
            npc.rotation = facing;
            action.IsRunning = false;
        }

        private IEnumerator TurnPlayerToward(Vector3 focus)
        {
            if (player == null)
            {
                yield break;
            }

            Vector3 direction = focus - player.position;
            direction.y = 0f;
            if (direction.sqrMagnitude < 0.001f)
            {
                yield break;
            }

            Quaternion start = player.rotation;
            Quaternion target = Quaternion.LookRotation(direction.normalized, Vector3.up);
            float duration = 0.32f;
            float elapsed = 0f;
            while (elapsed < duration)
            {
                elapsed += Time.deltaTime;
                player.rotation = Quaternion.Slerp(start, target, Mathf.SmoothStep(0f, 1f, elapsed / duration));
                yield return null;
            }
            player.rotation = target;
        }

        private IEnumerator MoveProp(
            Transform prop,
            Vector3 fromPosition,
            Vector3 toPosition,
            Quaternion fromRotation,
            Quaternion toRotation,
            float duration,
            float arcHeight)
        {
            float elapsed = 0f;
            while (elapsed < duration)
            {
                elapsed += Time.deltaTime;
                float progress = Mathf.SmoothStep(0f, 1f, Mathf.Clamp01(elapsed / duration));
                Vector3 position = Vector3.Lerp(fromPosition, toPosition, progress);
                position.y += Mathf.Sin(progress * Mathf.PI) * arcHeight;
                prop.position = position;
                prop.rotation = Quaternion.Slerp(fromRotation, toRotation, progress);
                yield return null;
            }
            prop.position = toPosition;
            prop.rotation = toRotation;
        }

        private IEnumerator RockOnce(Transform target, float degrees)
        {
            Quaternion rest = target.localRotation;
            float duration = 0.6f;
            float elapsed = 0f;
            while (elapsed < duration)
            {
                elapsed += Time.deltaTime;
                float progress = Mathf.Clamp01(elapsed / duration);
                float angle = Mathf.Sin(progress * Mathf.PI * 2f) * degrees * (1f - progress);
                target.localRotation = rest * Quaternion.Euler(0f, 0f, angle);
                yield return null;
            }
            target.localRotation = rest;
        }

        private Transform FindHand(HumanBodyBones handBone)
        {
            if (player == null)
            {
                return null;
            }
            Animator animator = player.GetComponentInChildren<Animator>();
            return animator != null && animator.isHuman
                ? animator.GetBoneTransform(handBone)
                : null;
        }

        private void GetHeldPose(
            Transform hand,
            PickupAction action,
            out Vector3 heldPosition,
            out Quaternion heldRotation)
        {
            if (player == null)
            {
                heldPosition = action.Prop.position;
                heldRotation = action.Prop.rotation;
                return;
            }

            Vector3 anchor = hand != null
                ? hand.position
                : player.position + player.right * 0.24f + Vector3.up * 0.9f;
            heldPosition = anchor + player.TransformDirection(action.PositionFromHand);
            heldRotation = player.rotation * action.RotationFromPlayer;
        }

        private IEnumerator MovePropToHand(
            Transform prop,
            Transform hand,
            PickupAction action,
            Vector3 fromPosition,
            Quaternion fromRotation,
            float duration,
            float arcHeight)
        {
            float elapsed = 0f;
            while (elapsed < duration)
            {
                elapsed += Time.deltaTime;
                float progress = Mathf.SmoothStep(
                    0f,
                    1f,
                    Mathf.Clamp01(elapsed / duration));
                GetHeldPose(hand, action, out Vector3 heldPosition, out Quaternion heldRotation);
                Vector3 position = Vector3.Lerp(fromPosition, heldPosition, progress);
                position.y += Mathf.Sin(progress * Mathf.PI) * arcHeight;
                prop.SetPositionAndRotation(
                    position,
                    Quaternion.Slerp(fromRotation, heldRotation, progress));
                yield return null;
            }
            GetHeldPose(hand, action, out Vector3 finalPosition, out Quaternion finalRotation);
            prop.SetPositionAndRotation(finalPosition, finalRotation);
        }
    }
}
