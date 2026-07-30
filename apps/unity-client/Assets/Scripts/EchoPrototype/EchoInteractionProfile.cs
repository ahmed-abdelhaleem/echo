using System;
using System.Collections.Generic;
using UnityEngine;

namespace Echo.FreePrototype
{
    /// <summary>
    /// The physical shape of a hero-prop interaction. The archetype decides how
    /// many hands are involved, whether the prop leaves its support, and which
    /// body posture the rig drives; the per-object numbers live in
    /// <see cref="EchoInteractionProfile"/>.
    /// </summary>
    public enum EchoInteractionArchetype
    {
        /// <summary>One hand lifts a small object from a waist-high surface.</summary>
        TabletopOneHand,

        /// <summary>Both hands hold a flat object up and read it.</summary>
        TwoHandRead,

        /// <summary>The hand touches an object that never leaves its support.</summary>
        SupportedInspect,

        /// <summary>The character stoops to a handle on a grounded object.</summary>
        LowHandle
    }

    /// <summary>
    /// Which hand a grip belongs to. Matches the rig's palm sockets.
    /// </summary>
    public enum EchoHand
    {
        /// <summary>The character's right hand.</summary>
        Right,

        /// <summary>The character's left hand.</summary>
        Left
    }

    /// <summary>
    /// Object-specific interaction data for one hero prop, authored in
    /// Resources/Config/interaction_profiles.json and loaded by
    /// <see cref="EchoInteractionProfileCatalog"/>.
    ///
    /// Coordinate convention (every local pose in this class shares it):
    /// the prop's local frame is its own upright presentation frame —
    /// +Y is the object's up, +Z is the face a person reads or uses, +X is its
    /// right — and the origin sits at the centre of the object's bottom face in
    /// that frame. <see cref="dimensionsMeters"/> is (width, height, depth) in
    /// the same frame, so the collider box spans y = 0 to y = dimensions.y.
    /// A prop that rests in some other orientation (a phone lying flat, a book
    /// lying closed on a table) expresses that through the support pose, whose
    /// +Y axis points along world up while the prop is at rest.
    ///
    /// Grip sockets use the rig's palm convention: socket +Z is the palm normal
    /// (it points out of the palm and into the surface the hand presses on) and
    /// socket +Y is the palm's up axis, so the rig can align a palm socket to a
    /// grip socket with a plain pose match.
    /// </summary>
    [Serializable]
    public sealed class EchoInteractionProfile
    {
        private const float CoincidentGripEpsilonMeters = 0.005f;

        /// <summary>Matches the vignette interaction id, e.g. "photograph".</summary>
        public string interactionId;

        /// <summary>
        /// One of "tabletop_one_hand", "two_hand_read", "supported_inspect" or
        /// "low_handle". Read it through <see cref="Archetype"/>.
        /// </summary>
        public string archetype;

        /// <summary>Real-world (width, height, depth) in metres, upright frame.</summary>
        public Vector3 dimensionsMeters;

        /// <summary>"Right" or "Left". Read it through <see cref="PrimaryHand"/>.</summary>
        public string primaryHand;

        /// <summary>True when the second hand also contacts the prop.</summary>
        public bool usesSecondaryHand;

        /// <summary>Primary grip socket position in prop-local metres.</summary>
        public Vector3 gripPrimaryLocalPosition;

        /// <summary>Primary grip socket rotation in prop-local degrees.</summary>
        public Vector3 gripPrimaryLocalEuler;

        /// <summary>Secondary grip socket position; ignored unless <see cref="usesSecondaryHand"/>.</summary>
        public Vector3 gripSecondaryLocalPosition;

        /// <summary>Secondary grip socket rotation; ignored unless <see cref="usesSecondaryHand"/>.</summary>
        public Vector3 gripSecondaryLocalEuler;

        /// <summary>
        /// The patch where the prop touches its support at rest. Its +Y axis is
        /// world up while the prop rests, so its +Z axis is always horizontal
        /// and is the reference direction for <see cref="approachYawDegrees"/>.
        /// </summary>
        public Vector3 supportPoseLocalPosition;

        /// <summary>Support patch rotation in prop-local degrees.</summary>
        public Vector3 supportPoseLocalEuler;

        /// <summary>The point the character's eyes track, in prop-local metres.</summary>
        public Vector3 lookTargetLocalPosition;

        /// <summary>The point the prop turns about while it is inspected.</summary>
        public Vector3 inspectPivotLocalPosition;

        /// <summary>Horizontal distance from the prop to the character's stand point.</summary>
        public float stationDistanceMeters;

        /// <summary>
        /// Height of the surface the prop rests on above the character's floor.
        /// The station subtracts it from the prop's height to find the stand plane.
        /// </summary>
        public float stationHeightMeters;

