using UnityEngine;
using UnityEngine.InputSystem;

namespace Echo.FreePrototype
{
    /// <summary>
    /// A calm, bounded orbit camera for Echo's explorable diorama scenes.
    /// Right-drag or use the arrow keys to look around; scroll to zoom.
    /// </summary>
    public sealed class EchoOrbitCamera : MonoBehaviour
    {
        private Vector3 target = new(0f, 1.8f, 4.5f);
        private float yaw;
        private float pitch = 17f;
        private float distance = 15.5f;
        private float targetYaw;
        private float targetPitch = 17f;
        private float targetDistance = 15.5f;
        private float defaultYaw;
        private float defaultPitch = 17f;
        private float defaultDistance = 15.5f;
        private bool wasDragging;
        private Vector2 previousPointer;
        private float idleTime;

        public void Configure(Vector3 focusPoint, float startYaw, float startPitch, float startDistance)
        {
            target = focusPoint;
            yaw = targetYaw = startYaw;
            pitch = targetPitch = startPitch;
            distance = targetDistance = startDistance;
            defaultYaw = startYaw;
            defaultPitch = startPitch;
            defaultDistance = startDistance;
            ApplyTransform();
        }

        private void Update()
        {
            HandlePointer();
            HandleKeyboard();

            idleTime += Time.unscaledDeltaTime;
            if (idleTime > 4f && !wasDragging)
            {
                targetYaw = Mathf.Sin(Time.unscaledTime * 0.11f) * 9f;
            }

            yaw = Mathf.LerpAngle(yaw, targetYaw, 1f - Mathf.Exp(-5f * Time.unscaledDeltaTime));
            pitch = Mathf.Lerp(pitch, targetPitch, 1f - Mathf.Exp(-5f * Time.unscaledDeltaTime));
            distance = Mathf.Lerp(distance, targetDistance, 1f - Mathf.Exp(-5f * Time.unscaledDeltaTime));
            ApplyTransform();
        }

        private void HandlePointer()
        {
            Mouse mouse = Mouse.current;
            if (mouse == null)
            {
                return;
            }

            bool isDragging = mouse.rightButton.isPressed;
            Vector2 pointer = mouse.position.ReadValue();
            if (isDragging && wasDragging)
            {
                Vector2 delta = pointer - previousPointer;
                targetYaw = Mathf.Clamp(targetYaw + delta.x * 0.12f, -30f, 30f);
                targetPitch = Mathf.Clamp(targetPitch - delta.y * 0.1f, 8f, 28f);
                idleTime = 0f;
            }

            float scroll = mouse.scroll.ReadValue().y;
            if (Mathf.Abs(scroll) > 0.01f)
            {
                targetDistance = Mathf.Clamp(targetDistance - scroll * 0.008f, 11.5f, 19f);
                idleTime = 0f;
            }

            previousPointer = pointer;
            wasDragging = isDragging;
        }

        private void HandleKeyboard()
        {
            Keyboard keyboard = Keyboard.current;
            if (keyboard == null)
            {
                return;
            }

            float horizontal = 0f;
            float vertical = 0f;
            if (keyboard.leftArrowKey.isPressed || keyboard.aKey.isPressed) horizontal -= 1f;
            if (keyboard.rightArrowKey.isPressed || keyboard.dKey.isPressed) horizontal += 1f;
            if (keyboard.upArrowKey.isPressed || keyboard.wKey.isPressed) vertical += 1f;
            if (keyboard.downArrowKey.isPressed || keyboard.sKey.isPressed) vertical -= 1f;

            if (Mathf.Abs(horizontal) + Mathf.Abs(vertical) > 0f)
            {
                targetYaw = Mathf.Clamp(targetYaw + horizontal * 26f * Time.unscaledDeltaTime, -30f, 30f);
                targetPitch = Mathf.Clamp(targetPitch + vertical * 18f * Time.unscaledDeltaTime, 8f, 28f);
                idleTime = 0f;
            }

            if (keyboard.rKey.wasPressedThisFrame)
            {
                targetYaw = defaultYaw;
                targetPitch = defaultPitch;
                targetDistance = defaultDistance;
                idleTime = 0f;
            }
        }

        private void ApplyTransform()
        {
            Quaternion rotation = Quaternion.Euler(pitch, yaw, 0f);
            transform.SetPositionAndRotation(target - rotation * Vector3.forward * distance, rotation);
        }
    }
}
