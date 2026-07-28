using System.Collections.Generic;
using UnityEngine;
using UnityEngine.InputSystem;

namespace Echo.FreePrototype
{
    public sealed class EchoPlayableVignetteDefinition
    {
        public string SceneId { get; set; }
        public string Title { get; set; }
        public string FirstInteractionId { get; set; }
        public string FirstObjective { get; set; }
        public string SecondInteractionId { get; set; }
        public string SecondObjective { get; set; }
        public string ChoiceObjective { get; set; }
        public string ChoiceTitle { get; set; }
        public string ChoiceQuestion { get; set; }
        public string HonestChoice { get; set; }
        public string GuardedChoice { get; set; }
        public string HonestResolutionTitle { get; set; }
        public string GuardedResolutionTitle { get; set; }
        public string HonestResolution { get; set; }
        public string GuardedResolution { get; set; }
        public string NextSceneId { get; set; }
        public string NextSceneLabel { get; set; }
    }

    /// <summary>
    /// Reusable two-beat, no-fail vignette loop used after the Bedroom reference
    /// slice proved the interaction contract.
    /// </summary>
    public sealed class EchoPlayableVignette : MonoBehaviour
    {
        private const float InteractionRange = 2.05f;

        private readonly List<EchoInteractable> interactions = new();
        private EchoWorldBootstrap bootstrap;
        private EchoPlayableVignetteDefinition definition;
        private Transform player;
        private EchoThirdPersonController controller;
        private EchoInteractable nearbyInteraction;
        private int stage;
        private bool isActive;
        private bool isPaused;
        private bool honestChoice;
        private string observation = string.Empty;
        private float observationTimer;
        private float tutorialTimer;
        private GUIStyle titleStyle;
        private GUIStyle bodyStyle;
        private GUIStyle smallStyle;
        private GUIStyle buttonStyle;

        public string CurrentObjectiveId => stage switch
        {
            0 => definition?.FirstInteractionId ?? string.Empty,
            1 => definition?.SecondInteractionId ?? string.Empty,
            2 => "choice",
            _ => "complete"
        };

        public bool IsComplete => stage >= 3;

        public void Configure(
            EchoWorldBootstrap worldBootstrap,
            EchoPlayableVignetteDefinition vignetteDefinition,
            Transform playerTransform,
            EchoThirdPersonController playerController,
            IEnumerable<EchoInteractable> sceneInteractions)
        {
            bootstrap = worldBootstrap;
            definition = vignetteDefinition;
            player = playerTransform;
            controller = playerController;
            interactions.Clear();
            interactions.AddRange(sceneInteractions);
            RestartVignette();
        }

        public void SetVignetteActive(bool value)
        {
            isActive = value;
            enabled = value;
            controller?.SetInputEnabled(value && !isPaused && stage < 2);
        }

        public void InteractForTest(string interactionId)
        {
            EchoInteractable interaction = interactions.Find(item => item.Id == interactionId);
            if (interaction != null)
            {
                ResolveInteraction(interaction);
            }
        }

        public void ChooseForTest(bool honest)
        {
            if (stage == 2)
            {
                ResolveChoice(honest);
            }
        }

        private void Update()
        {
            if (!isActive)
            {
                return;
            }

            tutorialTimer = Mathf.Max(0f, tutorialTimer - Time.unscaledDeltaTime);
            observationTimer = Mathf.Max(0f, observationTimer - Time.unscaledDeltaTime);
            if (observationTimer <= 0f)
            {
                observation = string.Empty;
            }

            Keyboard keyboard = Keyboard.current;
            Gamepad gamepad = Gamepad.current;
            if ((keyboard != null && keyboard.escapeKey.wasPressedThisFrame) ||
                (gamepad != null && gamepad.startButton.wasPressedThisFrame))
            {
                isPaused = !isPaused;
                controller?.SetInputEnabled(!isPaused && stage < 2);
            }
            if (keyboard != null && keyboard.rKey.wasPressedThisFrame)
            {
                RestartVignette();
            }

            nearbyInteraction = FindNearestInteraction();
            bool interactPressed =
                (keyboard != null && keyboard.eKey.wasPressedThisFrame) ||
                (gamepad != null && gamepad.buttonSouth.wasPressedThisFrame);
            if (!isPaused && stage < 2 && interactPressed && nearbyInteraction != null)
            {
                ResolveInteraction(nearbyInteraction);
            }
        }