        /// <summary>
        /// Legal approach directions, in degrees about world up, measured from
        /// the support patch's forward axis. The first entry is the canonical one.
        /// </summary>
        public float[] approachYawDegrees;

        /// <summary>How far off a legal approach yaw the character may already stand.</summary>
        public float approachToleranceDegrees;

        /// <summary>Inspected pose position relative to the rig's eye anchor.</summary>
        public Vector3 holdLocalPositionFromEye;

        /// <summary>Inspected pose rotation relative to the rig's eye anchor.</summary>
        public Vector3 holdLocalEulerFromEye;

        /// <summary>Seconds spent turning and stepping onto the stand point.</summary>
        public float alignSeconds;

        /// <summary>Seconds spent moving the hand from rest onto the grip.</summary>
        public float reachSeconds;

        /// <summary>Seconds spent settling the prop into the inspected pose.</summary>
        public float settleSeconds;

        /// <summary>Seconds the inspected pose is held.</summary>
        public float holdSeconds;

        /// <summary>Seconds spent returning the prop to its support pose.</summary>
        public float returnSeconds;

        /// <summary>Seconds spent releasing the grip and relaxing the arm.</summary>
        public float recoverySeconds;

        /// <summary>True when the prop must stay level, e.g. a mug with liquid.</summary>
        public bool keepWorldUp;

        /// <summary>Tilt budget in degrees applied when <see cref="keepWorldUp"/> is set.</summary>
        public float maxTiltDegrees;

        /// <summary>
        /// True when the prop may never leave the surface it rests on and is
        /// therefore never attached to a palm at all — the tip jar, which is
        /// touched and turned in place. Mutually exclusive with
        /// <see cref="groundedPivot"/>.
        /// </summary>
        public bool staysSupported;

        /// <summary>
        /// True when the prop IS carried by the hand but its lowest point stays
        /// pinned to the floor, so it pivots and tilts about its grounded edge
        /// instead of floating — the suitcase. This is a different constraint
        /// from <see cref="staysSupported"/>: a grounded-pivot prop moves with
        /// the hand and its collider travels with it, it simply never leaves
        /// the ground.
        /// </summary>
        public bool groundedPivot;

        /// <summary>Named finger shape the rig applies, e.g. "handle_hook".</summary>
        public string fingerPose;

        /// <summary>Accepted distance between the palm socket and the grip socket.</summary>
        public float gripToleranceMeters = 0.02f;

        /// <summary>Accepted angle between the palm socket and the grip socket.</summary>
        public float gripAngleToleranceDegrees = 5f;

        /// <summary>
        /// The parsed <see cref="archetype"/> string. Throws when the string is
        /// not a known archetype; the catalog rejects such profiles on load, so
        /// this only fires for profiles built in code.
        /// </summary>
        public EchoInteractionArchetype Archetype
        {
            get
            {
                if (!TryParseArchetype(archetype, out EchoInteractionArchetype parsed))
                {
                    throw new InvalidOperationException(
                        $"Interaction profile '{interactionId}' has unknown archetype '{archetype}'.");
                }
                return parsed;
            }
        }

        /// <summary>
        /// The parsed <see cref="primaryHand"/> string. Anything other than
        /// "Left" reads as the right hand, which is the authored default.
        /// </summary>
        public EchoHand PrimaryHand
        {
            get
            {
                return string.Equals(primaryHand, "Left", StringComparison.OrdinalIgnoreCase)
                    ? EchoHand.Left
                    : EchoHand.Right;
            }
        }

        /// <summary>
        /// Checks that the profile can actually drive a rig. Data problems are
        /// caught here at load time rather than as a limp arm at runtime.
        /// </summary>
        /// <param name="reason">Why the profile was rejected; empty when valid.</param>
        /// <returns>True when every field is usable.</returns>
        public bool Validate(out string reason)
        {
            if (dimensionsMeters.x <= 0f || dimensionsMeters.y <= 0f || dimensionsMeters.z <= 0f)
            {
                reason = $"dimensionsMeters {dimensionsMeters} must be positive on every axis.";
                return false;
            }

            if (!TryParseArchetype(archetype, out EchoInteractionArchetype _))
            {
                reason =
                    $"archetype '{archetype}' is not one of tabletop_one_hand, " +
                    "two_hand_read, supported_inspect, low_handle.";
                return false;
            }

            if (approachYawDegrees == null || approachYawDegrees.Length == 0)
            {
                reason = "approachYawDegrees must list at least one legal approach direction.";
                return false;
            }

            if (alignSeconds <= 0f || reachSeconds <= 0f || settleSeconds <= 0f ||
                holdSeconds <= 0f || returnSeconds <= 0f || recoverySeconds <= 0f)
            {
                reason =
                    "every timing must be positive (align, reach, settle, hold, return, recovery " +
                    $"= {alignSeconds}, {reachSeconds}, {settleSeconds}, {holdSeconds}, " +
                    $"{returnSeconds}, {recoverySeconds}).";
                return false;
            }

            if (usesSecondaryHand &&
                Vector3.Distance(gripSecondaryLocalPosition, gripPrimaryLocalPosition) <
                    CoincidentGripEpsilonMeters)
            {
                reason =
                    "usesSecondaryHand is set but the secondary grip sits on top of the " +
                    "primary grip; two hands cannot share one contact point.";
                return false;
            }

            if (staysSupported && groundedPivot)
            {
                reason =
                    "staysSupported and groundedPivot are mutually exclusive: the first never " +
                    "attaches the prop to a hand, the second carries it with its base pinned " +
                    "to the floor.";
                return false;
            }

            reason = string.Empty;
            return true;
        }

