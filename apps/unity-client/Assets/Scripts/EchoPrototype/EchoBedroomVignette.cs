using System.Collections.Generic;
using UnityEngine;
using UnityEngine.InputSystem;

namespace Echo.FreePrototype
{
    /// <summary>
    /// Deterministic no-fail gameplay director for the What Remains vignette.
    /// </summary>
    public sealed class EchoBedroomVignette : MonoBehaviour
    {
        private const float InteractionRange = 1.75f;

        private readonly List<EchoInteractable> interactions = new();
        private EchoWorldBootstrap bootstrap;
        private Transform player;
        private EchoThirdPersonController controller;
        private EchoInteractionActionDirector actionDirector;
        private EchoInteractionCoordinator coordinator;
        private EchoInteractable nearbyInteraction;
        private int stage;
        private bool isActive;
        private bool isPaused;
        private bool choiceMade;
        private string observation = string.Empty;
        private float observationTimer;
        private float tutorialTimer;
        private GUIStyle titleStyle;
        private GUIStyle bodyStyle;
        private GUIStyle smallStyle;
        private GUIStyle buttonStyle;

        public string CurrentObjectiveId => stage switch
        {
            0 => "photograph",
            1 => "phone",
            2 => "choice",
            _ => "complete"
        };

        public bool IsComplete => stage >= 3;

        public void Configure(
            EchoWorldBootstrap worldBootstrap,
            Transform playerTransform,
            EchoThirdPersonController playerController,
            IEnumerable<EchoInteractable> sceneInteractions,
            EchoInteractionActionDirector interactionActions = null,
            EchoInteractionCoordinator interactionCoordinator = null)
        {
            bootstrap = worldBootstrap;
            player = playerTransform;
            controller = playerController;
            actionDirector = interactionActions;
            coordinator = interactionCoordinator;
            actionDirector?.ConfigurePlayer(playerTransform);
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
            EchoInteractable target = interactions.Find(item => item.Id == interactionId);
            if (target != null)
            {
                ResolveInteraction(target);
            }
        }

        public void ChooseForTest(bool honest)
        {
            if (stage == 2)
            {
                ResolveChoice(honest);
            }
        }

        public void RestartForTest()
        {
            RestartVignette();
        }

        private void Update()
        {
            if (!isActive)
            {
                return;
            }

            observationTimer = Mathf.Max(0f, observationTimer - Time.unscaledDeltaTime);
            tutorialTimer = Mathf.Max(0f, tutorialTimer - Time.unscaledDeltaTime);
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

            EchoInteractable best = null;
            float bestDistance = InteractionRange;
            foreach (EchoInteractable interaction in interactions)
            {
                if (interaction == null || !interaction.IsAvailable(stage))
                {
                    continue;
                }
                if ((interaction.Id == "photograph" && stage != 0) ||
                    (interaction.Id == "phone" && stage != 1))
                {
                    continue;
                }
                float distance = Vector3.Distance(player.position, interaction.transform.position);
                if (distance < bestDistance)
                {
                    bestDistance = distance;
                    best = interaction;
                }
            }
            return best;
        }

        private void ResolveInteraction(EchoInteractable interaction)
        {
            observation = interaction.Observation;
            observationTimer = 6f;

            // Hero props that have an authored interaction profile go through the
            // coordinator, which moves the hand to the stationary prop and only
            // then attaches it. Everything else keeps the older director, so the
            // migration is per-prop rather than a single risky cutover.
            if (coordinator != null && coordinator.IsRegistered(interaction.Id))
            {
                coordinator.TryBegin(interaction.Id);
            }
            else
            {
                actionDirector?.Play(interaction.Id);
            }

            if (interaction.Id == "photograph" && stage == 0)
            {
                stage = 1;
            }
            else if (interaction.Id == "phone" && stage == 1)
            {
                stage = 2;
                controller?.SetInputEnabled(false);
            }
        }

        private void ResolveChoice(bool honest)
        {
            choiceMade = honest;
            stage = 3;
            controller?.SetInputEnabled(false);
            bootstrap?.ApplyBedroomChoiceMood(honest);
            observation = honest
                ? "Noor deletes the apology at the beginning. The honest sentence is smaller—and finally possible to send."
                : "The familiar answer leaves Noor's thumb. The room goes quiet around it.";
            observationTimer = 30f;
        }

        private void RestartVignette()
        {
            stage = 0;
            isPaused = false;
            choiceMade = false;
            observation = string.Empty;
            observationTimer = 0f;
            tutorialTimer = 8f;
            nearbyInteraction = null;
            bootstrap?.ResetBedroomChoiceMood();
            actionDirector?.ResetActions();
            // A restart mid-interaction would otherwise strand a prop in mid-air
            // with the arm still weighted; CancelAll puts both back to rest.
            coordinator?.CancelAll();
            controller?.ResetToStart();
            controller?.SetInputEnabled(isActive);
        }

