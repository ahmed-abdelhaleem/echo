using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.InputSystem;
using UnityEngine.Rendering;

namespace Echo.FreePrototype
{
    /// <summary>
    /// A dependency-free Unity Personal proof of concept for Echo.
    /// The scene is created at runtime so it can be tested immediately in any open scene.
    /// </summary>
    [DefaultExecutionOrder(-1000)]
    public sealed class EchoWorldBootstrap : MonoBehaviour
    {
        private const string PrototypeName = "EchoFreePrototype";

        private enum PrototypeScene
        {
            Bedroom,
            HarborStreet,
            CafeShop
        }

        private readonly Dictionary<string, Material> materials = new();
        private readonly List<EchoInteractable> bedroomInteractions = new();
        private readonly List<EchoInteractable> streetInteractions = new();
        private readonly List<EchoInteractable> cafeInteractions = new();
        private GUIStyle titleStyle;
        private GUIStyle bodyStyle;
        private GUIStyle labelStyle;
        private GUIStyle buttonStyle;
        private GUIStyle smallStyle;
        private Light warmWindowLight;
        private Light bedroomLampLight;
        private Light cafePendantLight;
        private Light streetSun;
        private Light bedroomSun;
        private Light cafeSun;
        private Light sun;
        private Transform bedroomRoot;
        private Transform streetRoot;
        private Transform cafeRoot;
        private EchoOrbitCamera orbitCamera;
        private EchoThirdPersonCamera thirdPersonCamera;
        private EchoBedroomVignette bedroomVignette;
        private EchoThirdPersonController bedroomController;
        private Transform bedroomPlayer;
        private EchoPlayableVignette streetVignette;
        private EchoThirdPersonController streetController;
        private Transform streetPlayer;
        private EchoPlayableVignette cafeVignette;
        private EchoThirdPersonController cafeController;
        private Transform cafePlayer;
        private Camera mainCamera;
        private PrototypeScene activeScene;
        private int storyStep;
        private string outcome = string.Empty;
        private string inspectedObservation = string.Empty;
        private float choicePulse;
        private float observationTimer;

        public string ActiveSceneId => activeScene switch
        {
            PrototypeScene.Bedroom => "bedroom",
            PrototypeScene.CafeShop => "cafe-shop",
            _ => "harbor-street"
        };

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        private static void StartPrototype()
        {
            if (GameObject.Find(PrototypeName) != null)
            {
                return;
            }

            GameObject host = new(PrototypeName);
            host.AddComponent<EchoWorldBootstrap>();
        }

        private void Awake()
        {
            DisableTemplateObjects();
            ConfigureAtmosphere();
            CreateMaterials();
            streetRoot = CreateSceneRoot("Scene_HarborStreet");
            BuildDiorama(streetRoot);
            CreateStreetLighting(streetRoot);
            bedroomRoot = CreateSceneRoot("Scene_Bedroom");
            BuildBedroom(bedroomRoot);
            CreateBedroomLighting(bedroomRoot);
            cafeRoot = CreateSceneRoot("Scene_CafeShop");
            BuildCafeShop(cafeRoot);
            CreateCafeLighting(cafeRoot);
            CreateCamera();
            CreateBedroomGameplay();
            CreateStreetGameplay();
            CreateCafeGameplay();
            ShowBedroom();
        }

        private void Update()
        {
            choicePulse = Mathf.Lerp(choicePulse, 0f, Time.deltaTime * 2.4f);
            observationTimer = Mathf.Max(0f, observationTimer - Time.deltaTime);
            if (observationTimer <= 0f)
            {
                inspectedObservation = string.Empty;
            }

            if (activeScene == PrototypeScene.HarborStreet && warmWindowLight != null)
            {
                warmWindowLight.intensity = 5.2f + Mathf.Sin(Time.time * 1.7f) * 0.18f + choicePulse;
            }
            if (activeScene == PrototypeScene.Bedroom && bedroomLampLight != null)
            {
                bedroomLampLight.intensity = 6.8f + Mathf.Sin(Time.time * 1.25f) * 0.12f + choicePulse;
            }
            if (activeScene == PrototypeScene.CafeShop && cafePendantLight != null)
            {
                cafePendantLight.intensity = 5.4f + Mathf.Sin(Time.time * 1.45f) * 0.14f + choicePulse;
            }

        }

        private Transform CreateSceneRoot(string rootName)
        {
            Transform sceneRoot = new GameObject(rootName).transform;
            sceneRoot.SetParent(transform);
            return sceneRoot;
        }

        private void DisableTemplateObjects()
        {
            foreach (MonoBehaviour behaviour in FindObjectsByType<MonoBehaviour>())
            {
                if (behaviour.GetType().FullName == "Echo.Vignette.BoundedCameraOrbit")
                {
                    behaviour.enabled = false;
                }
            }

            foreach (Camera sceneCamera in FindObjectsByType<Camera>())
            {
                sceneCamera.enabled = false;
                AudioListener listener = sceneCamera.GetComponent<AudioListener>();
                if (listener != null) listener.enabled = false;
            }

            foreach (Light sceneLight in FindObjectsByType<Light>())
            {
                sceneLight.enabled = false;
            }

            foreach (Volume sceneVolume in FindObjectsByType<Volume>())
            {
                sceneVolume.enabled = false;
            }
        }

        private static void ConfigureAtmosphere()
        {
            RenderSettings.fog = true;
            RenderSettings.fogMode = FogMode.ExponentialSquared;
            RenderSettings.fogDensity = 0.009f;
            RenderSettings.fogColor = new Color(0.075f, 0.095f, 0.14f);
            RenderSettings.ambientMode = AmbientMode.Trilight;
            RenderSettings.ambientSkyColor = new Color(0.17f, 0.22f, 0.32f);
            RenderSettings.ambientEquatorColor = new Color(0.1f, 0.12f, 0.18f);
            RenderSettings.ambientGroundColor = new Color(0.045f, 0.05f, 0.075f);
            RenderSettings.reflectionIntensity = 0.45f;
        }

        private void CreateMaterials()
        {
            AddMaterial("Road", new Color(0.055f, 0.065f, 0.085f), 0.12f);
            AddMaterial("Sidewalk", new Color(0.34f, 0.38f, 0.43f), 0.2f);
            AddMaterial("Stone", new Color(0.52f, 0.54f, 0.56f), 0.35f);
            AddMaterial("Cream", new Color(0.84f, 0.76f, 0.65f), 0.28f);
            AddMaterial("Terracotta", new Color(0.62f, 0.23f, 0.19f), 0.24f);
            AddMaterial("Ocean", new Color(0.05f, 0.38f, 0.48f), 0.55f);
            AddMaterial("Teal", new Color(0.035f, 0.24f, 0.28f), 0.4f);
            AddMaterial("Gold", new Color(0.95f, 0.57f, 0.18f), 0.55f, new Color(0.75f, 0.28f, 0.04f));
            AddMaterial("WarmWindow", new Color(0.92f, 0.48f, 0.2f), 0.65f, new Color(1.8f, 0.56f, 0.13f));
            AddMaterial("CoolWindow", new Color(0.08f, 0.23f, 0.35f), 0.85f, new Color(0.03f, 0.22f, 0.4f));
            AddMaterial("White", new Color(0.91f, 0.91f, 0.86f), 0.2f);
            AddMaterial("Charcoal", new Color(0.055f, 0.06f, 0.075f), 0.45f);
            AddMaterial("Wood", new Color(0.32f, 0.15f, 0.075f), 0.25f);
            AddMaterial("Leaf", new Color(0.08f, 0.34f, 0.21f), 0.15f);
            AddMaterial("LeafLight", new Color(0.19f, 0.48f, 0.25f), 0.15f);
            AddMaterial("Water", new Color(0.04f, 0.52f, 0.7f), 0.9f, new Color(0.02f, 0.16f, 0.22f));
            AddMaterial("Rose", new Color(0.67f, 0.19f, 0.3f), 0.32f);
            AddMaterial("Indigo", new Color(0.18f, 0.2f, 0.46f), 0.3f);
            AddMaterial("Skin1", new Color(0.58f, 0.32f, 0.19f), 0.35f);
            AddMaterial("Skin2", new Color(0.84f, 0.58f, 0.39f), 0.35f);
            AddMaterial("Skin3", new Color(0.36f, 0.18f, 0.1f), 0.35f);
        }

        private void AddMaterial(string key, Color color, float smoothness, Color? emission = null)
        {
            Shader shader = Shader.Find("Universal Render Pipeline/Lit");
            if (shader == null) shader = Shader.Find("Standard");
            Material material = new(shader) { name = $"Echo_{key}" };
            if (material.HasProperty("_BaseColor")) material.SetColor("_BaseColor", color);
            if (material.HasProperty("_Color")) material.SetColor("_Color", color);
            if (material.HasProperty("_Smoothness")) material.SetFloat("_Smoothness", smoothness);
            if (emission.HasValue && material.HasProperty("_EmissionColor"))
            {
                material.EnableKeyword("_EMISSION");
                material.SetColor("_EmissionColor", emission.Value);
            }
            materials[key] = material;
        }

        private void BuildDiorama(Transform root)
        {
            Box("DioramaBase", new Vector3(0f, -0.85f, 4.5f), new Vector3(19f, 1.5f, 27f), "Charcoal", root);
            Box("Road", new Vector3(0f, 0f, 4.5f), new Vector3(6.4f, 0.18f, 25f), "Road", root);
            Box("LeftSidewalk", new Vector3(-4.7f, 0.16f, 4.5f), new Vector3(3f, 0.35f, 25f), "Sidewalk", root);
            Box("RightSidewalk", new Vector3(4.7f, 0.16f, 4.5f), new Vector3(3f, 0.35f, 25f), "Sidewalk", root);

            for (int z = -6; z <= 14; z += 4)
            {
                Box($"RoadMark{z}", new Vector3(0f, 0.13f, z), new Vector3(0.12f, 0.03f, 1.8f), "Gold", root);
            }

            for (int x = -2; x <= 2; x++)
            {
                Box($"Crosswalk{x}", new Vector3(x * 0.85f, 0.14f, 7.4f), new Vector3(0.54f, 0.035f, 2.2f), "White", root);
            }

            BuildCafe(new Vector3(6.0f, 0.35f, -1f), root);
            BuildBookshop(new Vector3(-6.0f, 0.35f, 1.5f), root);
            BuildApartments(root);
            BuildBusStop(new Vector3(-4.35f, 0.35f, -5.6f), root);
            BuildPlaza(new Vector3(0f, 0.18f, 14.2f), root);
            BuildStreetFurniture(root);
            BuildPeople(root);
            BuildProductionStreetArt(root);
            BuildStreetInteractions(root);
        }

        private void BuildProductionStreetArt(Transform root)
        {
            CreatePolyHavenModel(
                "street_lamp_01", "StreetArt_Lamp_West",
                new Vector3(-5.05f, 0.35f, -2.8f), Quaternion.Euler(-90f, 0f, 0f),
                Vector3.one * 0.92f, root);
            CreatePolyHavenModel(
                "street_lamp_01", "StreetArt_Lamp_East",
                new Vector3(5.05f, 0.35f, 7.4f), Quaternion.Euler(-90f, 0f, 0f),
                Vector3.one * 0.92f, root);
            CreatePolyHavenModel(
                "modular_street_seating", "StreetArt_PlazaSeating",
                new Vector3(3.8f, 0.36f, 12.5f), Quaternion.Euler(0f, -18f, 0f),
                Vector3.one, root);
            CreatePolyHavenModel(
                "painted_wooden_bench", "StreetArt_BusBench",
                new Vector3(-4.6f, 0.36f, -4.9f), Quaternion.Euler(-90f, 90f, 0f),
                Vector3.one * 1.08f, root);
            CreatePolyHavenModel(
                "metal_trash_can", "StreetArt_TrashCan",
                new Vector3(-5.2f, 0.36f, -3.7f), Quaternion.Euler(0f, 12f, 0f),
                Vector3.one * 0.78f, root);

            CreateFurnitureCollider(
                "StreetCollision_BusBench",
                new Vector3(-4.6f, 0.78f, -4.9f),
                new Vector3(0.75f, 0.85f, 2.2f),
                root);
            CreateFurnitureCollider(
                "StreetCollision_PlazaSeating",
                new Vector3(3.8f, 0.72f, 12.5f),
                new Vector3(3.3f, 0.75f, 1.15f),
                root);

            CreateStreetPracticalLight("StreetArt_LampGlow_West", new Vector3(-5.05f, 3.45f, -2.8f), root);
            CreateStreetPracticalLight("StreetArt_LampGlow_East", new Vector3(5.05f, 3.45f, 7.4f), root);
        }

