using UnityEngine;
using UnityEngine.InputSystem;

namespace Echo.FreePrototype
{
    /// <summary>
    /// Damped, bounded follow camera for compact third-person vignettes.
    /// </summary>
    public sealed class EchoThirdPersonCamera : MonoBehaviour
    {
        private Transform target;
        private Vector3 smoothFocus;
        private float yaw;
        private float pitch = 16f;
        private float distance = 4.6f;
        private bool wasDragging;
        private Vector2 previousPointer;

        public void Configure(Transform followTarget, float startYaw = 0f)
        {
            target = followTarget;
            yaw = startYaw;
            smoothFocus = target != null ? target.position + Vector3.up * 1.35f : Vector3.zero;
            ApplyTransform(true);
        }

        private void LateUpdate()
        {
            if (target == null)
            {
                return;
            }

            ReadLookInput();
            ApplyTransform(false);
        }

        private void ReadLookInput()
        {
            Mouse mouse = Mouse.current;
            if (mouse != null)
            {
                bool dragging = mouse.rightButton.isPressed;
                Vector2 pointer = mouse.position.ReadValue();
                if (dragging && wasDragging)
                {
                    Vector2 delta = pointer - previousPointer;
                    yaw += delta.x * 0.13f;
                    pitch = Mathf.Clamp(pitch - delta.y * 0.1f, 10f, 32f);
                }
                previousPointer = pointer;
                wasDragging = dragging;

                float scroll = mouse.scroll.ReadValue().y;
                if (Mathf.Abs(scroll) > 0.01f)
                {
                    distance = Mathf.Clamp(distance - scroll * 0.006f, 3.2f, 6f);
                }
            }

            Gamepad gamepad = Gamepad.current;
            if (gamepad != null)
            {
                Vector2 look = gamepad.rightStick.ReadValue();
                yaw += look.x * 95f * Time.unscaledDeltaTime;
                pitch = Mathf.Clamp(pitch - look.y * 65f * Time.unscaledDeltaTime, 10f, 32f);
            }

            Keyboard keyboard = Keyboard.current;
            if (keyboard != null)
            {
                if (keyboard.leftArrowKey.isPressed) yaw -= 65f * Time.unscaledDeltaTime;
                if (keyboard.rightArrowKey.isPressed) yaw += 65f * Time.unscaledDeltaTime;
                if (keyboard.upArrowKey.isPressed) pitch = Mathf.Clamp(pitch - 45f * Time.unscaledDeltaTime, 10f, 32f);
                if (keyboard.downArrowKey.isPressed) pitch = Mathf.Clamp(pitch + 45f * Time.unscaledDeltaTime, 10f, 32f);
            }
        }

        private void ApplyTransform(bool immediate)
        {
            if (target == null)
            {
                return;
            }

            Vector3 targetFocus = target.position + Vector3.up * 1.35f;
            smoothFocus = immediate
                ? targetFocus
                : Vector3.Lerp(smoothFocus, targetFocus, 1f - Mathf.Exp(-9f * Time.unscaledDeltaTime));
            Quaternion rotation = Quaternion.Euler(pitch, yaw, 0f);
            Vector3 desiredPosition = smoothFocus - rotation * Vector3.forward * distance;
            Vector3 cameraVector = desiredPosition - smoothFocus;
            float cameraDistance = cameraVector.magnitude;
            if (cameraDistance > 0.01f)
            {
                RaycastHit[] hits = Physics.SphereCastAll(
                    smoothFocus,
                    0.18f,
                    cameraVector / cameraDistance,
                    cameraDistance,
                    Physics.DefaultRaycastLayers,
                    QueryTriggerInteraction.Ignore);
                float nearestDistance = cameraDistance;
                foreach (RaycastHit hit in hits)
                {
                    Transform hitTransform = hit.collider.transform;
                    if (hitTransform == target ||
                        hitTransform.IsChildOf(target) ||
                        target.IsChildOf(hitTransform))
                    {
                        continue;
                    }
                    nearestDistance = Mathf.Min(nearestDistance, hit.distance);
                }
                if (nearestDistance < cameraDistance)
                {
                    desiredPosition = smoothFocus +
                        cameraVector.normalized * Mathf.Max(0.65f, nearestDistance - 0.14f);
                }
            }
            transform.SetPositionAndRotation(desiredPosition, rotation);
        }
    }
}
