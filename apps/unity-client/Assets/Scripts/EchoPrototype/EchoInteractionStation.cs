using UnityEngine;

namespace Echo.FreePrototype
{
    /// <summary>
    /// The floor-level half of an interaction: where the character has to stand,
    /// and which way they have to face, before a hand can reach a hero prop.
    ///
    /// Approach directions are authored in the profile as yaw angles about world
    /// up, measured from the prop's support patch forward axis. That axis is
    /// horizontal whenever the prop is at rest, including for props that lie
    /// flat, so the same numbers work for an upright photo frame and for a phone
    /// face-up on a desk.
    /// </summary>
    [DisallowMultipleComponent]
    public sealed class EchoInteractionStation : MonoBehaviour
    {
        private EchoInteractionProfile profile;
        private Transform prop;
        private EchoHeroProp heroProp;

        /// <summary>
        /// The canonical stand point: the first authored approach direction, at
        /// the profile's stand distance, on the floor plane under the prop.
        /// Falls back to this station's own position until it is configured.
        /// </summary>
        public Vector3 StandPoint
        {
            get
            {
                if (profile == null || prop == null)
                {
                    return transform.position;
                }
                return StandPointForYaw(profile.approachYawDegrees[0]);
            }
        }

        /// <summary>
        /// Binds the station to a prop and its profile.
        /// </summary>
        /// <param name="interactionProfile">The authored profile for the prop.</param>
        /// <param name="propTransform">The hero prop this station serves.</param>
        public void Configure(EchoInteractionProfile interactionProfile, Transform propTransform)
        {
            if (interactionProfile == null || propTransform == null)
            {
                Debug.LogError(
                    $"[Echo Interaction] Station {name} needs both a profile and a prop.");
                return;
            }

            if (!interactionProfile.Validate(out string reason))
            {
                Debug.LogError(
                    $"[Echo Interaction] Station {name} rejected profile " +
                    $"'{interactionProfile.interactionId}': {reason}");
                return;
            }

            profile = interactionProfile;
            prop = propTransform;
            // The prop may still be waiting for its own Configure call, so the
            // support socket is looked up lazily rather than cached here.
            heroProp = propTransform.GetComponent<EchoHeroProp>();
        }

        /// <summary>
        /// Picks the stand pose the character should walk to. The approach
        /// nearest to where they already are wins, and if they are already
        /// inside that approach's tolerance cone they keep their own bearing
        /// instead of shuffling onto the exact authored angle.
        /// </summary>
        /// <param name="fromPosition">Where the character is now, in world space.</param>
        /// <param name="position">The resolved stand position on the floor plane.</param>
        /// <param name="rotation">The resolved facing, level with the floor.</param>
        /// <returns>False when the station has no usable profile or prop.</returns>
        public bool TryResolveStandPose(
            Vector3 fromPosition,
            out Vector3 position,
            out Quaternion rotation)
        {
            position = fromPosition;
            rotation = Quaternion.identity;
            if (profile == null || prop == null)
            {
                return false;
            }

            Vector3 reference = ReferenceForward();
            Vector3 floorPoint = FloorPoint();
            Vector3 toCharacter = fromPosition - floorPoint;
            toCharacter.y = 0f;

            float currentYaw = toCharacter.sqrMagnitude > 0.0001f
                ? Vector3.SignedAngle(reference, toCharacter.normalized, Vector3.up)
                : profile.approachYawDegrees[0];
            float nearestYaw = NearestApprovedYaw(currentYaw);
            float chosenYaw =
                Mathf.Abs(Mathf.DeltaAngle(nearestYaw, currentYaw)) <= profile.approachToleranceDegrees
                    ? currentYaw
                    : nearestYaw;

            position = StandPointForYaw(chosenYaw);
            Vector3 facing = floorPoint - position;
            facing.y = 0f;
            rotation = facing.sqrMagnitude > 0.0001f
                ? Quaternion.LookRotation(facing.normalized, Vector3.up)
                : Quaternion.identity;
            return true;
        }

        private float NearestApprovedYaw(float currentYaw)
        {
            float nearest = profile.approachYawDegrees[0];
            float smallestDelta = Mathf.Abs(Mathf.DeltaAngle(nearest, currentYaw));
            for (int index = 1; index < profile.approachYawDegrees.Length; index++)
            {
                float candidate = profile.approachYawDegrees[index];
                float delta = Mathf.Abs(Mathf.DeltaAngle(candidate, currentYaw));
                if (delta < smallestDelta)
                {
                    smallestDelta = delta;
                    nearest = candidate;
                }
            }
            return nearest;
        }

        private Vector3 StandPointForYaw(float yawDegrees)
        {
            Vector3 direction = Quaternion.AngleAxis(yawDegrees, Vector3.up) * ReferenceForward();
            return FloorPoint() + direction * profile.stationDistanceMeters;
        }

        /// <summary>
        /// The prop's position dropped onto the plane the character stands on.
        /// The prop's own origin sits on its support surface, so the authored
        /// support height is exactly the drop.
        /// </summary>
        private Vector3 FloorPoint()
        {
            Vector3 floorPoint = prop.position;
            floorPoint.y -= profile.stationHeightMeters;
            return floorPoint;
        }

        private Vector3 ReferenceForward()
        {
            Transform source = heroProp != null && heroProp.SupportPose != null
                ? heroProp.SupportPose
                : prop;
            Vector3 forward = source.forward;
            forward.y = 0f;
            if (forward.sqrMagnitude < 0.0001f)
            {
                // The support patch points straight up or down, which happens
                // when a prop rests on the face its forward axis belongs to.
                forward = source.up;
                forward.y = 0f;
            }
            if (forward.sqrMagnitude < 0.0001f)
            {
                forward = Vector3.forward;
            }
            return forward.normalized;
        }
    }
}