        private static void CreateStreetPracticalLight(string objectName, Vector3 position, Transform root)
        {
            GameObject lightObject = new(objectName);
            lightObject.transform.SetParent(root, false);
            lightObject.transform.localPosition = position;
            Light practical = lightObject.AddComponent<Light>();
            practical.type = LightType.Point;
            practical.color = new Color(1f, 0.52f, 0.22f);
            practical.range = 9f;
            practical.intensity = 4.2f;
            practical.shadows = LightShadows.None;
        }

        private void BuildStreetInteractions(Transform root)
        {
            streetInteractions.Clear();
            CreateSceneInteraction(
                streetInteractions,
                "route_map",
                "Read the route map",
                "The last line was replaced this morning. The visitor is still tracing yesterday's route with one finger.",
                new Vector3(-4.3f, 0.9f, -5.55f), 0, false, root);
            CreateSceneInteraction(
                streetInteractions,
                "visitor",
                "Ask where they are going",
                "They show you an address across the harbor and try to hide how worried they are about missing the final bus.",
                new Vector3(-3.45f, 0.8f, -4.65f), 1, false, root);
            CreateSceneInteraction(
                streetInteractions,
                "bus_bench",
                "Notice the worn bench",
                "Years of waiting have polished one corner of the painted wood smooth.",
                new Vector3(-4.5f, 0.7f, -3.95f), 0, true, root);
            CreateSceneInteraction(
                streetInteractions,
                "bookshop",
                "Look through the bookshop window",
                "A handwritten card recommends a novel about two strangers who keep almost meeting.",
                new Vector3(-4.8f, 0.8f, 1.6f), 0, true, root);
            CreateSceneInteraction(
                streetInteractions,
                "crossing",
                "Watch the crossing",
                "Shoes, bicycle wheels, and shopping bags negotiate the same few seconds of green light.",
                new Vector3(0f, 0.45f, 7.4f), 0, true, root);
            CreateSceneInteraction(
                streetInteractions,
                "harbor",
                "Listen beyond the traffic",
                "Under the engines and voices, water keeps folding against the harbor wall.",
                new Vector3(0f, 0.7f, 14.5f), 0, true, root);
        }

        private void BuildBedroom(Transform root)
        {
            // Architecture uses the same metre convention as props and the
            // 1.78 m player reference. The former 12 × 9.5 × 6 m shell made
            // correctly sized furniture read like miniatures.
            Box("Bedroom_Floor", new Vector3(0f, -0.28f, 0f), new Vector3(10f, 0.5f, 8f), "Wood", root);
            Box("Bedroom_BackWall", new Vector3(0f, 1.55f, 3.85f), new Vector3(10f, 3.6f, 0.35f), "Cream", root);
            Box("Bedroom_LeftWall", new Vector3(-4.85f, 1.55f, 0f), new Vector3(0.35f, 3.6f, 8f), "Terracotta", root);
            Box("Bedroom_RightWall", new Vector3(4.85f, 1.55f, 0f), new Vector3(0.35f, 3.6f, 8f), "Indigo", root);
            Box("Bedroom_Ceiling", new Vector3(0f, 3.38f, 0f), new Vector3(10f, 0.18f, 8f), "Cream", root);
            Box("Bedroom_CeilingBeam", new Vector3(0f, 3.25f, 3.62f), new Vector3(10.3f, 0.25f, 0.45f), "Charcoal", root);

            BuildBedroomWindow(root);
            BuildProductionBedroomArt(root);
        }

        private void BuildProductionBedroomArt(Transform root)
        {
            // Choice: use reproducible CC0 Poly Haven furniture for the first
            // vertical slice. The primitive alternative remains useful for
            // greyboxing, but cannot meet the production visual target.
            CreatePolyHavenModel(
                "chinese_sofa", "BedroomArt_Bed",
                new Vector3(-3.45f, 0f, 3.3f), Quaternion.Euler(-90f, 0f, 0f),
                Vector3.one * 1.05f, root);
            CreatePolyHavenModel(
                "side_table_01", "BedroomArt_Nightstand",
                new Vector3(-1.72f, 0f, 2.3f), Quaternion.Euler(0f, 3f, 0f),
                Vector3.one, root);
            CreatePolyHavenModel(
                "dining_chair_02", "BedroomArt_Chair",
                new Vector3(1.95f, 0f, -0.55f), Quaternion.Euler(-90f, -28f, 0f),
                Vector3.one * 1.12f, root);
            CreatePolyHavenModel(
                "metal_office_desk", "BedroomArt_Desk",
                new Vector3(3.35f, 0f, 2.15f), Quaternion.Euler(0f, 180f, 0f),
                Vector3.one, root);
            CreatePolyHavenModel(
                "desk_lamp_arm_01", "BedroomArt_DeskLamp",
                new Vector3(3.75f, 0.84f, 2.18f), Quaternion.Euler(0f, -24f, 0f),
                Vector3.one * 0.72f, root);
            CreatePolyHavenModel(
                "binder_notebook", "BedroomArt_Notebook",
                new Vector3(2.95f, 0.84f, 2.15f), Quaternion.Euler(0f, 14f, 0f),
                Vector3.one * 0.85f, root);
            CreatePolyHavenModel(
                "potted_plant_01", "BedroomArt_Plant",
                new Vector3(4.1f, 0f, -2.45f), Quaternion.Euler(0f, 18f, 0f),
                Vector3.one * 0.72f, root);
            GameObject photoFrame = CreatePolyHavenModel(
                "standing_picture_frame_01", "BedroomArt_Photo",
                new Vector3(-1.72f, 0.55f, 2.23f), Quaternion.Euler(-90f, -8f, 0f),
                Vector3.one * 1.65f, root);
            if (photoFrame != null)
            {
                Box(
                    "BedroomArt_PhotoMat",
                    new Vector3(-1.72f, 0.81f, 2.11f),
                    new Vector3(0.46f, 0.55f, 0.026f),
                    "Gold",
                    root,
                    Quaternion.Euler(0f, -8f, 0f));
                Box(
                    "BedroomArt_PhotoImage",
                    new Vector3(-1.72f, 0.81f, 2.09f),
                    new Vector3(0.33f, 0.42f, 0.018f),
                    "Rose",
                    root,
                    Quaternion.Euler(0f, -8f, 0f));
            }
            CreatePolyHavenModel(
                "vintage_suitcase", "BedroomArt_Suitcase",
                new Vector3(-3.9f, 0f, -2.3f), Quaternion.Euler(0f, 8f, 0f),
                Vector3.one * 0.78f, root);
            CreatePolyHavenModel(
                "alarm_clock_01", "BedroomArt_AlarmClock",
                new Vector3(-2.02f, 0.55f, 2.23f), Quaternion.Euler(0f, 8f, 0f),
                Vector3.one * 1.05f, root);
            CreatePolyHavenModel(
                "modern_wooden_cabinet", "BedroomArt_Cabinet",
                new Vector3(3.55f, 0f, 3.45f), Quaternion.Euler(0f, 180f, 0f),
                Vector3.one, root);

            Box(
                "Bedroom_Rug",
                new Vector3(0.35f, 0.025f, -0.35f),
                new Vector3(4.6f, 0.045f, 3.15f),
                "Indigo",
                root,
                Quaternion.Euler(0f, -7f, 0f));
            BuildBedroomHeroProps(root);
            BuildBedroomCollision(root);
            BuildBedroomInteractions(root);
        }

        private void BuildBedroomHeroProps(Transform root)
        {
            Transform phone = new GameObject("BedroomArt_Phone").transform;
            phone.SetParent(root, false);
            phone.localPosition = new Vector3(3.4f, 0.85f, 2.1f);
            phone.localRotation = Quaternion.Euler(0f, -18f, 0f);
            Box("PhoneBody", Vector3.zero, new Vector3(0.38f, 0.055f, 0.72f), "Charcoal", phone);
            Box("PhoneScreen", new Vector3(0f, 0.034f, 0f), new Vector3(0.34f, 0.012f, 0.65f), "CoolWindow", phone);
            GameObject phoneGlowObject = new("PhoneNotificationGlow");
            phoneGlowObject.transform.SetParent(phone, false);
            phoneGlowObject.transform.localPosition = new Vector3(0f, 0.18f, 0f);
            Light phoneGlow = phoneGlowObject.AddComponent<Light>();
            phoneGlow.type = LightType.Point;
            phoneGlow.color = new Color(0.16f, 0.52f, 1f);
            phoneGlow.range = 1.8f;
            phoneGlow.intensity = 1.8f;
            phoneGlow.shadows = LightShadows.None;

            Transform mug = new GameObject("BedroomArt_Mug").transform;
            mug.SetParent(root, false);
            mug.localPosition = new Vector3(3.95f, 0.82f, 1.88f);
            Cylinder("MugBody", Vector3.zero, new Vector3(0.16f, 0.2f, 0.16f), "Gold", mug);
            Cylinder(
                "MugDarkTop",
                new Vector3(0f, 0.205f, 0f),
                new Vector3(0.135f, 0.012f, 0.135f),
                "Charcoal",
                mug);
        }

        private void BuildBedroomCollision(Transform root)
        {
            CreateFurnitureCollider("BedroomCollision_LeftWall", new Vector3(-4.65f, 1.65f, 0f), new Vector3(0.3f, 3.3f, 7.7f), root);
            CreateFurnitureCollider("BedroomCollision_RightWall", new Vector3(4.65f, 1.65f, 0f), new Vector3(0.3f, 3.3f, 7.7f), root);
            CreateFurnitureCollider("BedroomCollision_BackWall", new Vector3(0f, 1.65f, 3.67f), new Vector3(9.3f, 3.3f, 0.3f), root);
            CreateFurnitureCollider("BedroomCollision_Bed", new Vector3(-3.45f, 0.52f, 3.3f), new Vector3(2.65f, 1.05f, 1.35f), root);
            CreateFurnitureCollider("BedroomCollision_Nightstand", new Vector3(-1.72f, 0.4f, 2.3f), new Vector3(0.8f, 0.8f, 0.8f), root);
            CreateFurnitureCollider("BedroomCollision_Chair", new Vector3(1.95f, 0.55f, -0.55f), new Vector3(1f, 1.2f, 1f), root);
            CreateFurnitureCollider("BedroomCollision_Desk", new Vector3(3.35f, 0.55f, 2.15f), new Vector3(2.25f, 1.1f, 0.95f), root);
            CreateFurnitureCollider("BedroomCollision_Cabinet", new Vector3(3.55f, 0.8f, 3.45f), new Vector3(2.5f, 1.6f, 0.7f), root);
        }

        private static void CreateFurnitureCollider(string objectName, Vector3 position, Vector3 size, Transform root)
        {
            GameObject collision = new(objectName);
            collision.transform.SetParent(root, false);
            collision.transform.localPosition = position;
            BoxCollider boxCollider = collision.AddComponent<BoxCollider>();
            boxCollider.size = size;
        }

        private void BuildBedroomInteractions(Transform root)
        {
            bedroomInteractions.Clear();
            CreateBedroomInteraction(
                "photograph",
                "Examine the photograph",
                "The photograph catches Noor mid-laugh, before the apartment became a place full of careful silences.",
                new Vector3(-1.72f, 0.81f, 1.77f), 0, false, root);
            CreateBedroomInteraction(
                "phone",
                "Read the waiting message",
                "The message has been waiting for twenty-three minutes: “Are you really okay?”",
                new Vector3(3.4f, 0.8f, 1.65f), 1, false, root);
            CreateBedroomInteraction(
                "bed",
                "Notice the unmade bed",
                "One side is untouched. The other still holds the shape of a sleepless night.",
                new Vector3(-3.35f, 0.45f, 2.55f), 0, true, root);
            CreateBedroomInteraction(
                "window",
                "Listen to the rain",
                "Rain traces the same routes down the glass, patient enough to repeat itself.",
                new Vector3(1.3f, 0.75f, 3.75f), 0, true, root);
            CreateBedroomInteraction(
                "mug",
                "Inspect the repaired mug",
                "The rim is chipped. Someone repaired it carefully enough to keep using.",
                new Vector3(4.25f, 0.8f, 1.48f), 0, true, root);
            CreateBedroomInteraction(
                "suitcase",
                "Look at the half-packed suitcase",
                "The suitcase contains the practical things. The impossible things are still scattered around the room.",
                new Vector3(-4.1f, 0.35f, -2f), 0, true, root);
        }

