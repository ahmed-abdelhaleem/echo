using UnityEngine;
using UnityEngine.InputSystem;

namespace Echo.FreePrototype
{
    /// <summary>
    /// Compact camera-relative movement for Echo's bounded playable vignettes.
    /// There is intentionally no sprint, jump, combat, stamina, or fail state.
    /// </summary>
    public sealed class EchoThirdPersonController : MonoBehaviour
    {
        private Camera movementCamera;
        private CharacterController characterController;
        private EchoMixamoCharacter animationPlayback;
        private Bounds movementBounds;
        private Vector3 startPosition;
        private Quaternion startRotation;
        private bool acceptsInput;
        private float movementSpeed = 2.15f;
        private Vector2 smoothedInput;
        private Vector2 inputSmoothVelocity;
        private Vector2 bufferedTapInput;
        private float bufferedTapTimer;

        public float CurrentSpeed { get; private set; }
        public bool AcceptsInput => acceptsInput;

        public void Configure(
            Camera cameraComponent,
            Bounds bounds,
            EchoMixamoCharacter playback,
            float speed = 2.15f)
        {
            movementCamera = cameraComponent;
            movementBounds = bounds;
            animationPlayback = playback;
            movementSpeed = speed;
            characterController = GetComponent<CharacterController>();
            startPosition = transform.position;
            startRotation = transform.rotation;
            acceptsInput = true;
        }

        public void SetInputEnabled(bool value)
        {
            acceptsInput = value;
            if (!acceptsInput)
            {
                CurrentSpeed = 0f;
                smoothedInput = Vector2.zero;
                inputSmoothVelocity = Vector2.zero;
                animationPlayback?.SetLocomotion(0f);
            }
        }

        public void ResetToStart()
        {
            bool wasEnabled = characterController != null && characterController.enabled;
            if (characterController != null)
            {
                characterController.enabled = false;
            }
            transform.SetPositionAndRotation(startPosition, startRotation);
            if (characterController != null)
            {
                characterController.enabled = wasEnabled;
            }
            CurrentSpeed = 0f;
            smoothedInput = Vector2.zero;
            inputSmoothVelocity = Vector2.zero;
            bufferedTapInput = Vector2.zero;
            bufferedTapTimer = 0f;
            animationPlayback?.SetLocomotion(0f);
        }

        private void Update()
        {
            if (!acceptsInput || movementCamera == null)
            {
                return;
            }

            Move(ReadMovement(Time.deltaTime), Time.deltaTime);
        }

        public void MoveForTest(Vector2 input, float deltaTime)
        {
            Move(Vector2.ClampMagnitude(input, 1f), deltaTime);
        }

        private void Move(Vector2 input, float deltaTime)
        {
            float smoothingTime = input.sqrMagnitude > 0.0025f ? 0.11f : 0.17f;
            smoothedInput = Vector2.SmoothDamp(
                smoothedInput,
                input,
                ref inputSmoothVelocity,
                smoothingTime,
                Mathf.Infinity,
                Mathf.Max(0.0001f, deltaTime));

            Vector3 cameraForward = movementCamera.transform.forward;
            Vector3 cameraRight = movementCamera.transform.right;
            cameraForward.y = 0f;
            cameraRight.y = 0f;
            cameraForward.Normalize();
            cameraRight.Normalize();

            Vector3 direction = cameraForward * smoothedInput.y + cameraRight * smoothedInput.x;
            direction = Vector3.ClampMagnitude(direction, 1f);
            CurrentSpeed = direction.magnitude * movementSpeed;

            if (direction.sqrMagnitude > 0.004f)
            {
                Quaternion targetRotation = Quaternion.LookRotation(direction, Vector3.up);
                transform.rotation = Quaternion.RotateTowards(
                    transform.rotation,
                    targetRotation,
                    300f * deltaTime);

                Vector3 motion = direction * movementSpeed * deltaTime;
                if (characterController != null && characterController.enabled)
                {
                    characterController.Move(motion);
                }
                else
                {
                    transform.position += motion;
                }

                Vector3 clamped = transform.position;
                clamped.x = Mathf.Clamp(clamped.x, movementBounds.min.x, movementBounds.max.x);
                clamped.z = Mathf.Clamp(clamped.z, movementBounds.min.z, movementBounds.max.z);
                clamped.y = startPosition.y;
                transform.position = clamped;
            }

            animationPlayback?.SetLocomotion(Mathf.Clamp01(direction.magnitude));
        }

        private Vector2 ReadMovement(float deltaTime)
        {
            Vector2 input = Vector2.zero;
            Keyboard keyboard = Keyboard.current;
            if (keyboard != null)
            {
                if (keyboard.aKey.isPressed) input.x -= 1f;
                if (keyboard.dKey.isPressed) input.x += 1f;
                if (keyboard.sKey.isPressed) input.y -= 1f;
                if (keyboard.wKey.isPressed) input.y += 1f;

                Vector2 tapInput = Vector2.zero;
                if (keyboard.aKey.wasPressedThisFrame) tapInput.x -= 1f;
                if (keyboard.dKey.wasPressedThisFrame) tapInput.x += 1f;
                if (keyboard.sKey.wasPressedThisFrame) tapInput.y -= 1f;
                if (keyboard.wKey.wasPressedThisFrame) tapInput.y += 1f;
                if (tapInput.sqrMagnitude > 0f)
                {
                    bufferedTapInput = Vector2.ClampMagnitude(tapInput, 1f);
                    bufferedTapTimer = 0.12f;
                }
            }

            Gamepad gamepad = Gamepad.current;
            if (gamepad != null)
            {
                Vector2 stick = gamepad.leftStick.ReadValue();
                if (stick.sqrMagnitude > input.sqrMagnitude)
                {
                    input = stick;
                }
            }

            if (input.sqrMagnitude <= 0.0025f && bufferedTapTimer > 0f)
            {
                bufferedTapTimer = Mathf.Max(0f, bufferedTapTimer - deltaTime);
                input = bufferedTapInput;
            }
            else if (input.sqrMagnitude > 0.0025f)
            {
                bufferedTapTimer = 0f;
            }

            return Vector2.ClampMagnitude(input, 1f);
        }
    }
}