        private void OnGUI()
        {
            if (!isActive)
            {
                return;
            }

            EnsureStyles();
            float scale = Mathf.Clamp(Screen.height / 900f, 0.72f, 1.18f);
            Matrix4x4 previous = GUI.matrix;
            GUI.matrix = Matrix4x4.Scale(new Vector3(scale, scale, 1f));
            float width = Screen.width / scale;
            float height = Screen.height / scale;

            GUI.Box(new Rect(28f, 28f, 360f, 155f), GUIContent.none);
            GUI.Label(new Rect(50f, 45f, 310f, 24f), "WHAT REMAINS", titleStyle);
            GUI.Label(new Rect(50f, 77f, 310f, 18f), "CURRENT INTENTION", smallStyle);
            GUI.Label(new Rect(50f, 101f, 310f, 32f), ObjectiveText(), bodyStyle);
            if (stage < 2 && GUI.Button(new Rect(50f, 139f, 150f, 30f), "Skip to choice", buttonStyle))
            {
                stage = 2;
                controller?.SetInputEnabled(false);
            }
            if (GUI.Button(new Rect(210f, 139f, 150f, 30f), isPaused ? "Resume" : "Pause", buttonStyle))
            {
                isPaused = !isPaused;
                controller?.SetInputEnabled(!isPaused && stage < 2);
            }

            if (nearbyInteraction != null && stage < 2 && !isPaused)
            {
                float promptWidth = 330f;
                GUI.Box(new Rect((width - promptWidth) * 0.5f, height - 126f, promptWidth, 50f), GUIContent.none);
                GUI.Label(
                    new Rect((width - promptWidth) * 0.5f + 18f, height - 113f, promptWidth - 36f, 24f),
                    $"E  •  {nearbyInteraction.Prompt}",
                    bodyStyle);
            }

            if (tutorialTimer > 0f && stage < 2)
            {
                GUI.Box(new Rect(28f, 197f, 360f, 48f), GUIContent.none);
                GUI.Label(
                    new Rect(48f, 210f, 320f, 24f),
                    "HOLD WASD TO WALK  •  E TO INTERACT",
                    smallStyle);
            }

            if (stage < 2 && !isPaused)
            {
                DrawObjectiveMarker(scale, width, height);
            }

            if (!string.IsNullOrEmpty(observation))
            {
                float observationWidth = Mathf.Min(620f, width - 70f);
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

            GUI.Box(new Rect(width - 330f, height - 92f, 300f, 62f), GUIContent.none);
            GUI.Label(new Rect(width - 310f, height - 79f, 265f, 20f), "WASD MOVE  •  RIGHT-DRAG LOOK", smallStyle);
            GUI.Label(new Rect(width - 310f, height - 57f, 265f, 18f), "E INTERACT  •  R RESTART", smallStyle);

            GUI.matrix = previous;
        }

        private void DrawObjectiveMarker(float scale, float width, float height)
        {
            string objectiveId = stage == 0 ? "photograph" : "phone";
            EchoInteractable objective = interactions.Find(item => item != null && item.Id == objectiveId);
            Camera cameraComponent = Camera.main;
            if (objective == null || cameraComponent == null || player == null)
            {
                return;
            }

            Vector3 screenPoint = cameraComponent.WorldToScreenPoint(objective.transform.position + Vector3.up * 0.35f);
            bool behindCamera = screenPoint.z < 0f;
            float guiX = behindCamera ? width - screenPoint.x / scale : screenPoint.x / scale;
            float guiY = behindCamera ? screenPoint.y / scale : (Screen.height - screenPoint.y) / scale;
            guiX = Mathf.Clamp(guiX, 115f, width - 115f);
            guiY = Mathf.Clamp(guiY, 205f, height - 155f);
            float distance = Vector3.Distance(player.position, objective.transform.position);
            string label = objectiveId == "photograph" ? "◆  PHOTOGRAPH" : "◆  PHONE";
            GUI.Box(new Rect(guiX - 82f, guiY - 19f, 164f, 38f), GUIContent.none);
            GUI.Label(new Rect(guiX - 72f, guiY - 12f, 144f, 22f), $"{label}  •  {distance:0.0}m", smallStyle);
        }

        private void DrawChoice(float width, float height)
        {
            float panelWidth = 560f;
            float x = (width - panelWidth) * 0.5f;
            float y = (height - 240f) * 0.5f;
            GUI.Box(new Rect(x, y, panelWidth, 240f), GUIContent.none);
            GUI.Label(new Rect(x + 28f, y + 24f, panelWidth - 56f, 32f), "THE MESSAGE", titleStyle);
            GUI.Label(
                new Rect(x + 28f, y + 67f, panelWidth - 56f, 58f),
                "“You don't have to explain everything. I just need to know: are you really okay?”",
                bodyStyle);
            if (GUI.Button(new Rect(x + 28f, y + 145f, 238f, 50f), "Answer honestly", buttonStyle))
            {
                ResolveChoice(true);
            }
            if (GUI.Button(new Rect(x + 294f, y + 145f, 238f, 50f), "Say you're fine", buttonStyle))
            {
                ResolveChoice(false);
            }
        }

        private void DrawResolution(float width, float height)
        {
            float panelWidth = 420f;
            float x = (width - panelWidth) * 0.5f;
            float y = height * 0.5f - 75f;
            GUI.Box(new Rect(x, y, panelWidth, 150f), GUIContent.none);
            GUI.Label(
                new Rect(x + 24f, y + 22f, panelWidth - 48f, 28f),
                choiceMade ? "THE TRUTH IS SENT" : "THE ROOM STAYS QUIET",
                titleStyle);
            if (GUI.Button(new Rect(x + 24f, y + 78f, 176f, 42f), "Replay vignette", buttonStyle))
            {
                RestartVignette();
            }
            if (GUI.Button(new Rect(x + 220f, y + 78f, 176f, 42f), "Visit Harbor Street", buttonStyle))
            {
                bootstrap.ShowHarborStreet();
            }
        }

        private string ObjectiveText()
        {
            return stage switch
            {
                0 => "Find the photograph beside the bed.",
                1 => "Read the message waiting on the desk.",
                2 => "Decide what Noor sends.",
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
                normal = { textColor = new Color(0.7f, 0.74f, 0.82f) }
            };
            buttonStyle = new GUIStyle(GUI.skin.button)
            {
                fontSize = 14,
                fontStyle = FontStyle.Bold,
                normal = { textColor = new Color(0.92f, 0.92f, 0.9f) }
            };
        }
    }
}