        private void CreateBedroomInteraction(
            string id,
            string prompt,
            string observation,
            Vector3 position,
            int unlockStage,
            bool isOptional,
            Transform root)
        {
            GameObject anchor = new($"BedroomInteraction_{id}");
            anchor.transform.SetParent(root, false);
            anchor.transform.localPosition = position;
            EchoInteractable interactable = anchor.AddComponent<EchoInteractable>();
            interactable.Configure(id, prompt, observation, unlockStage, isOptional);
            bedroomInteractions.Add(interactable);
        }

        private static void CreateSceneInteraction(
            List<EchoInteractable> target,
            string id,
            string prompt,
            string observation,
            Vector3 position,
            int unlockStage,
            bool isOptional,
            Transform root)
        {
            GameObject anchor = new($"{root.name}_Interaction_{id}");
            anchor.transform.SetParent(root, false);
            anchor.transform.localPosition = position;
            EchoInteractable interactable = anchor.AddComponent<EchoInteractable>();
            interactable.Configure(id, prompt, observation, unlockStage, isOptional);
            target.Add(interactable);
        }

        private GameObject CreatePolyHavenModel(
            string assetId,
            string objectName,
            Vector3 position,
            Quaternion rotation,
            Vector3 scale,
            Transform root)
        {
            string resourcePath = $"Art/PolyHaven/{assetId}/{assetId}_1k";
            GameObject prefab = Resources.Load<GameObject>(resourcePath);
            if (prefab == null)
            {
                Debug.LogWarning($"[Echo] Missing CC0 art asset at Resources/{resourcePath}; keeping the slice playable.");
                return null;
            }

            GameObject instance = Instantiate(prefab, root);
            instance.name = objectName;
            instance.transform.SetLocalPositionAndRotation(position, rotation);
            instance.transform.localScale = scale;
            ImprovePolyHavenMaterials(assetId, instance);
            EchoRealWorldScale.NormalizePropAndPlace(instance, assetId, root, position);
            return instance;
        }

        private static void ImprovePolyHavenMaterials(string assetId, GameObject instance)
        {
            Texture2D[] textures = Resources.LoadAll<Texture2D>($"Art/PolyHaven/{assetId}/textures");
            Shader shader = Shader.Find("Universal Render Pipeline/Lit");
            if (shader == null || textures.Length == 0)
            {
                return;
            }

            foreach (Renderer modelRenderer in instance.GetComponentsInChildren<Renderer>(true))
            {
                Material[] sourceMaterials = modelRenderer.sharedMaterials;
                Material[] upgradedMaterials = new Material[sourceMaterials.Length];
                for (int index = 0; index < sourceMaterials.Length; index++)
                {
                    Material source = sourceMaterials[index];
                    Material upgraded = new(shader)
                    {
                        name = $"Echo_{assetId}_{source?.name ?? index.ToString()}"
                    };
                    Texture diffuse = source != null && source.mainTexture != null
                        ? source.mainTexture
                        : FindTexture(textures, source?.name, "_diff_");
                    Texture normal = FindTexture(textures, source?.name, "_nor_gl_");
                    Texture metallic = FindTexture(textures, source?.name, "_metal_");
                    Texture roughness = FindTexture(textures, source?.name, "_rough_");
                    if (diffuse != null) upgraded.SetTexture("_BaseMap", diffuse);
                    if (normal != null)
                    {
                        upgraded.SetTexture("_BumpMap", normal);
                        upgraded.EnableKeyword("_NORMALMAP");
                    }
                    if (metallic != null)
                    {
                        upgraded.SetTexture("_MetallicGlossMap", metallic);
                        upgraded.EnableKeyword("_METALLICSPECGLOSSMAP");
                    }
                    upgraded.SetFloat("_Metallic", metallic != null ? 0.35f : 0.04f);
                    upgraded.SetFloat("_Smoothness", roughness != null ? 0.32f : 0.25f);
                    upgradedMaterials[index] = upgraded;
                }
                modelRenderer.materials = upgradedMaterials;
                modelRenderer.shadowCastingMode = ShadowCastingMode.On;
                modelRenderer.receiveShadows = true;
            }
        }

        private static Texture2D FindTexture(Texture2D[] textures, string materialName, string channel)
        {
            string materialKey = string.IsNullOrWhiteSpace(materialName)
                ? string.Empty
                : materialName.Replace(" ", "_").ToLowerInvariant();
            foreach (Texture2D texture in textures)
            {
                string textureName = texture.name.ToLowerInvariant();
                if (textureName.Contains(channel, StringComparison.Ordinal) &&
                    !string.IsNullOrEmpty(materialKey) &&
                    textureName.Contains(materialKey, StringComparison.Ordinal))
                {
                    return texture;
                }
            }
            foreach (Texture2D texture in textures)
            {
                if (texture.name.Contains(channel, StringComparison.OrdinalIgnoreCase))
                {
                    return texture;
                }
            }
            return null;
        }

        private void BuildBedroomWindow(Transform root)
        {
            GameObject windowGlass = Box(
                "Bedroom_WindowGlass",
                new Vector3(1.1f, 2f, 3.63f),
                new Vector3(3.1f, 1.55f, 0.08f),
                "CoolWindow",
                root);
            Box("Bedroom_WindowTop", new Vector3(1.1f, 2.88f, 3.47f), new Vector3(3.4f, 0.18f, 0.18f), "Charcoal", root);
            Box("Bedroom_WindowBottom", new Vector3(1.1f, 1.12f, 3.47f), new Vector3(3.4f, 0.18f, 0.18f), "Charcoal", root);
            Box("Bedroom_WindowLeft", new Vector3(-0.55f, 2f, 3.47f), new Vector3(0.18f, 1.9f, 0.18f), "Charcoal", root);
            Box("Bedroom_WindowRight", new Vector3(2.75f, 2f, 3.47f), new Vector3(0.18f, 1.9f, 0.18f), "Charcoal", root);
            Box("Bedroom_WindowCenter", new Vector3(1.1f, 2f, 3.43f), new Vector3(0.1f, 1.75f, 0.14f), "Charcoal", root);

            for (int i = 0; i < 7; i++)
            {
                float x = -0.15f + i * 0.42f;
                Box(
                    $"Bedroom_Rain{i}",
                    new Vector3(x, 1.45f + (i % 3) * 0.45f, 3.33f),
                    new Vector3(0.025f, 0.48f, 0.025f),
                    "Water",
                    root,
                    Quaternion.Euler(0f, 0f, -9f));
            }

            CreateInspectable(
                windowGlass,
                "Rain has been tracing the same routes down the glass for most of the evening.");
        }

        private void BuildBedroomBed(Transform root)
        {
            Transform bed = new GameObject("Bedroom_Bed").transform;
            bed.SetParent(root);
            bed.position = new Vector3(-3.25f, 0f, 0.9f);
            Box("BedFrame", new Vector3(0f, 0.45f, 0f), new Vector3(3.5f, 0.55f, 5.3f), "Charcoal", bed);
            Box("Mattress", new Vector3(0f, 0.87f, 0f), new Vector3(3.25f, 0.48f, 5f), "White", bed);
            Box("Headboard", new Vector3(0f, 1.45f, 2.45f), new Vector3(3.55f, 2.2f, 0.22f), "Wood", bed);
            Box("PillowLeft", new Vector3(-0.72f, 1.24f, 1.65f), new Vector3(1.3f, 0.24f, 0.9f), "Cream", bed, Quaternion.Euler(4f, 12f, -5f));
            Box("PillowRight", new Vector3(0.72f, 1.22f, 1.72f), new Vector3(1.3f, 0.24f, 0.9f), "Cream", bed, Quaternion.Euler(-3f, -10f, 4f));
            GameObject blanket = Box(
                "UnmadeBlanket",
                new Vector3(0.2f, 1.25f, -0.55f),
                new Vector3(3.15f, 0.24f, 3.25f),
                "Rose",
                bed,
                Quaternion.Euler(2f, -7f, 4f));
            CreateInspectable(
                blanket,
                "The blanket is still folded around the shape of someone who left in a hurry.");
        }

        private void BuildBedroomDesk(Transform root)
        {
            Transform desk = new GameObject("Bedroom_Desk").transform;
            desk.SetParent(root);
            desk.position = new Vector3(4.1f, 0f, 1.6f);
            Box("DeskTop", new Vector3(0f, 1.25f, 0f), new Vector3(2.7f, 0.22f, 1.5f), "Wood", desk);
            for (int x = -1; x <= 1; x += 2)
            {
                for (int z = -1; z <= 1; z += 2)
                {
                    Box(
                        $"DeskLeg{x}_{z}",
                        new Vector3(x * 1.08f, 0.62f, z * 0.55f),
                        new Vector3(0.16f, 1.25f, 0.16f),
                        "Charcoal",
                        desk);
                }
            }

            Box("Notebook", new Vector3(-0.45f, 1.42f, 0f), new Vector3(0.95f, 0.08f, 0.72f), "Indigo", desk, Quaternion.Euler(0f, 12f, 0f));
            GameObject mug = Cylinder("ChippedMug", new Vector3(0.72f, 1.65f, 0.08f), new Vector3(0.28f, 0.28f, 0.28f), "Gold", desk);
            CreateInspectable(
                mug,
                "The mug is chipped at the rim. It has been repaired carefully enough to keep using.");

            Cylinder("LampStem", new Vector3(1.02f, 1.92f, -0.35f), new Vector3(0.09f, 0.55f, 0.09f), "Charcoal", desk);
            Sphere("LampShade", new Vector3(1.02f, 2.5f, -0.35f), new Vector3(0.58f, 0.38f, 0.58f), "WarmWindow", desk);
        }

        private void BuildBedroomWardrobe(Transform root)
        {
            Transform wardrobe = new GameObject("Bedroom_Wardrobe").transform;
            wardrobe.SetParent(root);
            wardrobe.position = new Vector3(-4.7f, 0f, 3.2f);
            Box("WardrobeBody", new Vector3(0f, 2.25f, 0f), new Vector3(1.65f, 4.5f, 1.9f), "Teal", wardrobe);
            Box("WardrobeDoor", new Vector3(0f, 2.25f, -0.98f), new Vector3(1.42f, 4.1f, 0.08f), "Ocean", wardrobe);
            Sphere("WardrobeHandle", new Vector3(0.48f, 2.25f, -1.08f), Vector3.one * 0.12f, "Gold", wardrobe);
        }

        private void BuildBedroomDetails(Transform root)
        {
            Box("Bedroom_Rug", new Vector3(0.7f, 0.03f, -0.45f), new Vector3(4.2f, 0.07f, 3.1f), "Indigo", root, Quaternion.Euler(0f, -8f, 0f));
            Box("Bedroom_Nightstand", new Vector3(-5f, 0.7f, -0.4f), new Vector3(1.15f, 1.4f, 1.2f), "Wood", root);
            Box("Bedroom_Photo", new Vector3(-4.98f, 1.62f, -0.4f), new Vector3(0.68f, 0.72f, 0.08f), "Gold", root, Quaternion.Euler(0f, 0f, 5f));

            Transform shelf = new GameObject("Bedroom_Bookshelf").transform;
            shelf.SetParent(root);
            shelf.position = new Vector3(4.85f, 0f, 3.65f);
            Box("ShelfBody", new Vector3(0f, 1.75f, 0f), new Vector3(1.65f, 3.5f, 0.8f), "Wood", shelf);
            for (int row = 0; row < 3; row++)
            {
                Box($"Shelf{row}", new Vector3(0f, 0.62f + row * 1.08f, -0.45f), new Vector3(1.5f, 0.1f, 0.9f), "Charcoal", shelf);
                for (int book = 0; book < 4; book++)
                {
                    Box(
                        $"Book{row}_{book}",
                        new Vector3(-0.52f + book * 0.34f, 0.87f + row * 1.08f, -0.52f),
                        new Vector3(0.24f, 0.46f + (book % 2) * 0.12f, 0.28f),
                        (row + book) % 2 == 0 ? "Rose" : "Gold",
                        shelf);
                }
            }

            Cylinder("PlantPot", new Vector3(4.65f, 0.36f, -2.65f), new Vector3(0.55f, 0.36f, 0.55f), "Terracotta", root);
            Sphere("PlantLeafA", new Vector3(4.65f, 1.15f, -2.65f), new Vector3(0.75f, 1f, 0.65f), "Leaf", root);
            Sphere("PlantLeafB", new Vector3(4.2f, 1.18f, -2.55f), new Vector3(0.5f, 0.75f, 0.45f), "LeafLight", root);
        }

