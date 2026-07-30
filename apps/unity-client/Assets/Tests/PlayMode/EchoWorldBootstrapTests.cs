using System.Collections;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace Echo.FreePrototype.Tests
{
    public sealed class EchoWorldBootstrapTests
    {
        [UnityTest]
        public IEnumerator PrototypeBuildsThreeExplorableScenesWithOptionalDetails()
        {
            yield return null;

            GameObject prototype = GameObject.Find("EchoFreePrototype");
            if (prototype == null)
            {
                prototype = new GameObject("EchoFreePrototype");
                prototype.AddComponent<EchoWorldBootstrap>();
                yield return null;
            }

            EchoWorldBootstrap bootstrap = prototype.GetComponent<EchoWorldBootstrap>();
            Assert.That(bootstrap, Is.Not.Null);
            Assert.That(GameObject.Find("Echo_MainCamera"), Is.Not.Null);
            Assert.That(bootstrap.ActiveSceneId, Is.EqualTo("bedroom"));
            Assert.That(GameObject.Find("BedroomArt_Bed"), Is.Not.Null);
            Assert.That(GameObject.Find("BedroomArt_Desk"), Is.Not.Null);
            Assert.That(GameObject.Find("BedroomArt_Photo"), Is.Not.Null);
            Assert.That(GameObject.Find("BedroomArt_Phone"), Is.Not.Null);
            Assert.That(
                LargestRendererDimension(GameObject.Find("BedroomArt_Bed")),
                Is.GreaterThan(1.5f),
                "The bed must be imported at real-world scale, not 1/100 scale.");
            Assert.That(
                RendererBounds(GameObject.Find("BedroomArt_Bed")).size.x,
                Is.GreaterThan(RendererBounds(GameObject.Find("BedroomArt_Bed")).size.z),
                "The day bed must face into the room so its full silhouette is visible.");
            Assert.That(
                RendererBounds(GameObject.Find("BedroomArt_Photo")).size.y,
                Is.GreaterThan(0.35f),
                "The photograph must stand visibly on the nightstand.");
            Assert.That(GameObject.Find("BedroomArt_PhotoImage"), Is.Not.Null);
            Assert.That(GameObject.Find("BedroomArt_PhotoMat"), Is.Not.Null);
            Assert.That(
                RendererBounds(GameObject.Find("BedroomArt_Chair")).size.y,
                Is.GreaterThan(0.95f),
                "The armchair must be upright rather than lying on its side.");
            Assert.That(GameObject.Find("Bedroom_WindowGlass"), Is.Not.Null);
            Assert.That(GameObject.Find("Noor_Player"), Is.Not.Null);
            yield return null;
            AssertGroundContact(
                GameObject.Find("Noor_Player"),
                GameObject.Find("Bedroom_Rug"),
                "Bedroom player");
            Assert.That(
                RendererBounds(GameObject.Find("Bedroom_BackWall")).size.y,
                Is.InRange(3.4f, 3.7f),
                "Room architecture must use a believable residential wall height.");
            Assert.That(
                RendererBounds(GameObject.Find("Bedroom_Floor")).size.x,
                Is.InRange(9.8f, 10.2f),
                "Bedroom width must remain proportional to the 1.78 m player reference.");
            Assert.That(GameObject.Find("Bedroom_Ceiling"), Is.Not.Null);
            EchoScaleAudit[] scaleAudits =
                prototype.GetComponentsInChildren<EchoScaleAudit>(true);
            Assert.That(
                scaleAudits.Length,
                Is.GreaterThanOrEqualTo(12),
                "Every imported scene model must carry real-world scale evidence.");
            foreach (EchoScaleAudit audit in scaleAudits)
            {
                if (audit.Category == "character")
                {
                    Assert.That(
                        audit.ActualBoundsMeters.y,
                        Is.InRange(audit.MinimumHeightMeters, audit.MaximumHeightMeters),
                        $"{audit.AssetId} must match the declared player-height reference.");
                    continue;
                }

                Assert.That(
                    Mathf.Max(
                        audit.ActualBoundsMeters.x,
                        Mathf.Max(audit.ActualBoundsMeters.y, audit.ActualBoundsMeters.z)),
                    Is.EqualTo(audit.TargetLongestMeters).Within(audit.ToleranceMeters),
                    $"{audit.AssetId} drifted from its declared metre scale.");
                Assert.That(
                    audit.ActualBoundsMeters.y,
                    Is.InRange(audit.MinimumHeightMeters, audit.MaximumHeightMeters),
                    $"{audit.AssetId} has the wrong orientation or semantic height.");
                if (audit.BlocksPlayer)
                {
                    Assert.That(
                        audit.BlockingCollider,
                        Is.Not.Null,
                        $"{audit.AssetId} is blocking furniture and needs derived collision.");
                }
            }
            Assert.That(
                prototype.GetComponentsInChildren<EchoInteractable>(true).Length,
                Is.GreaterThanOrEqualTo(6),
                "The Bedroom slice must have a required route and optional noticing points.");

            EchoThirdPersonController controller =
                GameObject.Find("Noor_Player").GetComponent<EchoThirdPersonController>();
            EchoBedroomVignette vignette = prototype.GetComponent<EchoBedroomVignette>();
            Assert.That(controller, Is.Not.Null, "The Bedroom must have direct movement, not only an orbit camera.");
            Assert.That(vignette, Is.Not.Null);
            Assert.That(vignette.CurrentObjectiveId, Is.EqualTo("photograph"));
            Assert.That(controller.AcceptsInput, Is.True);

            CharacterController characterCollision =
                controller.GetComponent<CharacterController>();
            Vector3 collisionTestStart = controller.transform.position;
            Physics.SyncTransforms();
            for (int collisionStep = 0; collisionStep < 60; collisionStep++)
            {
                characterCollision.Move(Vector3.left * 0.1f);
            }
            Assert.That(
                controller.transform.position.x,
                Is.GreaterThan(-3.1f),
                "The half-packed suitcases must physically block the player.");
            characterCollision.enabled = false;
            controller.transform.position = collisionTestStart;
            characterCollision.enabled = true;
            Physics.SyncTransforms();

            Vector3 movementStart = controller.transform.position;
            Quaternion rotationStart = controller.transform.rotation;
            controller.MoveForTest(Vector2.right, 0.05f);
            Assert.That(
                Quaternion.Angle(rotationStart, controller.transform.rotation),
                Is.LessThanOrEqualTo(15.1f),
                "A direction change must turn gradually instead of snapping.");
            controller.MoveForTest(Vector2.right, 0.25f);
            Assert.That(
                Vector3.Distance(movementStart, controller.transform.position),
                Is.GreaterThan(0.25f),
                "A movement command must visibly translate the playable character.");

            Assert.That(GameObject.Find("BedroomArt_PhotoGroup"), Is.Not.Null);
            Assert.That(
                GameObject.Find("BedroomArt_PhotoGroup").transform.localPosition,
                Is.EqualTo(new Vector3(-1.72f, 0.55f, 2.23f)),
                "The photograph pickup pivot must be anchored to the visible frame.");
            Assert.That(GameObject.Find("BedroomArt_Suitcase"), Is.Not.Null);
            EchoInteractionActionDirector bedroomActions = null;
            foreach (EchoInteractionActionDirector candidate in
                     prototype.GetComponentsInChildren<EchoInteractionActionDirector>(true))
            {
                if (candidate.HasActionFor("photograph"))
                {
                    bedroomActions = candidate;
                    break;
                }
            }
            Assert.That(bedroomActions, Is.Not.Null, "Bedroom interactions need embodied responses.");
            Assert.That(bedroomActions.HasActionFor("photograph"), Is.True, "Noor must lift the photograph by hand.");
            Assert.That(bedroomActions.HasActionFor("suitcase"), Is.True, "Noor must give the suitcase a grounded handle pull.");
            Assert.That(bedroomActions.HasActionFor("bed"), Is.True, "Noor must face the bed.");
            Assert.That(bedroomActions.HasActionFor("phone"), Is.True);

            Transform photograph = GameObject.Find("BedroomArt_PhotoGroup").transform;
            Vector3 photographRestPosition = photograph.localPosition;
            Quaternion photographRestRotation = photograph.localRotation;
            Animator playerAnimator =
                GameObject.Find("Noor_Player").GetComponentInChildren<Animator>();
            Transform rightHand = playerAnimator != null && playerAnimator.isHuman
                ? playerAnimator.GetBoneTransform(HumanBodyBones.RightHand)
                : null;
            float photographStartDistanceToHand = rightHand != null
                ? Vector3.Distance(photograph.position, rightHand.position)
                : 10f;
            vignette.InteractForTest("photograph");
            yield return new WaitForSeconds(0.18f);
            Assert.That(
                photograph.localPosition,
                Is.EqualTo(photographRestPosition),
                "The photograph must not teleport before Noor finishes turning.");
            Assert.That(
                bedroomActions.IsRunning("photograph"),
                Is.True,
                "The hand pickup must remain in progress long enough to read.");

            yield return new WaitForSeconds(0.8f);
            Assert.That(
                Vector3.Distance(photograph.localPosition, photographRestPosition),
                Is.GreaterThan(0.08f),
                "The photograph must move visibly after the slow reach begins.");
            if (rightHand != null)
            {
                Assert.That(
                    Vector3.Distance(photograph.position, rightHand.position),
                    Is.LessThan(photographStartDistanceToHand * 0.7f),
                    "The photograph must travel toward the character's hand.");
            }

            yield return new WaitForSeconds(0.65f);
            if (rightHand != null)
            {
                Assert.That(
                    Vector3.Distance(photograph.position, rightHand.position),
                    Is.LessThan(0.18f),
                    "The photograph must be held at the rigged hand, not floating at chest height.");
            }
            Quaternion expectedPhotographRotation =
                GameObject.Find("Noor_Player").transform.rotation * Quaternion.Euler(-8f, 35f, 0f);
            Assert.That(
                Quaternion.Angle(photograph.rotation, expectedPhotographRotation),
                Is.LessThan(4f),
                "The held photograph must face Noor in a readable upright orientation.");

            yield return new WaitForSeconds(2.9f);
            Assert.That(bedroomActions.IsRunning("photograph"), Is.False);
            Assert.That(photograph.localPosition, Is.EqualTo(photographRestPosition));
            Assert.That(photograph.localRotation, Is.EqualTo(photographRestRotation));

            Transform suitcase = GameObject.Find("BedroomArt_Suitcase").transform;
            Vector3 suitcaseRestPosition = suitcase.localPosition;
            bedroomActions.Play("suitcase");
            yield return new WaitForSeconds(0.18f);
            Assert.That(
                suitcase.localPosition,
                Is.EqualTo(suitcaseRestPosition),
                "The suitcase must not jump before the handle pull starts.");
            yield return new WaitForSeconds(0.85f);
            float suitcaseTravel =
                Vector3.Distance(suitcase.localPosition, suitcaseRestPosition);
            Assert.That(
                suitcaseTravel,
                Is.InRange(0.04f, 0.24f),
                "The suitcase must make a restrained grounded movement.");
            Assert.That(
                Mathf.Abs(suitcase.localPosition.y - suitcaseRestPosition.y),
                Is.LessThan(0.08f),
                "The suitcase must not float upward like a handheld prop.");
            yield return new WaitForSeconds(2.7f);
            Assert.That(suitcase.localPosition, Is.EqualTo(suitcaseRestPosition));

            vignette.RestartForTest();
            Assert.That(
                photograph.localPosition,
                Is.EqualTo(photographRestPosition),
                "Replaying the vignette must preserve supported props.");

            vignette.InteractForTest("photograph");
            Assert.That(vignette.CurrentObjectiveId, Is.EqualTo("phone"));
            Assert.That(
                bedroomActions.TimesPlayed("photograph"),
                Is.GreaterThanOrEqualTo(1),
                "Interacting with the photograph must trigger the hand pickup.");
            bedroomActions.ResetActions();
            Assert.That(
                GameObject.Find("BedroomArt_PhotoGroup").transform.localPosition,
                Is.EqualTo(photographRestPosition),
                "Restarting an interaction sequence must restore the photograph.");
            vignette.InteractForTest("phone");
            Assert.That(vignette.CurrentObjectiveId, Is.EqualTo("choice"));
            vignette.ChooseForTest(true);
            Assert.That(vignette.IsComplete, Is.True, "The vertical slice must have a playable ending.");

            bootstrap.ShowHarborStreet();
            yield return null;

            Assert.That(bootstrap.ActiveSceneId, Is.EqualTo("harbor-street"));
            Assert.That(GameObject.Find("Cafe_Saffron"), Is.Not.Null);
            Assert.That(GameObject.Find("Bookshop_SecondChapter"), Is.Not.Null);
            Assert.That(GameObject.Find("Public_BusStop"), Is.Not.Null);
            Assert.That(
                GameObject.Find("Mina_Mixamo") != null || GameObject.Find("Mina_Walking") != null,
                Is.True,
                "A pedestrian must be present even when the optional Mixamo FBX is absent.");
            if (Resources.Load<GameObject>("Characters/Noor/Walking") != null)
            {
                AssertRiggedCrowdPerson("Mina_Mixamo", 0);
                AssertRiggedCrowdPerson("Jonas_Rigged", 1);
                AssertRiggedCrowdPerson("Visitor_Rigged", 2);
                AssertRiggedCrowdPerson("CafeGuest_Rigged", 3);
                AssertRiggedCrowdPerson("BusPassenger", 4);
                AssertRiggedCrowdPerson("PlazaFriend_Rigged", 5);
            }
            Assert.That(GameObject.Find("Street_Player"), Is.Not.Null);
            AssertGroundContact(
                GameObject.Find("Street_Player"),
                GameObject.Find("Road"),
                "Street player");
            Assert.That(GameObject.Find("StreetArt_Lamp_West"), Is.Not.Null);
            Assert.That(GameObject.Find("StreetArt_BusBench"), Is.Not.Null);
            Assert.That(GameObject.Find("StreetArt_ParkedCar"), Is.Not.Null);
            Assert.That(GameObject.Find("StreetArt_FireHydrant"), Is.Not.Null);
            Assert.That(GameObject.Find("StreetArt_BookshopPlanter"), Is.Not.Null);
            Assert.That(GameObject.Find("StreetArt_RouteMapCard"), Is.Not.Null);
            Assert.That(
                LargestRendererDimension(GameObject.Find("StreetArt_ParkedCar")),
                Is.GreaterThan(3.5f),
                "The parked car must keep its real-world footprint.");
            Assert.That(
                RendererBounds(GameObject.Find("StreetArt_Lamp_West")).size.y,
                Is.GreaterThan(3f),
                "The imported street lamp must retain its real-world height.");

            EchoPlayableVignette streetVignette = null;
            foreach (EchoPlayableVignette candidate in prototype.GetComponents<EchoPlayableVignette>())
            {
                if (candidate.enabled)
                {
                    streetVignette = candidate;
                    break;
                }
            }
            Assert.That(streetVignette, Is.Not.Null);
            Assert.That(streetVignette.CurrentObjectiveId, Is.EqualTo("route_map"));
            streetVignette.InteractForTest("route_map");
            streetVignette.InteractForTest("visitor");
            streetVignette.ChooseForTest(true);
            Assert.That(streetVignette.IsComplete, Is.True);

            bootstrap.ShowCafeShop();
            yield return null;

            Assert.That(bootstrap.ActiveSceneId, Is.EqualTo("cafe-shop"));
            Assert.That(GameObject.Find("CafeInterior_Counter"), Is.Not.Null);
            Assert.That(GameObject.Find("ForgottenSketchbook"), Is.Not.Null);
            Assert.That(GameObject.Find("TipJar"), Is.Not.Null);
            Assert.That(
                GameObject.Find("Amira_Mixamo") != null || GameObject.Find("Amira_Barista") != null,
                Is.True,
                "The café must have a barista with or without the optional Mixamo FBX.");
            if (Resources.Load<GameObject>("Characters/Noor/Walking") != null)
            {
                AssertRiggedCrowdPerson("Amira_Mixamo", 6);
                AssertRiggedCrowdPerson("Cafe_LastGuest", 7);
            }
            Assert.That(GameObject.Find("Cafe_Player"), Is.Not.Null);
            AssertGroundContact(
                GameObject.Find("Cafe_Player"),
                GameObject.Find("CafeInterior_Floor"),
                "Café player");
            Assert.That(GameObject.Find("CafeArt_Table_0"), Is.Not.Null);
            Assert.That(GameObject.Find("CafeArt_ChairA_0"), Is.Not.Null);
            Assert.That(GameObject.Find("CafeArt_ReadingChair"), Is.Not.Null);
            Assert.That(GameObject.Find("CafeArt_CornerPlant"), Is.Not.Null);
            EchoInteractionActionDirector cafeActions =
                GameObject.Find("Scene_CafeShop").GetComponent<EchoInteractionActionDirector>();
            Assert.That(cafeActions, Is.Not.Null);
            Assert.That(cafeActions.HasActionFor("sketchbook"), Is.True, "The player must face the sketchbook.");
            Assert.That(
                RendererBounds(GameObject.Find("CafeArt_ChairA_0")).size.y,
                Is.GreaterThan(0.7f),
                "The café chair must be upright and retain real-world scale.");

            EchoPlayableVignette cafeVignette = null;
            foreach (EchoPlayableVignette candidate in prototype.GetComponents<EchoPlayableVignette>())
            {
                if (candidate.enabled)
                {
                    cafeVignette = candidate;
                    break;
                }
            }
            Assert.That(cafeVignette, Is.Not.Null);
            Assert.That(cafeVignette.CurrentObjectiveId, Is.EqualTo("sketchbook"));
            cafeVignette.InteractForTest("sketchbook");
            cafeVignette.InteractForTest("door");
            cafeVignette.ChooseForTest(false);
            Assert.That(cafeVignette.IsComplete, Is.True);

            Object.Destroy(prototype);
            yield return null;
        }

        private static float LargestRendererDimension(GameObject target)
        {
            Bounds bounds = RendererBounds(target);
            return Mathf.Max(bounds.size.x, Mathf.Max(bounds.size.y, bounds.size.z));
        }

        private static void AssertGroundContact(GameObject character, GameObject ground, string label)
        {
            float footHeight = RendererBounds(character).min.y;
            float groundHeight = RendererBounds(ground).max.y;
            Physics.SyncTransforms();
            RaycastHit[] hits = Physics.RaycastAll(
                character.transform.position + Vector3.up,
                Vector3.down,
                2.5f,
                Physics.DefaultRaycastLayers,
                QueryTriggerInteraction.Ignore);
            foreach (RaycastHit hit in hits)
            {
                if (!hit.collider.transform.IsChildOf(character.transform) &&
                    hit.point.y <= character.transform.position.y + 0.2f)
                {
                    groundHeight = Mathf.Max(groundHeight, hit.point.y);
                }
            }
            Assert.That(
                footHeight,
                Is.InRange(groundHeight - 0.025f, groundHeight + 0.035f),
                $"{label} feet must meet the visible ground surface.");
        }

        private static void AssertRiggedCrowdPerson(string objectName, int styleIndex)
        {
            GameObject person = GameObject.Find(objectName);
            Assert.That(person, Is.Not.Null, $"{objectName} must be present.");
            SkinnedMeshRenderer[] renderers =
                person.GetComponentsInChildren<SkinnedMeshRenderer>(true);
            Assert.That(
                renderers.Length,
                Is.GreaterThan(0),
                $"{objectName} must use the rigged human mesh, not primitive mannequin parts.");
            bool hasVariedMaterial = false;
            foreach (SkinnedMeshRenderer renderer in renderers)
            {
                foreach (Material material in renderer.sharedMaterials)
                {
                    if (material != null &&
                        material.name.Contains($"Echo_Crowd_{styleIndex}_"))
                    {
                        hasVariedMaterial = true;
                    }
                }
            }
            Assert.That(
                hasVariedMaterial,
                Is.True,
                $"{objectName} must receive its own crowd styling.");
        }

        private static Bounds RendererBounds(GameObject target)
        {
            Renderer[] renderers = target.GetComponentsInChildren<Renderer>(true);
            Assert.That(renderers.Length, Is.GreaterThan(0), $"{target.name} needs visible renderers.");
            Bounds bounds = renderers[0].bounds;
            for (int index = 1; index < renderers.Length; index++)
            {
                bounds.Encapsulate(renderers[index].bounds);
            }
            return bounds;
        }
    }
}
