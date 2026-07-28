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

            vignette.InteractForTest("photograph");
            Assert.That(vignette.CurrentObjectiveId, Is.EqualTo("phone"));
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
            Assert.That(GameObject.Find("Street_Player"), Is.Not.Null);
            Assert.That(GameObject.Find("StreetArt_Lamp_West"), Is.Not.Null);
            Assert.That(GameObject.Find("StreetArt_BusBench"), Is.Not.Null);
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
            Assert.That(GameObject.Find("Cafe_Player"), Is.Not.Null);
            Assert.That(GameObject.Find("CafeArt_Table_0"), Is.Not.Null);
            Assert.That(GameObject.Find("CafeArt_ChairA_0"), Is.Not.Null);
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