        private void BuildCafeShop(Transform root)
        {
            Box("CafeInterior_Floor", new Vector3(0f, -0.28f, 0f), new Vector3(12.5f, 0.5f, 10f), "Stone", root);
            Box("CafeInterior_BackWall", new Vector3(0f, 2.8f, 4.85f), new Vector3(12.5f, 6.2f, 0.35f), "Terracotta", root);
            Box("CafeInterior_LeftWall", new Vector3(-6.08f, 2.8f, 0f), new Vector3(0.35f, 6.2f, 10f), "Teal", root);
            Box("CafeInterior_RightWall", new Vector3(6.08f, 2.8f, 0f), new Vector3(0.35f, 6.2f, 10f), "Cream", root);
            Box("CafeInterior_CeilingBeam", new Vector3(0f, 5.8f, 4.55f), new Vector3(12.8f, 0.25f, 0.45f), "Charcoal", root);

            BuildCafeCounter(root);
            BuildCafeTables(root);
            BuildCafeWindowAndDoor(root);
            BuildCafeShelves(root);

            if (!CreateMixamoPerson(
                    "Amira_Mixamo",
                    new Vector3(2.2f, 0.02f, 2.55f),
                    root,
                    Vector3.right,
                    0.85f,
                    0.28f,
                    2.2f))
            {
                CreatePerson(
                    "Amira_Barista",
                    new Vector3(2.2f, 0.02f, 2.55f),
                    "Gold",
                    "Skin1",
                    "Charcoal",
                    root,
                    Vector3.right,
                    0.85f,
                    0.28f,
                    2.2f);
            }

            CreatePerson(
                "Cafe_LastGuest",
                new Vector3(-2.65f, 0.02f, -0.2f),
                "Ocean",
                "Skin3",
                "Indigo",
                root,
                Vector3.zero,
                0f,
                0f,
                0.55f);

            BuildCafeInteractions(root);
        }

        private void BuildCafeCounter(Transform root)
        {
            Transform counter = new GameObject("CafeInterior_Counter").transform;
            counter.SetParent(root);
            counter.position = new Vector3(2.8f, 0f, 2.8f);
            Box("CounterBody", new Vector3(0f, 0.78f, 0f), new Vector3(5.5f, 1.55f, 1.4f), "Teal", counter);
            Box("CounterTop", new Vector3(0f, 1.62f, 0f), new Vector3(5.8f, 0.18f, 1.7f), "Wood", counter);
            Box("EspressoBody", new Vector3(1.25f, 2.05f, 0.1f), new Vector3(1.55f, 0.75f, 0.75f), "Charcoal", counter);
            Cylinder("EspressoDialA", new Vector3(0.92f, 2.15f, -0.43f), new Vector3(0.12f, 0.08f, 0.12f), "Gold", counter, Quaternion.Euler(90f, 0f, 0f));
            Cylinder("EspressoDialB", new Vector3(1.45f, 2.15f, -0.43f), new Vector3(0.12f, 0.08f, 0.12f), "Gold", counter, Quaternion.Euler(90f, 0f, 0f));
            GameObject pastryCase = Box(
                "PastryCase",
                new Vector3(-1.45f, 2.02f, 0f),
                new Vector3(1.75f, 0.72f, 0.85f),
                "CoolWindow",
                counter);
            for (int i = 0; i < 3; i++)
            {
                Sphere($"Pastry{i}", new Vector3(-1.95f + i * 0.5f, 1.93f, -0.48f), Vector3.one * 0.2f, i == 1 ? "Rose" : "Gold", counter);
            }
            CreateInspectable(
                pastryCase,
                "Only three pastries remain. One has been turned so its imperfect side faces the wall.");

            GameObject tipJar = Cylinder("TipJar", new Vector3(-0.15f, 1.98f, -0.18f), new Vector3(0.3f, 0.34f, 0.3f), "CoolWindow", counter);
            CreateInspectable(
                tipJar,
                "The tip jar holds two coins and a folded paper star.");
        }

        private void BuildCafeTables(Transform root)
        {
            for (int i = 0; i < 2; i++)
            {
                float z = -1.4f + i * 2.65f;
                CreatePolyHavenModel(
                    "round_wooden_table_01", $"CafeArt_Table_{i}",
                    new Vector3(-2.7f, 0f, z), Quaternion.identity,
                    Vector3.one * 0.92f, root);
                CreatePolyHavenModel(
                    "dining_chair_02", $"CafeArt_ChairA_{i}",
                    new Vector3(-4.05f, 0f, z), Quaternion.Euler(-90f, 90f, 0f),
                    Vector3.one, root);
                CreatePolyHavenModel(
                    "dining_chair_02", $"CafeArt_ChairB_{i}",
                    new Vector3(-1.35f, 0f, z), Quaternion.Euler(-90f, -90f, 0f),
                    Vector3.one, root);
                CreateFurnitureCollider(
                    $"CafeCollision_Table_{i}",
                    new Vector3(-2.7f, 0.55f, z),
                    new Vector3(1.35f, 1.1f, 1.35f),
                    root);
            }

            CreatePolyHavenModel(
                "hanging_industrial_lamp", "CafeArt_HangingLamp_A",
                new Vector3(-2.7f, 3.65f, -1.4f), Quaternion.Euler(-90f, 0f, 0f),
                Vector3.one * 0.82f, root);
            CreatePolyHavenModel(
                "hanging_industrial_lamp", "CafeArt_HangingLamp_B",
                new Vector3(-2.7f, 3.65f, 1.25f), Quaternion.Euler(-90f, 0f, 0f),
                Vector3.one * 0.82f, root);

            GameObject sketchbook = Box(
                "ForgottenSketchbook",
                new Vector3(-2.7f, 1.23f, -1.35f),
                new Vector3(0.88f, 0.08f, 0.68f),
                "Rose",
                root,
                Quaternion.Euler(0f, -14f, 0f));
            CreateInspectable(
                sketchbook,
                "A name is written inside the cover. The last page is a careful drawing of this room.");
        }

        private void BuildCafeInteractions(Transform root)
        {
            cafeInteractions.Clear();
            CreateSceneInteraction(
                cafeInteractions,
                "sketchbook",
                "Open the forgotten sketchbook",
                "A name is written inside. The final page is a patient drawing of this café, including Amira behind the counter.",
                new Vector3(-2.7f, 0.85f, -1.35f), 0, false, root);
            CreateSceneInteraction(
                cafeInteractions,
                "door",
                "Look through the closing door",
                "The owner is still visible beyond the glass, walking quickly into the rain without looking back.",
                new Vector3(-4.55f, 0.85f, 3.9f), 1, false, root);
            CreateSceneInteraction(
                cafeInteractions,
                "tip_jar",
                "Inspect the tip jar",
                "Two coins sit beside a folded paper star with a tiny thank-you written inside.",
                new Vector3(2.65f, 0.85f, 2.0f), 0, true, root);
            CreateSceneInteraction(
                cafeInteractions,
                "pastries",
                "Look at the remaining pastries",
                "Only three remain. One has been turned so its imperfect side faces the wall.",
                new Vector3(1.35f, 0.85f, 2.0f), 0, true, root);
            CreateSceneInteraction(
                cafeInteractions,
                "last_table",
                "Notice the last table",
                "A ring of warmth remains where the owner's cup stood.",
                new Vector3(-2.7f, 0.75f, 1.25f), 0, true, root);
            CreateSceneInteraction(
                cafeInteractions,
                "rain_window",
                "Watch the rain outside",
                "Streetlight turns every drop on the glass briefly gold.",
                new Vector3(-2.1f, 0.85f, 4.15f), 0, true, root);
        }

        private void BuildCafeWindowAndDoor(Transform root)
        {
            Box("CafeInterior_FrontWindow", new Vector3(-2.1f, 2.85f, 4.62f), new Vector3(4.1f, 3.4f, 0.08f), "CoolWindow", root);
            Box("CafeInterior_WindowFrame", new Vector3(-2.1f, 2.85f, 4.49f), new Vector3(0.12f, 3.55f, 0.16f), "Gold", root);
            Box("CafeInterior_Door", new Vector3(-5f, 1.62f, 4.58f), new Vector3(1.5f, 3.25f, 0.18f), "Ocean", root);
            Sphere("CafeInterior_DoorHandle", new Vector3(-4.55f, 1.65f, 4.35f), Vector3.one * 0.12f, "Gold", root);
            Box("CafeInterior_Sign", new Vector3(-2.1f, 4.7f, 4.32f), new Vector3(3.6f, 0.65f, 0.14f), "Gold", root);
        }

        private void BuildCafeShelves(Transform root)
        {
            for (int row = 0; row < 3; row++)
            {
                Box($"CafeInterior_Shelf{row}", new Vector3(3.25f, 2.1f + row * 0.8f, 4.3f), new Vector3(4.7f, 0.14f, 0.55f), "Wood", root);
                for (int cup = 0; cup < 6; cup++)
                {
                    Cylinder(
                        $"CafeInterior_Cup{row}_{cup}",
                        new Vector3(1.4f + cup * 0.72f, 2.35f + row * 0.8f, 4.05f),
                        new Vector3(0.2f, 0.24f, 0.2f),
                        (row + cup) % 2 == 0 ? "Cream" : "Gold",
                        root);
                }
            }

            for (int i = 0; i < 3; i++)
            {
                GameObject pendant = new($"CafeInterior_Pendant{i}");
                pendant.transform.SetParent(root);
                pendant.transform.localPosition = new Vector3(-2.7f + i * 2.7f, 5.2f, -0.1f);
                Cylinder("Cord", new Vector3(0f, 0f, 0f), new Vector3(0.04f, 0.6f, 0.04f), "Charcoal", pendant.transform);
                Sphere("Shade", new Vector3(0f, -0.72f, 0f), new Vector3(0.58f, 0.32f, 0.58f), "WarmWindow", pendant.transform);
            }
        }

        private void BuildCafe(Vector3 position, Transform root)
        {
            Transform cafe = new GameObject("Cafe_Saffron").transform;
            cafe.SetParent(root);
            cafe.position = position;
            Box("CafeBody", new Vector3(0f, 2.35f, 1.8f), new Vector3(3.25f, 4.7f, 6.2f), "Terracotta", cafe);
            Box("CafeTrim", new Vector3(0f, 4.75f, 1.8f), new Vector3(3.5f, 0.24f, 6.45f), "Gold", cafe);
            Box("CafeWindow", new Vector3(-1.64f, 2f, 0.6f), new Vector3(0.08f, 2.35f, 2.6f), "WarmWindow", cafe);
            Box("CafeDoor", new Vector3(-1.65f, 1.4f, 3.15f), new Vector3(0.1f, 2.8f, 1.1f), "Teal", cafe);
            Box("Awning", new Vector3(-2.12f, 3.2f, 0.6f), new Vector3(1.1f, 0.18f, 3.15f), "Cream", cafe, Quaternion.Euler(0f, 0f, -11f));
            Box("CafeSign", new Vector3(-1.86f, 4.1f, 0.6f), new Vector3(0.18f, 0.7f, 2.1f), "Teal", cafe);

            for (int i = 0; i < 2; i++)
            {
                Vector3 table = new(-2.3f, 0.3f, -0.45f + i * 2.1f);
                Cylinder($"CafeTable{i}", table + Vector3.up * 0.62f, new Vector3(0.75f, 0.08f, 0.75f), "Wood", cafe);
                Cylinder($"CafeTableLeg{i}", table + Vector3.up * 0.32f, new Vector3(0.12f, 0.32f, 0.12f), "Charcoal", cafe);
                Box($"CafeChair{i}", table + new Vector3(-0.75f, 0.42f, 0f), new Vector3(0.5f, 0.8f, 0.55f), "Ocean", cafe);
            }

            GameObject lightObject = new("CafeGlow");
            lightObject.transform.SetParent(cafe);
            lightObject.transform.localPosition = new Vector3(-2.2f, 2.1f, 0.6f);
            warmWindowLight = lightObject.AddComponent<Light>();
            warmWindowLight.type = LightType.Point;
            warmWindowLight.color = new Color(1f, 0.45f, 0.18f);
            warmWindowLight.range = 7f;
            warmWindowLight.intensity = 5.2f;
            warmWindowLight.shadows = LightShadows.None;
        }

