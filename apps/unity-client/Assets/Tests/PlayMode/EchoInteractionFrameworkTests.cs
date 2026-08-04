using System.Collections;
using System.Collections.Generic;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace Echo.FreePrototype.Tests
{
    /// <summary>
    /// Play-mode coverage for the hero-prop interaction framework described by
    /// docs/15_Interaction_Benchmark.md: the authored profile catalogue, the two
    /// constraints that are easy to conflate, the grip solve every held prop
    /// depends on, and the coordinator's busy lock.
    ///
    /// Every prop, palm and support here is built from code, so the suite runs on
    /// a clean checkout where the gitignored Mixamo FBX files are absent. The one
    /// test that genuinely needs a rigged humanoid ignores itself with a message
    /// rather than failing.
    /// </summary>
    public sealed class EchoInteractionFrameworkTests
    {
        /// <summary>Tolerance for a pose the framework promises to restore verbatim.</summary>
        private const float ExactPoseToleranceMeters = 0.0001f;

        /// <summary>Rotation tolerance for a pose the framework restores verbatim.</summary>
        private const float ExactPoseToleranceDegrees = 0.01f;

        /// <summary>How close the grip socket must land on the palm, in metres.</summary>
        private const float GripToleranceMeters = 0.001f;

        /// <summary>How close the grip socket must land on the palm, in degrees.</summary>
        private const float GripToleranceDegrees = 0.5f;

        /// <summary>Metres of authored dimension drift that still counts as the benchmark size.</summary>
        private const float DimensionToleranceMeters = 0.0005f;

        /// <summary>Seconds the driven interaction is given to reach its hold phase.</summary>
        private const float InteractionDriveTimeoutSeconds = 6f;

        /// <summary>
        /// Where the fixtures are built. High enough above every bootstrap scene
        /// that no stray floor, wall or rug can turn up under a ground probe or an
        /// overlap query, and close enough to the origin that float precision stays
        /// far below the sub-millimetre tolerances asserted here.
        /// </summary>
        private static readonly Vector3 TestOrigin = new(0f, 12f, 0f);

        private readonly List<GameObject> spawnedObjects = new();

        /// <summary>
        /// Destroys every fixture and lets the destruction land before the next
        /// test builds its own, so no test can inherit another's colliders.
        /// </summary>
        /// <returns>The tear-down coroutine.</returns>
        [UnityTearDown]
        public IEnumerator DestroySpawnedObjects()
        {
            foreach (GameObject spawnedObject in spawnedObjects)
            {
                if (spawnedObject != null)
                {
                    Object.Destroy(spawnedObject);
                }
            }
            spawnedObjects.Clear();
            yield return null;
            Physics.SyncTransforms();
        }

        /// <summary>
        /// Proves all six authored profiles load, validate, and carry the
        /// real-world dimensions and archetypes from the benchmark table. A prop
        /// authored at the wrong size reads as a doll-house copy the moment a
        /// character picks it up.
        /// </summary>
        [Test]
        public void EverySixProfilesLoadValidateAndMatchTheBenchmarkDimensions()
        {
            IReadOnlyList<EchoInteractionProfile> profiles = EchoInteractionProfileCatalog.All;
            Assert.That(
                profiles.Count,
                Is.EqualTo(6),
                "The benchmark ships six hero props; a missing profile means one of them " +
                "cannot be picked up at all.");

            AssertBenchmarkProfile(
                "photograph",
                EchoInteractionArchetype.TwoHandRead,
                new Vector3(0.18f, 0.24f, 0.02f),
                "an 18 x 24 x 2 cm framed print");
            AssertBenchmarkProfile(
                "phone",
                EchoInteractionArchetype.TabletopOneHand,
                new Vector3(0.075f, 0.15f, 0.008f),
                "a 7.5 x 15 x 0.8 cm phone");
            AssertBenchmarkProfile(
                "mug",
                EchoInteractionArchetype.TabletopOneHand,
                new Vector3(0.09f, 0.1f, 0.09f),
                "a 9 cm wide, 10 cm tall mug");
            AssertBenchmarkProfile(
                "suitcase",
                EchoInteractionArchetype.LowHandle,
                new Vector3(0.55f, 0.35f, 0.22f),
                "a 55 x 35 x 22 cm suitcase");
            AssertBenchmarkProfile(
                "sketchbook",
                EchoInteractionArchetype.TwoHandRead,
                new Vector3(0.15f, 0.21f, 0.02f),
                "a 15 x 21 x 2 cm sketchbook");
            AssertBenchmarkProfile(
                "tip_jar",
                EchoInteractionArchetype.SupportedInspect,
                new Vector3(0.14f, 0.2f, 0.14f),
                "a 14 cm wide, 20 cm tall tip jar");
        }

        /// <summary>
        /// Proves <c>staysSupported</c> and <c>groundedPivot</c> stay two different
        /// constraints on two different props, and that a profile setting both is
        /// rejected. Collapsing them welds the suitcase to the floor even though
        /// its own archetype requires it to be carried.
        /// </summary>
        [Test]
        public void StaysSupportedAndGroundedPivotAreDistinctAndCannotBothBeSet()
        {
            EchoInteractionProfile tipJar = RequireProfile("tip_jar");
            Assert.That(
                tipJar.staysSupported,
                Is.True,
                "The tip jar is the prop that is touched and turned in place; without " +
                "staysSupported it lifts off the counter and floats to the hand.");
            Assert.That(
                tipJar.groundedPivot,
                Is.False,
                "The tip jar is never attached to a palm, so pinning its base is " +
                "meaningless and would hide a jar that had started following the hand.");

            EchoInteractionProfile suitcase = RequireProfile("suitcase");
            Assert.That(
                suitcase.groundedPivot,
                Is.True,
                "The suitcase is carried by its handle with its base on the floor; " +
                "without groundedPivot it lifts clear of the ground like a small prop.");
            Assert.That(
                suitcase.staysSupported,
                Is.False,
                "Marking the suitcase staysSupported welds it to the floor: the hand " +
                "would close on a handle that never moves and the case never travels.");

            EchoInteractionProfile conflated = BuildMinimalValidProfile();
            conflated.staysSupported = true;
            conflated.groundedPivot = true;
            Assert.That(
                conflated.Validate(out string conflictReason),
                Is.False,
                "A profile claiming both constraints must be rejected at load time " +
                "instead of producing a prop that is both carried and welded down.");
            Assert.That(
                conflictReason,
                Does.Contain("mutually exclusive"),
                $"The rejection has to name the conflict so it can be fixed; got " +
                $"'{conflictReason}'.");

            conflated.groundedPivot = false;
            Assert.That(
                conflated.Validate(out string supportedOnlyReason),
                Is.True,
                "staysSupported on its own is a legal profile; the rejection above must " +
                $"come from the conflict, not from another field ({supportedOnlyReason}).");

            conflated.staysSupported = false;
            conflated.groundedPivot = true;
            Assert.That(
                conflated.Validate(out string pivotOnlyReason),
                Is.True,
                "groundedPivot on its own is a legal profile; the rejection above must " +
                $"come from the conflict, not from another field ({pivotOnlyReason}).");
        }

        /// <summary>
        /// Proves a <c>staysSupported</c> prop keeps its exact support pose even
        /// when a palm has claimed it, and that the grip error stays an honest
        /// measurement instead of being hidden by a snap.
        /// </summary>
        /// <returns>The test coroutine.</returns>
        [UnityTest]
        public IEnumerator SupportedPropStaysOnItsSupportEvenWhenAPalmClaimsIt()
        {
            yield return null;

            EchoHeroProp jar = CreateProp(
                "tip_jar",
                null,
                TestOrigin + new Vector3(0f, 1.05f, 0f),
                Quaternion.Euler(0f, 27f, 0f));
            jar.transform.GetPositionAndRotation(
                out Vector3 restPosition,
                out Quaternion restRotation);

            Transform palm = CreatePalm(
                restPosition + new Vector3(0.45f, 0.62f, -0.3f),
                Quaternion.Euler(18f, -74f, 41f),
                new Vector3(0.06f, 0.02f, 0.09f),
                Quaternion.Euler(-22f, 33f, 8f));

            jar.AttachTo(palm);
            for (int step = 0; step < 4; step++)
            {
                jar.FollowAttachment();
            }

            Assert.That(
                Vector3.Distance(jar.transform.position, restPosition),
                Is.LessThanOrEqualTo(ExactPoseToleranceMeters),
                "The tip jar must never float: it keeps contact with the counter for the " +
                "whole interaction, however far the hand has travelled.");
            Assert.That(
                Quaternion.Angle(jar.transform.rotation, restRotation),
                Is.LessThanOrEqualTo(ExactPoseToleranceDegrees),
                "A supported prop must not be spun by the wrist; it only turns when the " +
                "director asks it to, about its own inspect pivot.");
            Assert.That(
                jar.GripPositionErrorMeters(palm),
                Is.GreaterThan(0.1f),
                "The grip error has to stay an honest measurement of where the hand " +
                "really is; a supported prop must not snap onto the palm to flatter it.");
        }

        /// <summary>
        /// Proves the core contract
        /// <c>propWorldPose = palmWorldPose * inverse(gripPrimaryLocalPose)</c>: the
        /// grip socket lands in the palm and keeps tracking it as the hand moves and
        /// turns, and the prop does not twitch before it has been attached.
        /// </summary>
        /// <returns>The test coroutine.</returns>
        [UnityTest]
        public IEnumerator AttachedPropPutsItsGripSocketOnThePalmAndKeepsTrackingIt()
        {
            yield return null;

            EchoHeroProp photograph = CreateProp(
                "photograph",
                null,
                TestOrigin + new Vector3(0f, 0.78f, 0f),
                Quaternion.Euler(0f, 24f, 0f));
            Vector3 restPosition = photograph.transform.position;

            Transform palm = CreatePalm(
                TestOrigin + new Vector3(0.37f, 1.12f, -0.63f),
                Quaternion.Euler(12f, 47f, -23f),
                new Vector3(0.11f, -0.05f, 0.24f),
                Quaternion.Euler(-31f, 15f, 62f));

            photograph.FollowAttachment();
            Assert.That(
                Vector3.Distance(photograph.transform.position, restPosition),
                Is.LessThanOrEqualTo(ExactPoseToleranceMeters),
                "The hand travels to a stationary photograph: an unattached prop must " +
                "not move a millimetre while the rig evaluates.");

            photograph.AttachTo(palm);
            photograph.FollowAttachment();
            AssertGripMeetsPalm(photograph, palm, "the frame is taken");
            Assert.That(
                Vector3.Distance(photograph.transform.position, restPosition),
                Is.GreaterThan(0.2f),
                "The attached photograph must actually be in the hand, otherwise this " +
                "test would pass on a prop that never left the nightstand.");

            palm.parent.SetPositionAndRotation(
                TestOrigin + new Vector3(-0.44f, 1.53f, 0.21f),
                Quaternion.Euler(-38f, 205f, 17f));
            palm.SetLocalPositionAndRotation(
                new Vector3(-0.07f, 0.13f, -0.19f),
                Quaternion.Euler(48f, -66f, 9f));
            photograph.FollowAttachment();
            AssertGripMeetsPalm(photograph, palm, "the hand has moved and turned");
        }

        /// <summary>
        /// Proves a <c>groundedPivot</c> prop tips about its base instead of
        /// floating when the hand rises, while its collider still travels with it
        /// horizontally. The regression this catches welded the suitcase to the
        /// floor and left the hand closing on a handle that never moved.
        /// </summary>
        /// <returns>The test coroutine.</returns>
        [UnityTest]
        public IEnumerator GroundedPivotPropKeepsItsBaseOnTheSurfaceItRestedOn()
        {
            yield return null;

            // Deliberately not on the world floor: the pin height is whatever the
            // case was actually resting on, which may be a rug.
            Vector3 restPosition = TestOrigin + new Vector3(0f, 0.42f, 0f);
            EchoHeroProp suitcase = CreateProp("suitcase", null, restPosition, Quaternion.identity);

            Collider suitcaseCollider = suitcase.GetComponentInChildren<Collider>();
            Assert.That(
                suitcaseCollider,
                Is.Not.Null,
                "A carried prop needs collision of its own, otherwise it passes through " +
                "the room the moment the hand takes it.");
            Assert.That(
                suitcaseCollider.transform.IsChildOf(suitcase.transform),
                Is.True,
                "The suitcase's collision must belong to the suitcase; parked next to it " +
                "as a sibling it stays behind on the floor while the case is carried off.");

            Physics.SyncTransforms();
            float restBottomHeight = suitcaseCollider.bounds.min.y;
            Assert.That(
                restBottomHeight,
                Is.EqualTo(restPosition.y).Within(0.002f),
                "The profile's origin is the centre of the prop's bottom face, so a case " +
                "placed on a surface must already be standing on it, not sunk into it.");

            Transform palm = CreatePalm(
                restPosition + new Vector3(0.3f, 0.9f, 0.12f),
                Quaternion.Euler(0f, 40f, 0f),
                Vector3.zero,
                Quaternion.identity);
            suitcase.AttachTo(palm);
            Assert.That(
                suitcase.IsAttached,
                Is.True,
                "Unlike the tip jar, the suitcase really is carried by the hand.");

            bool baseStayedDown = false;
            for (int step = 0; step < 8 && !baseStayedDown; step++)
            {
                Physics.SyncTransforms();
                suitcase.FollowAttachment();
                Physics.SyncTransforms();
                baseStayedDown =
                    Mathf.Abs(suitcaseCollider.bounds.min.y - restBottomHeight) <= 0.001f;
            }

            Assert.That(
                baseStayedDown,
                Is.True,
                "With the hand 0.9 m above it the suitcase must still be standing on the " +
                "surface it started on; a case hanging in the air has no weight.");
            Assert.That(
                suitcase.transform.position.y,
                Is.InRange(restPosition.y - 0.001f, restPosition.y + 0.06f),
                "The case tips about its grounded edge, so its base rises by a few " +
                "centimetres of tilt at most, never by the height of the hand.");

            Vector3 gripOnFloorPlane = suitcase.GripPrimary.position;
            gripOnFloorPlane.y = 0f;
            Vector3 palmOnFloorPlane = palm.position;
            palmOnFloorPlane.y = 0f;
            Assert.That(
                Vector3.Distance(gripOnFloorPlane, palmOnFloorPlane),
                Is.LessThanOrEqualTo(GripToleranceMeters),
                "Only the case's height is pinned: the hand must stay on the handle as " +
                "the case is dragged, instead of sliding off it.");

            Vector3 travel = suitcase.transform.position - restPosition;
            travel.y = 0f;
            Assert.That(
                travel.magnitude,
                Is.GreaterThan(0.1f),
                "The suitcase and its collider must travel with the hand. Pinning it to " +
                "its rest pose is the tip jar's rule, not the suitcase's.");
        }

        /// <summary>
        /// Proves a <c>keepWorldUp</c> prop stays level within its tilt budget on a
        /// wildly rolled wrist, while the hand keeps its position on the grip and
        /// the resulting angle error is still reported honestly.
        /// </summary>
        /// <returns>The test coroutine.</returns>
        [UnityTest]
        public IEnumerator KeepWorldUpPropStaysLevelOnAWildlyTiltedPalm()
        {
            yield return null;

            EchoInteractionProfile mugProfile = RequireProfile("mug");
            Assert.That(
                mugProfile.keepWorldUp,
                Is.True,
                "A mug holds liquid, so it is the prop that must stay level whatever " +
                "the wrist does.");
            Assert.That(
                mugProfile.maxTiltDegrees,
                Is.GreaterThan(0f),
                "A zero tilt budget would freeze the mug bolt upright and read as a " +
                "prop glued to an invisible table.");

            EchoHeroProp mug = CreateProp(
                "mug",
                null,
                TestOrigin + new Vector3(0f, 0.75f, 0f),
                Quaternion.identity);
            Transform palm = CreatePalm(
                TestOrigin + new Vector3(0.2f, 1.1f, 0.3f),
                Quaternion.identity,
                new Vector3(0.03f, -0.02f, 0.05f),
                Quaternion.identity);
            mug.AttachTo(palm);

            Quaternion gripLocalRotation = Quaternion.Euler(mugProfile.gripPrimaryLocalEuler);
            Quaternion[] wristPoses =
            {
                Quaternion.Euler(75f, 30f, -120f),
                Quaternion.Euler(-110f, 200f, 65f),
                Quaternion.Euler(180f, 0f, 0f),
                Quaternion.Euler(0f, 0f, 95f)
            };

            foreach (Quaternion wristPose in wristPoses)
            {
                palm.rotation = wristPose;
                mug.FollowAttachment();

                Quaternion unclamped = wristPose * Quaternion.Inverse(gripLocalRotation);
                Assert.That(
                    Vector3.Angle(unclamped * Vector3.up, Vector3.up),
                    Is.GreaterThan(mugProfile.maxTiltDegrees),
                    $"Wrist pose {wristPose.eulerAngles} has to be extreme enough to need " +
                    "the tilt clamp, otherwise this case proves nothing.");
                Assert.That(
                    Vector3.Angle(mug.transform.up, Vector3.up),
                    Is.LessThanOrEqualTo(mugProfile.maxTiltDegrees + 0.25f),
                    $"With the wrist at {wristPose.eulerAngles} the mug would pour its " +
                    "contents onto the floor; it must stay inside its tilt budget.");
                Assert.That(
                    mug.GripPositionErrorMeters(palm),
                    Is.LessThanOrEqualTo(GripToleranceMeters),
                    "Levelling the mug must not slide it out of the hand: the fingers " +
                    "stay on the handle while only the tilt is corrected.");
                Assert.That(
                    mug.GripAngleErrorDegrees(palm),
                    Is.GreaterThan(mugProfile.gripAngleToleranceDegrees),
                    "A mug that refuses to follow the wrist must report that refusal as " +
                    "a real angle error rather than quietly matching the palm.");
            }
        }

        /// <summary>
        /// Proves the captured support pose is restored exactly in both position and
        /// rotation, through the parented path and the world path, and that the
        /// parented path keeps the prop welded to a support that has since moved.
        /// </summary>
        /// <returns>The test coroutine.</returns>
        [UnityTest]
        public IEnumerator CapturedSupportPoseIsRestoredExactlyInPositionAndRotation()
        {
            yield return null;

            GameObject table = new("EchoInteractionTests_Table");
            spawnedObjects.Add(table);
            table.transform.SetPositionAndRotation(
                TestOrigin + new Vector3(0.9f, 0.75f, -0.4f),
                Quaternion.Euler(0f, 63f, 0f));

            EchoHeroProp sketchbook = CreateProp(
                "sketchbook",
                table.transform,
                new Vector3(0.12f, 0f, -0.06f),
                Quaternion.Euler(90f, 17f, 0f));
            Vector3 restLocalPosition = sketchbook.transform.localPosition;
            Quaternion restLocalRotation = sketchbook.transform.localRotation;

            Transform palm = CreatePalm(
                TestOrigin + new Vector3(-0.3f, 1.4f, 0.5f),
                Quaternion.Euler(23f, 140f, -55f),
                new Vector3(0.04f, 0.07f, -0.12f),
                Quaternion.Euler(11f, -29f, 44f));

            sketchbook.AttachTo(palm);
            sketchbook.FollowAttachment();
            Assert.That(
                Vector3.Distance(sketchbook.transform.localPosition, restLocalPosition),
                Is.GreaterThan(0.2f),
                "The sketchbook must genuinely be lifted before the restore is worth " +
                "measuring.");

            sketchbook.Detach();
            Assert.That(
                sketchbook.IsAttached,
                Is.False,
                "Releasing the sketchbook must hand ownership of its pose back to the " +
                "table.");
            Assert.That(
                sketchbook.IsSupported,
                Is.True,
                "A released prop is back on its support and can be picked up again.");
            Assert.That(
                sketchbook.transform.localPosition,
                Is.EqualTo(restLocalPosition),
                "The sketchbook must land exactly where it was, not near it: even a few " +
                "millimetres read as the book hopping the instant the hand lets go.");
            Assert.That(
                Quaternion.Angle(sketchbook.transform.localRotation, restLocalRotation),
                Is.LessThanOrEqualTo(ExactPoseToleranceDegrees),
                "The book must also be put down the way up it was found; a restored " +
                "position with a drifted rotation still reads as a different object.");

            table.transform.SetPositionAndRotation(
                TestOrigin + new Vector3(1.4f, 0.75f, 0.1f),
                Quaternion.Euler(0f, 88f, 0f));
            sketchbook.AttachTo(palm);
            sketchbook.FollowAttachment();
            sketchbook.Detach();
            Assert.That(
                sketchbook.transform.localPosition,
                Is.EqualTo(restLocalPosition),
                "Restoring through the local pose keeps the sketchbook on the table it " +
                "came from even after the table itself has been moved.");
            Assert.That(
                Vector3.Distance(
                    sketchbook.transform.position,
                    table.transform.TransformPoint(restLocalPosition)),
                Is.LessThanOrEqualTo(ExactPoseToleranceMeters),
                "A prop restored onto a moved support must travel with the support " +
                "rather than reappearing at the support's old world position.");

            EchoHeroProp looseMug = CreateProp(
                "mug",
                null,
                TestOrigin + new Vector3(-0.6f, 0.75f, 0.2f),
                Quaternion.Euler(0f, 143f, 0f));
            looseMug.transform.GetPositionAndRotation(
                out Vector3 mugRestPosition,
                out Quaternion mugRestRotation);
            looseMug.AttachTo(palm);
            looseMug.FollowAttachment();
            looseMug.Detach();
            Assert.That(
                Vector3.Distance(looseMug.transform.position, mugRestPosition),
                Is.LessThanOrEqualTo(ExactPoseToleranceMeters),
                "A prop with no scene parent must be restored to its exact world pose " +
                "instead of drifting a little further off the counter every take.");
            Assert.That(
                Quaternion.Angle(looseMug.transform.rotation, mugRestRotation),
                Is.LessThanOrEqualTo(ExactPoseToleranceDegrees),
                "The mug's handle must end up facing the way it started.");
        }

        /// <summary>
        /// Proves a coordinator with no built rig refuses every start, stays idle,
        /// and leaves the prop untouched on its support. A character with no hand
        /// must not teleport a prop into an invisible palm.
        /// </summary>
        /// <returns>The test coroutine.</returns>
        [UnityTest]
        public IEnumerator CoordinatorRefusesToStartWithoutABuiltRigAndLeavesThePropAtRest()
        {
            yield return null;

            EchoHeroProp phone = CreateProp(
                "phone",
                null,
                TestOrigin + new Vector3(0f, 0.75f, 0.9f),
                Quaternion.Euler(0f, 180f, 0f));
            EchoInteractionStation station = CreateStation(phone);
            Vector3 restPosition = phone.transform.position;

            GameObject characterObject = new("EchoInteractionTests_UnriggedCharacter");
            spawnedObjects.Add(characterObject);
            characterObject.transform.position = TestOrigin;
            EchoInteractionCoordinator coordinator =
                characterObject.AddComponent<EchoInteractionCoordinator>();
            coordinator.Configure(null, characterObject.transform, null, null);
            Assert.That(
                coordinator.Register("phone", phone, station),
                Is.True,
                "A prop and a station are all an interaction id needs to be bound.");

            Assert.That(
                coordinator.TryBegin("phone"),
                Is.False,
                "A character with no interaction rig has no hand to reach with, so the " +
                "phone must stay on the desk instead of being taken by nothing.");
            Assert.That(
                coordinator.State,
                Is.EqualTo(EchoInteractionState.Idle),
                "A refused interaction must fall back to idle rather than parking the " +
                "machine mid-validation.");
            Assert.That(
                coordinator.IsBusy,
                Is.False,
                "A refused interaction must not leave the player unable to walk away.");
            Assert.That(
                coordinator.TryBegin("mug"),
                Is.False,
                "An id with no prop and station registered must be refused, not played " +
                "against whatever prop happens to be nearest.");

            yield return null;

            Assert.That(
                Vector3.Distance(phone.transform.position, restPosition),
                Is.LessThanOrEqualTo(ExactPoseToleranceMeters),
                "Nothing the coordinator refused may move the phone.");
            coordinator.CancelAll();
            Assert.That(
                coordinator.State,
                Is.EqualTo(EchoInteractionState.Idle),
                "Cancelling when nothing is running must be a safe no-op.");
            Assert.That(
                coordinator.PrimaryHandWeight,
                Is.EqualTo(0f).Within(ExactPoseToleranceMeters),
                "An idle character's arms belong to the animation, not to the IK.");
        }

        /// <summary>
        /// Drives a real interaction to its hold phase and proves the lock holds:
        /// every repeat <c>TryBegin</c> is refused for the whole run, the prop does
        /// not move before contact, and <c>CancelAll</c> returns to idle with the
        /// prop exactly back on its support and every IK weight at zero.
        /// </summary>
        /// <returns>The test coroutine.</returns>
        [UnityTest]
        public IEnumerator BusyCoordinatorRefusesRepeatEntryAndCancelAllReturnsEverythingToRest()
        {
            yield return null;

            if (!TryBuildRiggedCharacter(
                    out EchoCharacterInteractionRig rig,
                    out Transform characterRoot))
            {
                Assert.Ignore(
                    "No rigged humanoid is available: Assets/Resources/Characters/*/Walking.fbx " +
                    "is a gitignored Mixamo download, and the interaction coordinator cannot " +
                    "start without a built rig. Everything else in this suite runs without it.");
                yield break;
            }

            yield return null;

            EchoHeroProp photograph = CreateProp(
                "photograph",
                null,
                characterRoot.position + new Vector3(0f, 0.78f, 0.9f),
                Quaternion.Euler(0f, 180f, 0f));
            EchoInteractionStation station = CreateStation(photograph);
            photograph.transform.GetPositionAndRotation(
                out Vector3 restPosition,
                out Quaternion restRotation);

            EchoInteractionCoordinator coordinator =
                characterRoot.gameObject.AddComponent<EchoInteractionCoordinator>();
            coordinator.Configure(rig, characterRoot, null, null);
            Assert.That(coordinator.Register("photograph", photograph, station), Is.True);

            Assert.That(
                coordinator.TryBegin("photograph"),
                Is.True,
                "A rigged character standing in front of a registered photograph must be " +
                "able to pick it up.");
            Assert.That(
                coordinator.State,
                Is.EqualTo(EchoInteractionState.Align),
                "Validation, reservation and the locomotion lock all complete inside " +
                "TryBegin, so the machine is already turning to face the prop.");
            Assert.That(
                coordinator.IsBusy,
                Is.True,
                "Player locomotion stays locked from the moment the interaction is " +
                "reserved until recovery finishes.");

            bool reachedHold = false;
            float deadline = Time.time + InteractionDriveTimeoutSeconds;
            while (Time.time < deadline)
            {
                EchoInteractionState phase = coordinator.State;
                Assert.That(
                    coordinator.TryBegin("photograph"),
                    Is.False,
                    $"A second interaction was accepted during {phase}; mashing the " +
                    "interact key must not restart the reach on top of itself.");
                if (phase == EchoInteractionState.Align || phase == EchoInteractionState.Reach)
                {
                    Assert.That(
                        Vector3.Distance(photograph.transform.position, restPosition),
                        Is.LessThanOrEqualTo(0.001f),
                        "The photograph must not stir before the hand arrives; a prop " +
                        "that starts moving first is the floating-prop regression.");
                }
                if (phase == EchoInteractionState.Hold)
                {
                    reachedHold = true;
                    break;
                }
                yield return null;
            }

            Assert.That(
                reachedHold,
                Is.True,
                $"The interaction never reached its hold within " +
                $"{InteractionDriveTimeoutSeconds:0.0}s; it stalled in " +
                $"{coordinator.State} and the player would be locked in place.");
            Assert.That(
                photograph.IsAttached,
                Is.True,
                "By the hold the photograph is being carried by the hand.");
            Assert.That(
                coordinator.AttachFrameIndex,
                Is.GreaterThanOrEqualTo(0),
                "The frame the prop was taken has to be recorded; an unrecorded attach " +
                "cannot be checked against the capture gates.");
            Assert.That(
                Vector3.Distance(photograph.transform.position, restPosition),
                Is.GreaterThan(0.1f),
                "The held photograph must be up at the character, not still lying on " +
                "the nightstand.");

            coordinator.CancelAll();

            Assert.That(
                coordinator.State,
                Is.EqualTo(EchoInteractionState.Idle),
                "Cancelling mid-hold must return the machine to idle from any phase.");
            Assert.That(
                coordinator.IsBusy,
                Is.False,
                "A cancelled interaction must hand movement back to the player.");
            Assert.That(
                photograph.IsAttached,
                Is.False,
                "Cancelling must let go of the prop; a photograph still welded to a " +
                "relaxed hand follows the character around the room.");
            Assert.That(
                photograph.IsSupported,
                Is.True,
                "A cancelled prop is back on its support and can be picked up again.");
            Assert.That(
                Vector3.Distance(photograph.transform.position, restPosition),
                Is.LessThanOrEqualTo(ExactPoseToleranceMeters),
                "Cancelling must put the photograph back on the nightstand exactly where " +
                "it stood, not somewhere close to it.");
            Assert.That(
                Quaternion.Angle(photograph.transform.rotation, restRotation),
                Is.LessThanOrEqualTo(ExactPoseToleranceDegrees),
                "The restored photograph must also face the way it did before.");
            Assert.That(
                coordinator.PrimaryHandWeight,
                Is.EqualTo(0f).Within(ExactPoseToleranceMeters),
                "The reaching arm must return to the animated pose instead of staying " +
                "frozen mid-reach.");
            Assert.That(
                coordinator.SecondaryHandWeight,
                Is.EqualTo(0f).Within(ExactPoseToleranceMeters),
                "The supporting arm must relax too, even though it never took the grip.");
            Assert.That(
                coordinator.LookWeight,
                Is.EqualTo(0f).Within(ExactPoseToleranceMeters),
                "The character must stop staring at the prop once the interaction is " +
                "cancelled.");

            yield return null;

            Assert.That(
                coordinator.TryBegin("photograph"),
                Is.True,
                "The lock has to be released as well as cleared: after a cancel the same " +
                "interaction must be startable again.");
            coordinator.CancelAll();
        }

        private static EchoInteractionProfile RequireProfile(string interactionId)
        {
            EchoInteractionProfile profile = EchoInteractionProfileCatalog.Find(interactionId);
            Assert.That(
                profile,
                Is.Not.Null,
                $"The '{interactionId}' interaction has no authored profile, so nothing in " +
                "the scene can be picked up for it.");
            return profile;
        }

        private static void AssertBenchmarkProfile(
            string interactionId,
            EchoInteractionArchetype expectedArchetype,
            Vector3 expectedDimensionsMeters,
            string sizeDescription)
        {
            EchoInteractionProfile profile = RequireProfile(interactionId);
            Assert.That(
                profile.Validate(out string reason),
                Is.True,
                $"The '{interactionId}' profile cannot drive a rig: {reason}");
            Assert.That(
                profile.Archetype,
                Is.EqualTo(expectedArchetype),
                $"The {interactionId} borrows the wrong interaction shape, so it would be " +
                "handled with the wrong number of hands and the wrong posture.");
            Assert.That(
                profile.dimensionsMeters.x,
                Is.EqualTo(expectedDimensionsMeters.x).Within(DimensionToleranceMeters),
                $"The {interactionId} must be {sizeDescription}; another width reads as a " +
                "doll-house copy the moment it is held next to a 1.78 m character.");
            Assert.That(
                profile.dimensionsMeters.y,
                Is.EqualTo(expectedDimensionsMeters.y).Within(DimensionToleranceMeters),
                $"The {interactionId} must be {sizeDescription}; another height reads as a " +
                "doll-house copy the moment it is held next to a 1.78 m character.");
            Assert.That(
                profile.dimensionsMeters.z,
                Is.EqualTo(expectedDimensionsMeters.z).Within(DimensionToleranceMeters),
                $"The {interactionId} must be {sizeDescription}; another depth reads as a " +
                "doll-house copy the moment it is held next to a 1.78 m character.");
        }

        private static void AssertGripMeetsPalm(
            EchoHeroProp prop,
            Transform palm,
            string whenLabel)
        {
            Assert.That(
                prop.GripPositionErrorMeters(palm),
                Is.LessThanOrEqualTo(GripToleranceMeters),
                $"Once {whenLabel} the grip socket has to sit in the palm within a " +
                "millimetre; any further and the prop reads as floating beside the hand.");
            Assert.That(
                prop.GripAngleErrorDegrees(palm),
                Is.LessThanOrEqualTo(GripToleranceDegrees),
                $"Once {whenLabel} the grip socket has to match the palm's orientation; " +
                "a twisted grip reads as the fingers passing through the prop.");
        }

        /// <summary>
        /// A profile with every field the validator insists on and nothing else, so
        /// a test can switch one flag and know what the rejection came from.
        /// </summary>
        private static EchoInteractionProfile BuildMinimalValidProfile()
        {
            return new EchoInteractionProfile
            {
                interactionId = "test_prop",
                archetype = "tabletop_one_hand",
                dimensionsMeters = new Vector3(0.1f, 0.1f, 0.1f),
                primaryHand = "Right",
                usesSecondaryHand = false,
                approachYawDegrees = new float[] { 0f },
                approachToleranceDegrees = 20f,
                alignSeconds = 0.5f,
                reachSeconds = 0.5f,
                settleSeconds = 0.5f,
                holdSeconds = 0.5f,
                returnSeconds = 0.5f,
                recoverySeconds = 0.5f
            };
        }

        private static AnimationClip FirstImportedClip(string resourcePath)
        {
            AnimationClip[] clips = Resources.LoadAll<AnimationClip>(resourcePath);
            foreach (AnimationClip clip in clips)
            {
                if (!clip.name.Contains("__preview__"))
                {
                    return clip;
                }
            }
            return null;
        }

        /// <summary>
        /// Builds a hero prop from code and captures its rest pose once the physics
        /// world has caught up with the collider that <c>Configure</c> just added.
        /// </summary>
        private EchoHeroProp CreateProp(
            string interactionId,
            Transform parent,
            Vector3 localPosition,
            Quaternion localRotation)
        {
            EchoInteractionProfile profile = RequireProfile(interactionId);
            GameObject propObject = new($"EchoInteractionTests_{interactionId}");
            if (parent == null)
            {
                spawnedObjects.Add(propObject);
            }
            propObject.transform.SetParent(parent, false);
            propObject.transform.SetLocalPositionAndRotation(localPosition, localRotation);
            propObject.transform.localScale = Vector3.one;

            EchoHeroProp prop = propObject.AddComponent<EchoHeroProp>();
            prop.Configure(profile);
            Assert.That(
                prop.GripPrimary,
                Is.Not.Null,
                $"The '{interactionId}' prop was not configured, so it has no grip for a " +
                "hand to arrive at.");

            Physics.SyncTransforms();
            prop.CaptureRestPose();
            return prop;
        }

        /// <summary>
        /// Builds a stand-in for the rig's palm socket: a socket parented under a
        /// hand bone, both at poses that are nothing like the identity, so a solve
        /// that quietly ignores the parent chain cannot pass.
        /// </summary>
        private Transform CreatePalm(
            Vector3 handWorldPosition,
            Quaternion handWorldRotation,
            Vector3 palmLocalPosition,
            Quaternion palmLocalRotation)
        {
            GameObject handObject = new("EchoInteractionTests_HandBone");
            spawnedObjects.Add(handObject);
            handObject.transform.SetPositionAndRotation(handWorldPosition, handWorldRotation);

            GameObject palmObject = new("EchoInteractionTests_PalmSocket");
            palmObject.transform.SetParent(handObject.transform, false);
            palmObject.transform.SetLocalPositionAndRotation(palmLocalPosition, palmLocalRotation);
            return palmObject.transform;
        }

        private EchoInteractionStation CreateStation(EchoHeroProp prop)
        {
            GameObject stationObject = new($"{prop.name}_Station");
            spawnedObjects.Add(stationObject);
            EchoInteractionStation station =
                stationObject.AddComponent<EchoInteractionStation>();
            station.Configure(prop.Profile, prop.transform);
            return station;
        }

        /// <summary>
        /// Instantiates one of the optional Mixamo humanoids and builds a live
        /// interaction rig on it.
        /// </summary>
        /// <param name="rig">The built rig, or null when no humanoid is available.</param>
        /// <param name="characterRoot">The character root, or null.</param>
        /// <returns>False on a clean checkout, where the FBX files are gitignored.</returns>
        private bool TryBuildRiggedCharacter(
            out EchoCharacterInteractionRig rig,
            out Transform characterRoot)
        {
            rig = null;
            characterRoot = null;
            string[] candidatePaths =
            {
                "Characters/Noor/Walking",
                "Characters/YBot/Walking"
            };

            foreach (string resourcePath in candidatePaths)
            {
                GameObject modelPrefab = Resources.Load<GameObject>(resourcePath);
                AnimationClip walkClip = FirstImportedClip(resourcePath);
                if (modelPrefab == null || walkClip == null)
                {
                    continue;
                }

                GameObject characterObject = new("EchoInteractionTests_Character");
                spawnedObjects.Add(characterObject);
                characterObject.transform.SetPositionAndRotation(TestOrigin, Quaternion.identity);

                GameObject visual = Object.Instantiate(modelPrefab, characterObject.transform);
                visual.transform.SetLocalPositionAndRotation(Vector3.zero, Quaternion.identity);
                visual.transform.localScale = Vector3.one;

                Animator animator = visual.GetComponentInChildren<Animator>();
                EchoMixamoCharacter playback =
                    characterObject.AddComponent<EchoMixamoCharacter>();
                if (animator != null &&
                    animator.isHuman &&
                    playback.Configure(animator, walkClip, 0f))
                {
                    playback.SetPlaybackSpeed(0f);
                    EchoCharacterInteractionRig builtRig =
                        characterObject.AddComponent<EchoCharacterInteractionRig>();
                    if (builtRig.Build(
                            animator,
                            playback,
                            EchoCharacterInteractionRig.DefaultCalibration(resourcePath)))
                    {
                        rig = builtRig;
                        characterRoot = characterObject.transform;
                        return true;
                    }
                }

                spawnedObjects.Remove(characterObject);
                Object.Destroy(characterObject);
            }

            return false;
        }
    }
}