        private EchoInteractable FindNearestInteraction()
        {
            if (player == null)
            {
                return null;
            }

            EchoInteractable nearest = null;
            float nearestDistance = InteractionRange;
            foreach (EchoInteractable interaction in interactions)
            {
                if (interaction == null || !interaction.IsAvailable(stage))
                {
                    continue;
                }
                if ((interaction.Id == definition.FirstInteractionId && stage != 0) ||
                    (interaction.Id == definition.SecondInteractionId && stage != 1))
                {
                    continue;
                }
                float distance = Vector3.Distance(player.position, interaction.transform.position);
                if (distance < nearestDistance)
                {
                    nearestDistance = distance;
                    nearest = interaction;
                }
            }
            return nearest;
        }

        private void ResolveInteraction(EchoInteractable interaction)
        {
            observation = interaction.Observation;
            observationTimer = 6f;
            if (interaction.Id == definition.FirstInteractionId && stage == 0)
            {
                stage = 1;
            }
            else if (interaction.Id == definition.SecondInteractionId && stage == 1)
            {
                stage = 2;
                controller?.SetInputEnabled(false);
            }
        }

        private void ResolveChoice(bool honest)
        {
            honestChoice = honest;
            stage = 3;
            controller?.SetInputEnabled(false);
            bootstrap?.ApplySceneChoiceMood(definition.SceneId, honest);
            observation = honest
                ? definition.HonestResolution
                : definition.GuardedResolution;
            observationTimer = 30f;
        }

        private void RestartVignette()
        {
            stage = 0;
            isPaused = false;
            honestChoice = false;
            observation = string.Empty;
            observationTimer = 0f;
            tutorialTimer = 8f;
            nearbyInteraction = null;
            bootstrap?.ResetSceneChoiceMood(definition?.SceneId);
            controller?.ResetToStart();
            controller?.SetInputEnabled(isActive);
        }

        private void OnGUI()
        {
            if (!isActive || definition == null)
            {
                return;
            }

            EnsureStyles();
            float scale = Mathf.Clamp(Screen.height / 900f, 0.72f, 1.18f);
            Matrix4x4 previous = GUI.matrix;
            GUI.matrix = Matrix4x4.Scale(new Vector3(scale, scale, 1f));
            float width = Screen.width / scale;
            float height = Screen.height / scale;

            GUI.Box(new Rect(28f, 28f, 378f, 164f), GUIContent.none);
            GUI.Label(new Rect(50f, 44f, 336f, 27f), definition.Title, titleStyle);
            GUI.Label(new Rect(50f, 78f, 320f, 18f), "CURRENT INTENTION", smallStyle);
            GUI.Label(new Rect(50f, 101f, 330f, 34f), ObjectiveText(), bodyStyle);
            if (stage < 2 && GUI.Button(new Rect(50f, 145f, 158f, 31f), "Skip to choice", buttonStyle))
            {
                stage = 2;
                controller?.SetInputEnabled(false);
            }
            if (GUI.Button(new Rect(218f, 145f, 162f, 31f), isPaused ? "Resume" : "Pause", buttonStyle))
            {
                isPaused = !isPaused;
                controller?.SetInputEnabled(!isPaused && stage < 2);
            }

            if (tutorialTimer > 0f && stage < 2)
            {
                GUI.Box(new Rect(28f, 205f, 378f, 48f), GUIContent.none);
                GUI.Label(
                    new Rect(48f, 218f, 340f, 24f),
                    "HOLD WASD TO WALK  •  E TO INTERACT",
                    smallStyle);
            }

            if (nearbyInteraction != null && stage < 2 && !isPaused)
            {
                float promptWidth = 360f;
                GUI.Box(new Rect((width - promptWidth) * 0.5f, height - 126f, promptWidth, 50f), GUIContent.none);
                GUI.Label(
                    new Rect((width - promptWidth) * 0.5f + 18f, height - 113f, promptWidth - 36f, 24f),
                    $"E  •  {nearbyInteraction.Prompt}",
                    bodyStyle);
            }

            if (stage < 2 && !isPaused)
            {
                DrawObjectiveMarker(scale, width, height);
            }

            if (!string.IsNullOrEmpty(observation))
            {
                float observationWidth = Mathf.Min(660f, width - 70f);
                GUI.Box(new Rect((width - observationWidth) * 0.5f, height - 196f, observationWidth, 60f), GUIContent.none);
                GUI.Label(
                    new Rect((width - observationWidth) * 0.5f + 20f, height - 182f, observationWidth - 40f, 38f),
                    observation,
                    bodyStyle);
            }

            if (stage == 2)
            {
                DrawChoice(width, height);
            }
            else if (stage >= 3)
            {
                DrawResolution(width, height);
            }

            GUI.Box(new Rect(width - 342f, height - 94f, 312f, 64f), GUIContent.none);
            GUI.Label(new Rect(width - 322f, height - 80f, 280f, 20f), "WASD MOVE  •  RIGHT-DRAG LOOK", smallStyle);
            GUI.Label(new Rect(width - 322f, height - 57f, 280f, 18f), "E INTERACT  •  R RESTART", smallStyle);
            GUI.matrix = previous;
        }