        private void BuildBookshop(Vector3 position, Transform root)
        {
            Transform shop = new GameObject("Bookshop_SecondChapter").transform;
            shop.SetParent(root);
            shop.position = position;
            Box("ShopBody", new Vector3(0f, 2.7f, 1.4f), new Vector3(3.3f, 5.4f, 6.8f), "Cream", shop);
            Box("ShopRoof", new Vector3(0f, 5.55f, 1.4f), new Vector3(3.65f, 0.3f, 7.15f), "Indigo", shop);
            Box("ShopWindow", new Vector3(1.68f, 2f, 0.25f), new Vector3(0.08f, 2.6f, 3.1f), "CoolWindow", shop);
            Box("ShopDoor", new Vector3(1.7f, 1.4f, 3.1f), new Vector3(0.1f, 2.8f, 1.05f), "Wood", shop);
            Box("ShopSign", new Vector3(1.85f, 4f, 0.15f), new Vector3(0.22f, 0.85f, 3.4f), "Indigo", shop);

            for (int i = 0; i < 5; i++)
            {
                Box($"BookDisplay{i}", new Vector3(1.82f, 1.1f + (i % 2) * 0.7f, -0.85f + i * 0.42f),
                    new Vector3(0.13f, 0.55f, 0.28f), i % 2 == 0 ? "Rose" : "Gold", shop);
            }
        }

        private void BuildApartments(Transform root)
        {
            string[] colors = { "Ocean", "Stone", "Terracotta", "Cream" };
            for (int side = -1; side <= 1; side += 2)
            {
                for (int i = 0; i < 3; i++)
                {
                    float x = side * 6.25f;
                    float z = 6.2f + i * 5f;
                    float height = 4.8f + i * 0.65f;
                    Transform building = new GameObject($"Apartment_{side}_{i}").transform;
                    building.SetParent(root);
                    Box("Body", new Vector3(x, height * 0.5f, z), new Vector3(3.4f, height, 4.5f), colors[(i + (side > 0 ? 1 : 0)) % colors.Length], building);
                    for (int floor = 0; floor < 2; floor++)
                    {
                        Box($"Window{floor}", new Vector3(x - side * 1.72f, 1.65f + floor * 1.8f, z - 0.75f),
                            new Vector3(0.08f, 0.9f, 1.05f), (i + floor) % 2 == 0 ? "WarmWindow" : "CoolWindow", building);
                        Box($"WindowB{floor}", new Vector3(x - side * 1.72f, 1.65f + floor * 1.8f, z + 0.95f),
                            new Vector3(0.08f, 0.9f, 1.05f), "CoolWindow", building);
                    }
                }
            }
        }

        private void BuildBusStop(Vector3 position, Transform root)
        {
            Transform stop = new GameObject("Public_BusStop").transform;
            stop.SetParent(root);
            stop.position = position;
            Box("BackGlass", new Vector3(0f, 1.25f, 0f), new Vector3(0.12f, 2.5f, 3.3f), "CoolWindow", stop);
            Box("Roof", new Vector3(0.15f, 2.55f, 0f), new Vector3(1.25f, 0.16f, 3.6f), "Gold", stop);
            Box("Bench", new Vector3(0.42f, 0.62f, 0f), new Vector3(0.65f, 0.16f, 2.25f), "Wood", stop);
            Box("BenchBack", new Vector3(0.58f, 1f, 0f), new Vector3(0.12f, 0.75f, 2.25f), "Wood", stop);
            Cylinder("StopPole", new Vector3(-0.15f, 1.55f, -2.2f), new Vector3(0.12f, 1.55f, 0.12f), "Charcoal", stop);
            Box("StopSign", new Vector3(-0.15f, 2.75f, -2.2f), new Vector3(0.12f, 0.65f, 0.8f), "Ocean", stop);
        }

        private void BuildPlaza(Vector3 position, Transform root)
        {
            Box("PlazaStone", position, new Vector3(8.2f, 0.22f, 4.8f), "Stone", root);
            Cylinder("FountainBase", position + new Vector3(0f, 0.34f, 0f), new Vector3(2.25f, 0.28f, 2.25f), "Cream", root);
            Cylinder("FountainWater", position + new Vector3(0f, 0.64f, 0f), new Vector3(1.82f, 0.08f, 1.82f), "Water", root);
            Cylinder("FountainColumn", position + new Vector3(0f, 1.15f, 0f), new Vector3(0.42f, 0.62f, 0.42f), "Cream", root);
            Sphere("FountainCrown", position + new Vector3(0f, 1.85f, 0f), new Vector3(0.55f, 0.55f, 0.55f), "Water", root);

            for (int i = 0; i < 4; i++)
            {
                float angle = i * Mathf.PI * 0.5f + 0.5f;
                Vector3 offset = new(Mathf.Cos(angle) * 3f, 0f, Mathf.Sin(angle) * 1.7f);
                BuildTree(position + offset, 0.8f + i * 0.05f, root);
            }
        }

        private void BuildStreetFurniture(Transform root)
        {
            for (int i = 0; i < 6; i++)
            {
                float z = -6f + i * 3.9f;
                BuildLamp(new Vector3(-3.55f, 0.35f, z), root);
                if (i % 2 == 0) BuildLamp(new Vector3(3.55f, 0.35f, z + 1.7f), root);
            }

            BuildTree(new Vector3(4.45f, 0.35f, 4.6f), 0.9f, root);
            BuildTree(new Vector3(-4.65f, 0.35f, 8.7f), 1f, root);
            BuildTree(new Vector3(4.55f, 0.35f, 10.4f), 0.82f, root);

            Box("PublicBenchSeat", new Vector3(4.6f, 0.75f, 7.1f), new Vector3(0.7f, 0.16f, 2.3f), "Wood", root);
            Box("PublicBenchBack", new Vector3(5f, 1.15f, 7.1f), new Vector3(0.14f, 0.75f, 2.3f), "Wood", root);

            for (int i = 0; i < 3; i++)
            {
                Cylinder($"Bollard{i}", new Vector3(2.95f, 0.52f, 6.5f + i * 0.75f), new Vector3(0.13f, 0.52f, 0.13f), "Gold", root);
            }
        }

        private void BuildLamp(Vector3 position, Transform root)
        {
            Cylinder("LampPost", position + Vector3.up * 1.55f, new Vector3(0.09f, 1.55f, 0.09f), "Charcoal", root);
            Sphere("LampGlow", position + Vector3.up * 3.1f, new Vector3(0.33f, 0.33f, 0.33f), "WarmWindow", root);
            Box("LampCap", position + Vector3.up * 3.4f, new Vector3(0.55f, 0.12f, 0.55f), "Charcoal", root);
        }

        private void BuildTree(Vector3 position, float scale, Transform root)
        {
            Transform tree = new GameObject("StreetTree").transform;
            tree.SetParent(root);
            tree.position = position;
            Cylinder("Trunk", new Vector3(0f, 1.05f * scale, 0f), new Vector3(0.18f * scale, 1.05f * scale, 0.18f * scale), "Wood", tree);
            Sphere("CrownA", new Vector3(0f, 2.55f * scale, 0f), Vector3.one * 1.2f * scale, "Leaf", tree);
            Sphere("CrownB", new Vector3(0.65f * scale, 2.45f * scale, 0.1f), Vector3.one * 0.8f * scale, "LeafLight", tree);
            Sphere("CrownC", new Vector3(-0.55f * scale, 2.35f * scale, -0.15f), Vector3.one * 0.72f * scale, "Leaf", tree);
        }

        private void BuildPeople(Transform root)
        {
            if (!CreateMixamoPerson(
                    "Mina_Mixamo",
                    new Vector3(1.2f, 0.22f, -3.8f),
                    root,
                    Vector3.forward,
                    2.2f,
                    0.55f,
                    0f))
            {
                CreatePerson("Mina_Walking", new Vector3(1.2f, 0.22f, -3.8f), "Rose", "Skin2", "Charcoal", root, Vector3.forward, 2.2f, 0.55f, 0f);
            }
            CreatePerson("Jonas_Walking", new Vector3(-1.15f, 0.22f, 4.4f), "Ocean", "Skin1", "Gold", root, Vector3.forward, 2.7f, 0.43f, 2f);
            CreatePerson("Visitor_AtCrossing", new Vector3(2.5f, 0.22f, 7.4f), "Indigo", "Skin3", "Charcoal", root, Vector3.left, 2.1f, 0.38f, 1f);
            CreatePerson("CafeGuest", new Vector3(4.15f, 0.22f, -1.3f), "Cream", "Skin1", "Rose", root, Vector3.zero, 0f, 0f, 0f);
            CreatePerson("BusPassenger", new Vector3(-4.1f, 0.22f, -4.9f), "Gold", "Skin3", "Indigo", root, Vector3.zero, 0f, 0f, 0f);
            CreatePerson("PlazaFriend", new Vector3(-1.8f, 0.22f, 13.8f), "Teal", "Skin2", "Gold", root, Vector3.zero, 0f, 0f, 0f);
        }

        private bool CreateMixamoPerson(
            string personName,
            Vector3 position,
            Transform root,
            Vector3 walkAxis,
            float walkDistance,
            float walkSpeed,
            float walkPhase)
        {
            const string resourcePath = "Characters/YBot/Walking";
            GameObject modelPrefab = Resources.Load<GameObject>(resourcePath);
            AnimationClip[] animationClips = Resources.LoadAll<AnimationClip>(resourcePath);
            AnimationClip walkClip = null;
            foreach (AnimationClip candidate in animationClips)
            {
                if (!candidate.name.StartsWith("__preview__", System.StringComparison.OrdinalIgnoreCase))
                {
                    walkClip = candidate;
                    break;
                }
            }

            if (modelPrefab == null || walkClip == null)
            {
                Debug.LogWarning("[Echo] Mixamo Y Bot was not ready; using the stylized fallback pedestrian.");
                return false;
            }

            Transform person = new GameObject(personName).transform;
            person.SetParent(root);
            person.position = position;

            GameObject visual = Instantiate(modelPrefab, person);
            visual.name = "YBot_Visual";
            visual.transform.SetLocalPositionAndRotation(Vector3.zero, Quaternion.Euler(0f, 180f, 0f));
            visual.transform.localScale = Vector3.one * 1.05f;
            TintMixamoVisual(visual);

            Animator animator = visual.GetComponentInChildren<Animator>();
            if (animator == null)
            {
                animator = visual.AddComponent<Animator>();
            }

            EchoMixamoCharacter playback = person.gameObject.AddComponent<EchoMixamoCharacter>();
            if (!playback.Configure(animator, walkClip, walkPhase * 0.17f))
            {
                Destroy(person.gameObject);
                return false;
            }

            EchoNpcWalker walker = person.gameObject.AddComponent<EchoNpcWalker>();
            walker.Configure(walkAxis, walkDistance, walkSpeed, walkPhase, null, null, null, null);
            Debug.Log($"[Echo] Loaded Mixamo pedestrian '{modelPrefab.name}' with clip '{walkClip.name}'.");
            return true;
        }