        private static bool TryParseArchetype(string value, out EchoInteractionArchetype parsed)
        {
            switch (value)
            {
                case "tabletop_one_hand":
                    parsed = EchoInteractionArchetype.TabletopOneHand;
                    return true;
                case "two_hand_read":
                    parsed = EchoInteractionArchetype.TwoHandRead;
                    return true;
                case "supported_inspect":
                    parsed = EchoInteractionArchetype.SupportedInspect;
                    return true;
                case "low_handle":
                    parsed = EchoInteractionArchetype.LowHandle;
                    return true;
                default:
                    parsed = EchoInteractionArchetype.TabletopOneHand;
                    return false;
            }
        }
    }

    /// <summary>
    /// The JSON document behind <see cref="EchoInteractionProfileCatalog"/>.
    /// JsonUtility cannot read a top-level array, so the profiles hang off a
    /// versioned wrapper object exactly like the real-world scale catalog.
    /// </summary>
    [Serializable]
    internal sealed class EchoInteractionProfileCatalogFile
    {
        public int schemaVersion;
        public EchoInteractionProfile[] interactions;
    }

    /// <summary>
    /// Loads the authored interaction profiles once and hands them out by id.
    /// The catalog is data, not prefabs: every hero prop in the scene is built
    /// from C# and configured from this JSON.
    /// </summary>
    public static class EchoInteractionProfileCatalog
    {
        private const string CatalogResourcePath = "Config/interaction_profiles";
        private const int ExpectedSchemaVersion = 1;

        private static EchoInteractionProfileCatalogFile catalog;
        private static IReadOnlyList<EchoInteractionProfile> readOnlyProfiles;

        /// <summary>
        /// Every authored profile, in file order. Throws when the catalog is
        /// missing or malformed.
        /// </summary>
        public static IReadOnlyList<EchoInteractionProfile> All
        {
            get
            {
                LoadCatalog();
                return readOnlyProfiles;
            }
        }

        /// <summary>
        /// Finds the profile for a vignette interaction id.
        /// </summary>
        /// <param name="interactionId">The id used by the vignette, e.g. "mug".</param>
        /// <returns>The profile, or null when the catalog has no entry for it.</returns>
        public static EchoInteractionProfile Find(string interactionId)
        {
            EchoInteractionProfileCatalogFile activeCatalog = LoadCatalog();
            foreach (EchoInteractionProfile profile in activeCatalog.interactions)
            {
                if (string.Equals(profile.interactionId, interactionId, StringComparison.Ordinal))
                {
                    return profile;
                }
            }
            return null;
        }

        /// <summary>
        /// Drops the cached catalog so a test can reload it after editing the
        /// authored JSON or swapping the Resources folder.
        /// </summary>
        internal static void ResetCacheForTests()
        {
            catalog = null;
            readOnlyProfiles = null;
        }

        private static EchoInteractionProfileCatalogFile LoadCatalog()
        {
            if (catalog != null)
            {
                return catalog;
            }

            TextAsset source = Resources.Load<TextAsset>(CatalogResourcePath);
            if (source == null)
            {
                throw new InvalidOperationException(
                    $"Missing interaction profile catalog at Resources/{CatalogResourcePath}.json.");
            }

            EchoInteractionProfileCatalogFile loaded =
                JsonUtility.FromJson<EchoInteractionProfileCatalogFile>(source.text);
            if (loaded == null ||
                loaded.schemaVersion != ExpectedSchemaVersion ||
                loaded.interactions == null ||
                loaded.interactions.Length == 0)
            {
                throw new InvalidOperationException("Invalid interaction profile schema.");
            }

            foreach (EchoInteractionProfile profile in loaded.interactions)
            {
                if (profile == null)
                {
                    throw new InvalidOperationException(
                        "Invalid interaction profile schema: null entry in interactions.");
                }
                if (!profile.Validate(out string reason))
                {
                    throw new InvalidOperationException(
                        $"Interaction profile '{profile.interactionId}' is unusable: {reason}");
                }
            }

            catalog = loaded;
            readOnlyProfiles = Array.AsReadOnly(loaded.interactions);
            return catalog;
        }
    }
}