        private void DrawObjectiveMarker(float scale, float width, float height)
        {
            string objectiveId = stage == 0
                ? definition.FirstInteractionId
                : definition.SecondInteractionId;
            EchoInteractable objective = interactions.Find(item => item != null && item.Id == objectiveId);
            Camera cameraComponent = Camera.main;
            if (objective == null || cameraComponent == null || player == null)
            {
                return;
            }

            Vector3 screenPoint = cameraComponent.WorldToScreenPoint(objective.transform.position + Vector3.up * 0.4f);
            bool behindCamera = screenPoint.z < 0f;
            float guiX = behindCamera ? width - screenPoint.x / scale : screenPoint.x / scale;
            float guiY = behindCamera ? screenPoint.y / scale : (Screen.height - screenPoint.y) / scale;
            guiX = Mathf.Clamp(guiX, 120f, width - 120f);
            guiY = Mathf.Clamp(guiY, 280f, height - 155f);
            float distance = Vector3.Distance(player.position, objective.transform.position);
            string label = objectiveId.Replace("_", " ").ToUpperInvariant();
            GUI.Box(new Rect(guiX - 92f, guiY - 19f, 184f, 38f), GUIContent.none);
            GUI.Label(new Rect(guiX - 82f, guiY - 12f, 164f, 22f), $"◆  {label}  •  {distance:0.0}m", smallStyle);
        }

        private void DrawChoice(float width, float height)
        {
            float panelWidth = 600f;
            float x = (width - panelWidth) * 0.5f;
            float y = (height - 252f) * 0.5f;
            GUI.Box(new Rect(x, y, panelWidth, 252f), GUIContent.none);
            GUI.Label(new Rect(x + 28f, y + 24f, panelWidth - 56f, 32f), definition.ChoiceTitle, titleStyle);
            GUI.Label(new Rect(x + 28f, y + 67f, panelWidth - 56f, 68f), definition.ChoiceQuestion, bodyStyle);
            if (GUI.Button(new Rect(x + 28f, y + 157f, 258f, 50f), definition.HonestChoice, buttonStyle))
            {
                ResolveChoice(true);
            }
            if (GUI.Button(new Rect(x + 314f, y + 157f, 258f, 50f), definition.GuardedChoice, buttonStyle))
            {
                ResolveChoice(false);
            }
        }

        private void DrawResolution(float width, float height)
        {
            float panelWidth = 470f;
            float x = (width - panelWidth) * 0.5f;
            float y = height * 0.5f - 78f;
            GUI.Box(new Rect(x, y, panelWidth, 156f), GUIContent.none);
            GUI.Label(
                new Rect(x + 24f, y + 22f, panelWidth - 48f, 30f),
                honestChoice ? definition.HonestResolutionTitle : definition.GuardedResolutionTitle,
                titleStyle);
            if (GUI.Button(new Rect(x + 24f, y + 84f, 198f, 42f), "Replay vignette", buttonStyle))
            {
                RestartVignette();
            }
            if (GUI.Button(new Rect(x + 242f, y + 84f, 204f, 42f), definition.NextSceneLabel, buttonStyle))
            {
                bootstrap.ShowScene(definition.NextSceneId);
            }
        }

        private string ObjectiveText()
        {
            return stage switch
            {
                0 => definition.FirstObjective,
                1 => definition.SecondObjective,
                2 => definition.ChoiceObjective,
                _ => "The moment has passed."
            };
        }

        private void EnsureStyles()
        {
            if (titleStyle != null)
            {
                return;
            }

            titleStyle = new GUIStyle(GUI.skin.label)
            {
                fontSize = 22,
                fontStyle = FontStyle.Bold,
                normal = { textColor = new Color(0.97f, 0.94f, 0.87f) }
            };
            bodyStyle = new GUIStyle(GUI.skin.label)
            {
                fontSize = 15,
                wordWrap = true,
                normal = { textColor = new Color(0.91f, 0.9f, 0.86f) }
            };
            smallStyle = new GUIStyle(GUI.skin.label)
            {
                fontSize = 11,
                fontStyle = FontStyle.Bold,
                normal = { textColor = new Color(0.7f, 0.78f, 0.9f) }
            };
            buttonStyle = new GUIStyle(GUI.skin.button)
            {
                fontSize = 14,
                fontStyle = FontStyle.Bold,
                normal = { textColor = new Color(0.94f, 0.94f, 0.92f) }
            };
        }
    }
}