        private static void TintMixamoVisual(GameObject visual)
        {
            Color pedestrianColor = new(0.92f, 0.31f, 0.2f);
            foreach (Renderer visualRenderer in visual.GetComponentsInChildren<Renderer>())
            {
                Material[] visualMaterials = visualRenderer.materials;
                foreach (Material visualMaterial in visualMaterials)
                {
                    if (visualMaterial.HasProperty("_BaseColor"))
                    {
                        visualMaterial.SetColor("_BaseColor", pedestrianColor);
                    }
                    if (visualMaterial.HasProperty("_Color"))
                    {
                        visualMaterial.SetColor("_Color", pedestrianColor);
                    }
                    if (visualMaterial.HasProperty("_Smoothness"))
                    {
                        visualMaterial.SetFloat("_Smoothness", 0.28f);
                    }
                }
                visualRenderer.materials = visualMaterials;
            }
        }

        private void CreatePerson(
            string personName,
            Vector3 position,
            string clothing,
            string skin,
            string hair,
            Transform root,
            Vector3 walkAxis,
            float walkDistance,
            float walkSpeed,
            float walkPhase)
        {
            Transform person = new GameObject(personName).transform;
            person.SetParent(root);
            person.position = position;

            Capsule("Torso", new Vector3(0f, 1.35f, 0f), new Vector3(0.54f, 0.62f, 0.38f), clothing, person);
            Sphere("Head", new Vector3(0f, 2.22f, 0f), new Vector3(0.48f, 0.52f, 0.46f), skin, person);
            Sphere("Hair", new Vector3(0f, 2.48f, -0.02f), new Vector3(0.5f, 0.26f, 0.48f), hair, person);

            Transform leftArm = Capsule("ArmLeft", new Vector3(-0.43f, 1.38f, 0f), new Vector3(0.14f, 0.48f, 0.14f), skin, person).transform;
            Transform rightArm = Capsule("ArmRight", new Vector3(0.43f, 1.38f, 0f), new Vector3(0.14f, 0.48f, 0.14f), skin, person).transform;
            Transform leftLeg = Capsule("LegLeft", new Vector3(-0.18f, 0.54f, 0f), new Vector3(0.17f, 0.48f, 0.18f), "Charcoal", person).transform;
            Transform rightLeg = Capsule("LegRight", new Vector3(0.18f, 0.54f, 0f), new Vector3(0.17f, 0.48f, 0.18f), "Charcoal", person).transform;

            if (walkAxis.sqrMagnitude > 0.01f)
            {
                EchoNpcWalker walker = person.gameObject.AddComponent<EchoNpcWalker>();
                walker.Configure(walkAxis, walkDistance, walkSpeed, walkPhase, leftArm, rightArm, leftLeg, rightLeg);
            }
            else
            {
                person.rotation = Quaternion.Euler(0f, walkPhase * 55f, 0f);
            }
        }

        private void CreateStreetLighting(Transform root)
        {
            GameObject sunObject = new("Street_Sun");
            sunObject.transform.SetParent(root);
            sunObject.transform.rotation = Quaternion.Euler(38f, -32f, 0f);
            streetSun = sunObject.AddComponent<Light>();
            streetSun.type = LightType.Directional;
            streetSun.color = new Color(0.78f, 0.84f, 1f);
            streetSun.intensity = 1.35f;
            streetSun.shadows = LightShadows.Soft;
            streetSun.shadowStrength = 0.78f;

            GameObject rimObject = new("Street_Rim");
            rimObject.transform.SetParent(root);
            rimObject.transform.position = new Vector3(-4f, 6f, 10f);
            Light rim = rimObject.AddComponent<Light>();
            rim.type = LightType.Point;
            rim.color = new Color(0.15f, 0.4f, 1f);
            rim.range = 19f;
            rim.intensity = 5.5f;
        }

        private void CreateBedroomLighting(Transform root)
        {
            GameObject sunObject = new("Bedroom_Moon");
            sunObject.transform.SetParent(root);
            sunObject.transform.rotation = Quaternion.Euler(42f, 24f, 0f);
            bedroomSun = sunObject.AddComponent<Light>();
            bedroomSun.type = LightType.Directional;
            bedroomSun.color = new Color(0.34f, 0.48f, 0.78f);
            bedroomSun.intensity = 0.62f;
            bedroomSun.shadows = LightShadows.Soft;
            bedroomSun.shadowStrength = 0.68f;

            GameObject lampObject = new("Bedroom_LampGlow");
            lampObject.transform.SetParent(root);
            lampObject.transform.localPosition = new Vector3(5.05f, 2.55f, 1.25f);
            bedroomLampLight = lampObject.AddComponent<Light>();
            bedroomLampLight.type = LightType.Point;
            bedroomLampLight.color = new Color(1f, 0.48f, 0.2f);
            bedroomLampLight.range = 8.5f;
            bedroomLampLight.intensity = 6.8f;
            bedroomLampLight.shadows = LightShadows.None;

            GameObject windowObject = new("Bedroom_WindowGlow");
            windowObject.transform.SetParent(root);
            windowObject.transform.localPosition = new Vector3(1.3f, 3.1f, 3.75f);
            Light windowGlow = windowObject.AddComponent<Light>();
            windowGlow.type = LightType.Point;
            windowGlow.color = new Color(0.16f, 0.36f, 0.78f);
            windowGlow.range = 8f;
            windowGlow.intensity = 3.2f;
            windowGlow.shadows = LightShadows.None;

            GameObject fillObject = new("Bedroom_SoftFill");
            fillObject.transform.SetParent(root);
            fillObject.transform.localPosition = new Vector3(-0.8f, 4.1f, -1.2f);
            Light fill = fillObject.AddComponent<Light>();
            fill.type = LightType.Point;
            fill.color = new Color(1f, 0.77f, 0.61f);
            fill.range = 11f;
            fill.intensity = 3.6f;
            fill.shadows = LightShadows.None;

            root.gameObject.AddComponent<EchoBedroomAmbience>();
        }

        public void ApplyBedroomChoiceMood(bool honest)
        {
            choicePulse = honest ? 2.1f : 0.7f;
            if (bedroomSun != null)
            {
                bedroomSun.color = honest
                    ? new Color(0.56f, 0.55f, 0.76f)
                    : new Color(0.25f, 0.36f, 0.64f);
            }
            if (bedroomLampLight != null)
            {
                bedroomLampLight.color = honest
                    ? new Color(1f, 0.58f, 0.28f)
                    : new Color(0.9f, 0.39f, 0.18f);
            }
        }

        public void ResetBedroomChoiceMood()
        {
            if (bedroomSun != null) bedroomSun.color = new Color(0.34f, 0.48f, 0.78f);
            if (bedroomLampLight != null) bedroomLampLight.color = new Color(1f, 0.48f, 0.2f);
            choicePulse = 0f;
        }

        private void CreateCafeLighting(Transform root)
        {
            GameObject sunObject = new("CafeInterior_Sun");
            sunObject.transform.SetParent(root);
            sunObject.transform.rotation = Quaternion.Euler(48f, -28f, 0f);
            cafeSun = sunObject.AddComponent<Light>();
            cafeSun.type = LightType.Directional;
            cafeSun.color = new Color(0.95f, 0.72f, 0.48f);
            cafeSun.intensity = 1.05f;
            cafeSun.shadows = LightShadows.Soft;
            cafeSun.shadowStrength = 0.68f;

            GameObject pendantObject = new("CafeInterior_PendantGlow");
            pendantObject.transform.SetParent(root);
            pendantObject.transform.localPosition = new Vector3(-0.2f, 4.2f, -0.1f);
            cafePendantLight = pendantObject.AddComponent<Light>();
            cafePendantLight.type = LightType.Point;
            cafePendantLight.color = new Color(1f, 0.47f, 0.18f);
            cafePendantLight.range = 12f;
            cafePendantLight.intensity = 5.4f;
            cafePendantLight.shadows = LightShadows.None;

            GameObject counterObject = new("CafeInterior_CounterGlow");
            counterObject.transform.SetParent(root);
            counterObject.transform.localPosition = new Vector3(3.3f, 3.2f, 2.1f);
            Light counterGlow = counterObject.AddComponent<Light>();
            counterGlow.type = LightType.Point;
            counterGlow.color = new Color(0.25f, 0.62f, 0.72f);
            counterGlow.range = 8f;
            counterGlow.intensity = 3.1f;
            counterGlow.shadows = LightShadows.None;
        }

        private void CreateCamera()
        {
            GameObject cameraObject = new("Echo_MainCamera");
            cameraObject.transform.SetParent(transform);
            cameraObject.tag = "MainCamera";
            mainCamera = cameraObject.AddComponent<Camera>();
            mainCamera.clearFlags = CameraClearFlags.SolidColor;
            mainCamera.backgroundColor = new Color(0.035f, 0.045f, 0.075f);
            mainCamera.fieldOfView = 52f;
            mainCamera.nearClipPlane = 0.1f;
            mainCamera.farClipPlane = 100f;
            mainCamera.allowHDR = true;
            mainCamera.depth = 100f;
            cameraObject.AddComponent<AudioListener>();
            orbitCamera = cameraObject.AddComponent<EchoOrbitCamera>();
            orbitCamera.Configure(new Vector3(0f, 1.9f, 0.3f), 0f, 16f, 11.8f);
            thirdPersonCamera = cameraObject.AddComponent<EchoThirdPersonCamera>();
            thirdPersonCamera.enabled = false;
            Debug.Log($"[Echo] Free 3D prototype ready with 3 scenes. Camera at {cameraObject.transform.position}; scene roots: {transform.childCount}.");
        }

        private void CreateBedroomGameplay()
        {
            bedroomController = CreatePlayableCharacter(
                "Noor_Player",
                bedroomRoot,
                new Vector3(-0.2f, 0.02f, -2.1f),
                new Bounds(new Vector3(0f, 0f, 0f), new Vector3(8.8f, 2f, 6.8f)),
                out bedroomPlayer);
            bedroomVignette = gameObject.AddComponent<EchoBedroomVignette>();
            bedroomVignette.Configure(this, bedroomPlayer, bedroomController, bedroomInteractions);
        }

        private void CreateStreetGameplay()
        {
            streetController = CreatePlayableCharacter(
                "Street_Player",
                streetRoot,
                new Vector3(-0.4f, 0.38f, -5.2f),
                new Bounds(new Vector3(0f, 0.38f, 4.5f), new Vector3(9.8f, 2f, 21.5f)),
                out streetPlayer);
            streetVignette = gameObject.AddComponent<EchoPlayableVignette>();
            streetVignette.Configure(
                this,
                new EchoPlayableVignetteDefinition
                {
                    SceneId = "harbor-street",
                    Title = "THE CROSSING",
                    FirstInteractionId = "route_map",
                    FirstObjective = "Check the changed route at the bus stop.",
                    SecondInteractionId = "visitor",
                    SecondObjective = "Ask the waiting visitor where they need to go.",
                    ChoiceObjective = "Decide whether to step into their evening.",
                    ChoiceTitle = "THE LAST BUS",
                    ChoiceQuestion = "The correct stop is across the street. Helping means walking them there now; your own bus is already approaching.",
                    HonestChoice = "Walk over with them",
                    GuardedChoice = "Point, then keep moving",
                    HonestResolutionTitle = "YOU CROSS TOGETHER",
                    GuardedResolutionTitle = "THEY NOD AND HURRY",
                    HonestResolution = "You match their pace across the road. When the right bus turns the corner, their shoulders finally loosen.",
                    GuardedResolution = "You point out the shelter and repeat the route number. They thank you, then hurry toward the crossing alone.",
                    NextSceneId = "cafe-shop",
                    NextSceneLabel = "Enter Saffron Café"
                },
                streetPlayer,
                streetController,
                streetInteractions);
        }

        private void CreateCafeGameplay()
        {
            cafeController = CreatePlayableCharacter(
                "Cafe_Player",
                cafeRoot,
                new Vector3(-0.4f, 0.02f, -3.25f),
                new Bounds(new Vector3(0f, 0f, 0f), new Vector3(10.8f, 2f, 8.2f)),
                out cafePlayer);
            cafeVignette = gameObject.AddComponent<EchoPlayableVignette>();
            cafeVignette.Configure(
                this,
                new EchoPlayableVignetteDefinition
                {
                    SceneId = "cafe-shop",
                    Title = "THE LAST TABLE",
                    FirstInteractionId = "sketchbook",
                    FirstObjective = "Inspect the sketchbook left on the last table.",
                    SecondInteractionId = "door",
                    SecondObjective = "See whether its owner is still outside.",
                    ChoiceObjective = "Decide what Amira does before the door closes.",
                    ChoiceTitle = "THE FORGOTTEN SKETCHBOOK",
                    ChoiceQuestion = "The name inside belongs to the guest disappearing into the rain. The café is meant to be locked now.",
                    HonestChoice = "Call after them",
                    GuardedChoice = "Keep it safe until tomorrow",
                    HonestResolutionTitle = "THE DOOR CATCHES",
                    GuardedResolutionTitle = "SAFE BEHIND THE COUNTER",
                    HonestResolution = "Amira catches the door. Relief arrives on the owner's face before the thank-you does.",
                    GuardedResolution = "Amira wraps the sketchbook in clean paper and places it behind the counter. Tomorrow is still a promise.",
                    NextSceneId = "bedroom",
                    NextSceneLabel = "Return to Bedroom"
                },
                cafePlayer,
                cafeController,
                cafeInteractions);
        }

        private EchoThirdPersonController CreatePlayableCharacter(
            string objectName,
            Transform sceneRoot,
            Vector3 startPosition,
            Bounds movementBounds,
            out Transform playerTransform)
        {
            GameObject playerObject = new(objectName);
            playerTransform = playerObject.transform;
            playerTransform.SetParent(sceneRoot, false);
            playerTransform.localPosition = startPosition;
            playerTransform.localRotation = Quaternion.Euler(0f, 18f, 0f);

            CharacterController collision = playerObject.AddComponent<CharacterController>();
            collision.height = 1.82f;
            collision.radius = 0.28f;
            collision.center = new Vector3(0f, 0.91f, 0f);
            collision.skinWidth = 0.04f;

            EchoMixamoCharacter animationPlayback = CreateBedroomPlayerVisual(playerTransform);
            EchoThirdPersonController controller =
                playerObject.AddComponent<EchoThirdPersonController>();
            controller.Configure(mainCamera, movementBounds, animationPlayback, 3.2f);
            return controller;
        }

        private EchoMixamoCharacter CreateBedroomPlayerVisual(Transform playerRoot)
        {
            string[] candidatePaths =
            {
                "Characters/Noor/Walking",
                "Characters/YBot/Walking"
            };

            foreach (string resourcePath in candidatePaths)
            {
                GameObject modelPrefab = Resources.Load<GameObject>(resourcePath);
                AnimationClip[] clips = Resources.LoadAll<AnimationClip>(resourcePath);
                AnimationClip walkClip = null;
                foreach (AnimationClip clip in clips)
                {
                    if (!clip.name.StartsWith("__preview__", StringComparison.OrdinalIgnoreCase))
                    {
                        walkClip = clip;
                        break;
                    }
                }
                if (modelPrefab == null || walkClip == null)
                {
                    continue;
                }

                GameObject visual = Instantiate(modelPrefab, playerRoot);
                visual.name = resourcePath.StartsWith("Characters/Noor", StringComparison.Ordinal)
                    ? "Noor_RemyVisual"
                    : "Noor_YBotVisual";
                // Mixamo's imported forward axis already matches the playable
                // root. The previous 180° correction made Noor face opposite
                // the travel direction and appear to moonwalk toward the camera.
                visual.transform.SetLocalPositionAndRotation(Vector3.zero, Quaternion.identity);
                visual.transform.localScale = Vector3.one;
                StyleBedroomPlayerVisual(visual, resourcePath);
                EchoRealWorldScale.NormalizeCharacter(visual, playerRoot);
                Animator animator = visual.GetComponentInChildren<Animator>();
                if (animator == null)
                {
                    animator = visual.AddComponent<Animator>();
                }

                EchoMixamoCharacter playback = playerRoot.gameObject.AddComponent<EchoMixamoCharacter>();
                if (playback.Configure(animator, walkClip, 0f))
                {
                    playback.SetPlaybackSpeed(0f);
                    Debug.Log($"[Echo] Playable Noor loaded from {resourcePath}.");
                    return playback;
                }
                Destroy(playback);
                Destroy(visual);
            }

            Debug.LogWarning("[Echo] Noor FBX was unavailable; using the deterministic fallback player.");
            Capsule("FallbackTorso", new Vector3(0f, 1.08f, 0f), new Vector3(0.45f, 0.55f, 0.32f), "Indigo", playerRoot);
            Sphere("FallbackHead", new Vector3(0f, 1.78f, 0f), new Vector3(0.42f, 0.46f, 0.4f), "Skin2", playerRoot);
            Sphere("FallbackHair", new Vector3(0f, 1.98f, 0f), new Vector3(0.44f, 0.24f, 0.42f), "Charcoal", playerRoot);
            Capsule("FallbackLegLeft", new Vector3(-0.16f, 0.42f, 0f), new Vector3(0.14f, 0.42f, 0.15f), "Charcoal", playerRoot);
            Capsule("FallbackLegRight", new Vector3(0.16f, 0.42f, 0f), new Vector3(0.14f, 0.42f, 0.15f), "Charcoal", playerRoot);
            return null;
        }

        private static void StyleBedroomPlayerVisual(GameObject visual, string resourcePath)
        {
            Shader shader = Shader.Find("Universal Render Pipeline/Lit");
            if (shader == null)
            {
                return;
            }

            Texture2D[] embeddedTextures = Resources.LoadAll<Texture2D>(resourcePath);
            foreach (Renderer visualRenderer in visual.GetComponentsInChildren<Renderer>(true))
            {
                Material[] sourceMaterials = visualRenderer.sharedMaterials;
                Material[] styledMaterials = new Material[sourceMaterials.Length];
                for (int index = 0; index < sourceMaterials.Length; index++)
                {
                    string sourceName = sourceMaterials[index] != null
                        ? sourceMaterials[index].name
                        : string.Empty;
                    string sourceKey = sourceName.ToLowerInvariant();
                    Material styled = new(shader) { name = $"Echo_Noor_{sourceName}" };
                    Texture2D diffuse = FindCharacterTexture(embeddedTextures, sourceKey, "diffuse");
                    if (diffuse != null)
                    {
                        styled.SetTexture("_BaseMap", diffuse);
                        styled.SetColor("_BaseColor", Color.white);
                    }
                    else
                    {
                        styled.SetColor("_BaseColor", CharacterFallbackColor(sourceKey));
                    }
                    Texture2D normal = FindCharacterTexture(embeddedTextures, sourceKey, "normal");
                    if (normal != null)
                    {
                        styled.SetTexture("_BumpMap", normal);
                        styled.EnableKeyword("_NORMALMAP");
                    }
                    styled.SetFloat("_Smoothness", sourceKey.Contains("eye", StringComparison.Ordinal) ? 0.62f : 0.28f);
                    styledMaterials[index] = styled;
                }
                visualRenderer.materials = styledMaterials;
                visualRenderer.shadowCastingMode = ShadowCastingMode.On;
                visualRenderer.receiveShadows = true;
            }
        }

        private static Texture2D FindCharacterTexture(Texture2D[] textures, string materialKey, string channel)
        {
            string region = materialKey.Contains("shoe", StringComparison.Ordinal)
                ? "shoe"
                : materialKey.Contains("top", StringComparison.Ordinal)
                    ? "top"
                    : materialKey.Contains("bottom", StringComparison.Ordinal)
                        ? "bottom"
                        : materialKey.Contains("body", StringComparison.Ordinal)
                            ? "body"
                            : materialKey.Contains("hair", StringComparison.Ordinal)
                                ? "hair"
                                : materialKey.Contains("eye", StringComparison.Ordinal)
                                    ? "eye"
                                    : string.Empty;
            foreach (Texture2D texture in textures)
            {
                string textureKey = texture.name.ToLowerInvariant();
                if (textureKey.Contains(channel, StringComparison.Ordinal) &&
                    (string.IsNullOrEmpty(region) || textureKey.Contains(region, StringComparison.Ordinal)))
                {
                    return texture;
                }
            }
            return null;
        }

        private static Color CharacterFallbackColor(string materialKey)
        {
            if (materialKey.Contains("top", StringComparison.Ordinal)) return new Color(0.32f, 0.08f, 0.1f);
            if (materialKey.Contains("bottom", StringComparison.Ordinal)) return new Color(0.07f, 0.1f, 0.16f);
            if (materialKey.Contains("shoe", StringComparison.Ordinal)) return new Color(0.055f, 0.04f, 0.035f);
            if (materialKey.Contains("hair", StringComparison.Ordinal)) return new Color(0.055f, 0.035f, 0.025f);
            if (materialKey.Contains("eye", StringComparison.Ordinal)) return new Color(0.06f, 0.045f, 0.035f);
            return new Color(0.66f, 0.39f, 0.25f);
        }

        public void ShowBedroom()
        {
            SwitchScene(PrototypeScene.Bedroom);
        }

        public void ShowHarborStreet()
        {
            SwitchScene(PrototypeScene.HarborStreet);
        }

        public void ShowCafeShop()
        {
            SwitchScene(PrototypeScene.CafeShop);
        }

        public void ShowScene(string sceneId)
        {
            switch (sceneId)
            {
                case "bedroom":
                    ShowBedroom();
                    break;
                case "cafe-shop":
                    ShowCafeShop();
                    break;
                default:
                    ShowHarborStreet();
                    break;
            }
        }

        public void ApplySceneChoiceMood(string sceneId, bool openChoice)
        {
            choicePulse = openChoice ? 2.1f : 0.7f;
            if (sceneId == "harbor-street" && streetSun != null)
            {
                streetSun.color = openChoice
                    ? new Color(0.92f, 0.84f, 0.69f)
                    : new Color(0.58f, 0.69f, 0.9f);
            }
            else if (sceneId == "cafe-shop" && cafeSun != null)
            {
                cafeSun.color = openChoice
                    ? new Color(1f, 0.78f, 0.5f)
                    : new Color(0.72f, 0.5f, 0.42f);
                if (cafePendantLight != null)
                {
                    cafePendantLight.color = openChoice
                        ? new Color(1f, 0.58f, 0.25f)
                        : new Color(0.82f, 0.36f, 0.2f);
                }
            }
        }

        public void ResetSceneChoiceMood(string sceneId)
        {
            if (sceneId == "harbor-street" && streetSun != null)
            {
                streetSun.color = new Color(0.78f, 0.84f, 1f);
            }
            else if (sceneId == "cafe-shop" && cafeSun != null)
            {
                cafeSun.color = new Color(0.95f, 0.72f, 0.48f);
                if (cafePendantLight != null)
                {
                    cafePendantLight.color = new Color(1f, 0.47f, 0.18f);
                }
            }
            choicePulse = 0f;
        }

        private void SwitchScene(PrototypeScene scene)
        {
            activeScene = scene;
            bedroomRoot.gameObject.SetActive(scene == PrototypeScene.Bedroom);
            streetRoot.gameObject.SetActive(scene == PrototypeScene.HarborStreet);
            cafeRoot.gameObject.SetActive(scene == PrototypeScene.CafeShop);
            storyStep = 0;
            outcome = string.Empty;
            inspectedObservation = string.Empty;
            observationTimer = 0f;
            choicePulse = 0f;
            orbitCamera.enabled = false;
            thirdPersonCamera.enabled = true;
            bedroomVignette.SetVignetteActive(false);
            streetVignette.SetVignetteActive(false);
            cafeVignette.SetVignetteActive(false);

            if (scene == PrototypeScene.Bedroom)
            {
                sun = bedroomSun;
                ConfigureBedroomAtmosphere();
                mainCamera.fieldOfView = 52f;
                thirdPersonCamera.Configure(bedroomPlayer, -5f);
                bedroomVignette.SetVignetteActive(true);
            }
            else if (scene == PrototypeScene.HarborStreet)
            {
                sun = streetSun;
                ConfigureStreetAtmosphere();
                mainCamera.fieldOfView = 58f;
                thirdPersonCamera.Configure(streetPlayer, 8f);
                streetVignette.SetVignetteActive(true);
            }
            else
            {
                sun = cafeSun;
                ConfigureCafeAtmosphere();
                mainCamera.fieldOfView = 52f;
                thirdPersonCamera.Configure(cafePlayer, -10f);
                cafeVignette.SetVignetteActive(true);
            }

            Debug.Log($"[Echo] Showing {ActiveSceneId} scene.");
        }

        private static void ConfigureBedroomAtmosphere()
        {
            RenderSettings.fogDensity = 0.0045f;
            RenderSettings.fogColor = new Color(0.055f, 0.065f, 0.12f);
            RenderSettings.ambientSkyColor = new Color(0.12f, 0.16f, 0.28f);
            RenderSettings.ambientEquatorColor = new Color(0.12f, 0.1f, 0.15f);
            RenderSettings.ambientGroundColor = new Color(0.04f, 0.035f, 0.055f);
        }

        private static void ConfigureStreetAtmosphere()
        {
            RenderSettings.fogDensity = 0.009f;
            RenderSettings.fogColor = new Color(0.075f, 0.095f, 0.14f);
            RenderSettings.ambientSkyColor = new Color(0.17f, 0.22f, 0.32f);
            RenderSettings.ambientEquatorColor = new Color(0.1f, 0.12f, 0.18f);
            RenderSettings.ambientGroundColor = new Color(0.045f, 0.05f, 0.075f);
        }

        private static void ConfigureCafeAtmosphere()
        {
            RenderSettings.fogDensity = 0.0035f;
            RenderSettings.fogColor = new Color(0.12f, 0.075f, 0.065f);
            RenderSettings.ambientSkyColor = new Color(0.28f, 0.2f, 0.18f);
            RenderSettings.ambientEquatorColor = new Color(0.18f, 0.11f, 0.09f);
            RenderSettings.ambientGroundColor = new Color(0.065f, 0.045f, 0.04f);
        }

        private void HandleInspection()
        {
            if (activeScene == PrototypeScene.Bedroom)
            {
                return;
            }

            Mouse mouse = Mouse.current;
            Camera mainCamera = Camera.main;
            if (mouse == null || mainCamera == null || !mouse.leftButton.wasPressedThisFrame)
            {
                return;
            }

            Vector2 pointer = mouse.position.ReadValue();
            float guiY = Screen.height - pointer.y;
            if (pointer.x < 450f && guiY < 330f)
            {
                return;
            }

            Ray ray = mainCamera.ScreenPointToRay(pointer);
            if (Physics.Raycast(ray, out RaycastHit hit, 100f))
            {
                EchoInspectable inspectable = hit.collider.GetComponent<EchoInspectable>();
                if (inspectable != null)
                {
                    inspectedObservation = inspectable.Observation;
                    observationTimer = 6f;
                }
            }
        }

        private static void CreateInspectable(GameObject item, string observation)
        {
            if (item == null)
            {
                return;
            }

            // Primitive() removes the default collider at end-of-frame. Add a
            // dedicated lightweight collider that survives for optional noticing.
            item.AddComponent<BoxCollider>();
            EchoInspectable inspectable = item.AddComponent<EchoInspectable>();
            inspectable.Configure(observation);
        }

        private GameObject Box(string name, Vector3 position, Vector3 scale, string material, Transform parent, Quaternion? rotation = null)
        {
            return Primitive(PrimitiveType.Cube, name, position, scale, material, parent, rotation);
        }

        private GameObject Sphere(string name, Vector3 position, Vector3 scale, string material, Transform parent)
        {
            return Primitive(PrimitiveType.Sphere, name, position, scale, material, parent);
        }

        private GameObject Capsule(string name, Vector3 position, Vector3 scale, string material, Transform parent)
        {
            return Primitive(PrimitiveType.Capsule, name, position, scale, material, parent);
        }

        private GameObject Cylinder(
            string name,
            Vector3 position,
            Vector3 scale,
            string material,
            Transform parent,
            Quaternion? rotation = null)
        {
            return Primitive(PrimitiveType.Cylinder, name, position, scale, material, parent, rotation);
        }

        private GameObject Primitive(
            PrimitiveType type,
            string objectName,
            Vector3 localPosition,
            Vector3 localScale,
            string material,
            Transform parent,
            Quaternion? localRotation = null)
        {
            GameObject item = GameObject.CreatePrimitive(type);
            item.name = objectName;
            item.transform.SetParent(parent, false);
            item.transform.localPosition = localPosition;
            item.transform.localScale = localScale;
            item.transform.localRotation = localRotation ?? Quaternion.identity;
            Renderer itemRenderer = item.GetComponent<Renderer>();
            itemRenderer.sharedMaterial = materials[material];
            itemRenderer.shadowCastingMode = ShadowCastingMode.On;
            itemRenderer.receiveShadows = true;
            Collider collider = item.GetComponent<Collider>();
            if (collider != null) Destroy(collider);
            return item;
        }

        private void OnGUI()
        {
            if (bedroomVignette != null && streetVignette != null && cafeVignette != null)
            {
                return;
            }

            EnsureStyles();
            float scale = Mathf.Clamp(Screen.height / 900f, 0.72f, 1.18f);
            Matrix4x4 previous = GUI.matrix;
            GUI.matrix = Matrix4x4.Scale(new Vector3(scale, scale, 1f));
            float width = Screen.width / scale;
            float height = Screen.height / scale;

            GUI.Box(new Rect(28f, 28f, 390f, 304f), GUIContent.none);
            GUI.Label(new Rect(54f, 48f, 340f, 32f), "ECHO", labelStyle);
            GUI.Label(
                new Rect(54f, 75f, 340f, 42f),
                activeScene == PrototypeScene.Bedroom
                    ? "What Remains"
                    : activeScene == PrototypeScene.CafeShop
                        ? "The Last Table"
                        : "The Crossing",
                titleStyle);

            string story = storyStep == 0
                ? activeScene == PrototypeScene.Bedroom
                    ? "The rain has quieted the apartment. Noor finds the old photograph beside a half-packed bag. The message asking whether everything is okay is still unanswered."
                    : activeScene == PrototypeScene.CafeShop
                        ? "The café is closing. A sketchbook waits on the last table, its owner already disappearing beyond the rain-dark window. Amira looks from the name inside the cover to the door."
                        : "The evening bus exhales at the curb. A visitor studies the route map, then the darkening street. Everyone else keeps moving."
                : outcome;
            GUI.Label(new Rect(54f, 119f, 338f, 78f), story, bodyStyle);

            if (storyStep == 0)
            {
                string primaryChoice = activeScene == PrototypeScene.Bedroom
                    ? "Answer honestly"
                    : activeScene == PrototypeScene.CafeShop
                        ? "Call after them"
                        : "Walk over";
                string secondaryChoice = activeScene == PrototypeScene.Bedroom
                    ? "Say you're fine"
                    : activeScene == PrototypeScene.CafeShop
                        ? "Keep it safe"
                        : "Keep moving";
                if (GUI.Button(new Rect(54f, 201f, 157f, 42f), primaryChoice, buttonStyle))
                {
                    Choose(true);
                }
                if (GUI.Button(new Rect(224f, 201f, 168f, 42f), secondaryChoice, buttonStyle))
                {
                    Choose(false);
                }
            }
            else if (GUI.Button(new Rect(54f, 201f, 338f, 42f), "Try the other choice", buttonStyle))
            {
                storyStep = 0;
                outcome = string.Empty;
                choicePulse = 0f;
            }

            GUI.Label(new Rect(54f, 255f, 338f, 18f), "PROOF SCENES", smallStyle);
            if (GUI.Button(new Rect(54f, 278f, 102f, 32f), "Bedroom", buttonStyle) &&
                activeScene != PrototypeScene.Bedroom)
            {
                ShowBedroom();
            }
            if (GUI.Button(new Rect(164f, 278f, 102f, 32f), "Street", buttonStyle) &&
                activeScene != PrototypeScene.HarborStreet)
            {
                ShowHarborStreet();
            }
            if (GUI.Button(new Rect(274f, 278f, 118f, 32f), "Café", buttonStyle) &&
                activeScene != PrototypeScene.CafeShop)
            {
                ShowCafeShop();
            }

            GUI.Box(new Rect(width - 318f, height - 92f, 288f, 62f), GUIContent.none);
            GUI.Label(new Rect(width - 298f, height - 79f, 250f, 22f), "RIGHT-DRAG / ARROWS TO LOOK", smallStyle);
            GUI.Label(new Rect(width - 298f, height - 57f, 250f, 18f), "Click details  •  Scroll  •  R reset", smallStyle);

            if (!string.IsNullOrEmpty(inspectedObservation))
            {
                float observationWidth = Mathf.Min(540f, width - 60f);
                GUI.Box(new Rect((width - observationWidth) * 0.5f, height - 142f, observationWidth, 56f), GUIContent.none);
                GUI.Label(
                    new Rect((width - observationWidth) * 0.5f + 18f, height - 130f, observationWidth - 36f, 38f),
                    inspectedObservation,
                    bodyStyle);
            }

            string sceneFooter = activeScene == PrototypeScene.Bedroom
                ? "SCENE 02  •  NOOR'S BEDROOM  •  UNITY PERSONAL PROTOTYPE"
                : activeScene == PrototypeScene.CafeShop
                    ? "SCENE 03  •  SAFFRON CAFÉ  •  UNITY PERSONAL PROTOTYPE"
                    : "SCENE 01  •  HARBOR STREET  •  UNITY PERSONAL PROTOTYPE";
            GUI.Label(new Rect(30f, height - 54f, 520f, 24f), sceneFooter, smallStyle);
            GUI.matrix = previous;
        }

        private void Choose(bool help)
        {
            storyStep = 1;
            choicePulse = help ? 2.1f : 0.7f;
            if (activeScene == PrototypeScene.Bedroom)
            {
                outcome = help
                    ? "Noor writes, then deletes the apology at the beginning. The honest sentence is smaller. It is also the first one that feels possible to send."
                    : "Noor sends the familiar answer. The room accepts it without argument; the rain keeps making quiet paths down the glass.";
            }
            else if (activeScene == PrototypeScene.CafeShop)
            {
                outcome = help
                    ? "Amira catches the door before it closes. The owner sees the name inside the cover, then the drawing, and relief arrives before the thank-you."
                    : "Amira places the sketchbook behind the counter where it will stay dry. Tomorrow, she decides, there will still be time to return it.";
            }
            else
            {
                outcome = help
                    ? "You point out the right stop. Their shoulders loosen. It costs less than a minute, but the street feels different afterward."
                    : "You pass beneath the café light. The bus arrives behind you; for a moment, you wonder whether they found the right one.";
            }

            if (sun != null)
            {
                if (activeScene == PrototypeScene.Bedroom)
                {
                    sun.color = help
                        ? new Color(0.62f, 0.58f, 0.78f)
                        : new Color(0.28f, 0.39f, 0.68f);
                }
                else if (activeScene == PrototypeScene.CafeShop)
                {
                    sun.color = help
                        ? new Color(1f, 0.78f, 0.5f)
                        : new Color(0.72f, 0.5f, 0.42f);
                }
                else
                {
                    sun.color = help
                        ? new Color(0.92f, 0.86f, 0.72f)
                        : new Color(0.64f, 0.73f, 0.92f);
                }
            }
        }

        private void EnsureStyles()
        {
            if (titleStyle != null) return;

            titleStyle = new GUIStyle(GUI.skin.label)
            {
                fontSize = 27,
                fontStyle = FontStyle.Bold,
                normal = { textColor = new Color(0.97f, 0.94f, 0.87f) }
            };
            bodyStyle = new GUIStyle(GUI.skin.label)
            {
                fontSize = 15,
                wordWrap = true,
                normal = { textColor = new Color(0.82f, 0.84f, 0.88f) }
            };
            labelStyle = new GUIStyle(GUI.skin.label)
            {
                fontSize = 12,
                fontStyle = FontStyle.Bold,
                normal = { textColor = new Color(0.98f, 0.57f, 0.2f) }
            };
            buttonStyle = new GUIStyle(GUI.skin.button)
            {
                fontSize = 14,
                fontStyle = FontStyle.Bold,
                normal = { textColor = Color.white },
                hover = { textColor = new Color(1f, 0.76f, 0.4f) }
            };
            smallStyle = new GUIStyle(GUI.skin.label)
            {
                fontSize = 11,
                normal = { textColor = new Color(0.7f, 0.74f, 0.8f) }
            };
        }
    }
}
