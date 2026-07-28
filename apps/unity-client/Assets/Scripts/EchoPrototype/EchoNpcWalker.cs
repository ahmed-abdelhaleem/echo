using UnityEngine;

namespace Echo.FreePrototype
{
    /// <summary>
    /// Lightweight ambient NPC motion. It deliberately stays simple and looping:
    /// characters make the place feel inhabited without turning Echo into a crowd simulation.
    /// </summary>
    public sealed class EchoNpcWalker : MonoBehaviour
    {
        private Vector3 origin;
        private Vector3 axis;
        private float distance;
        private float speed;
        private float phase;
        private Transform leftArm;
        private Transform rightArm;
        private Transform leftLeg;
        private Transform rightLeg;

        public void Configure(
            Vector3 movementAxis,
            float movementDistance,
            float movementSpeed,
            float movementPhase,
            Transform armLeft,
            Transform armRight,
            Transform legLeft,
            Transform legRight)
        {
            origin = transform.position;
            axis = movementAxis.normalized;
            distance = movementDistance;
            speed = movementSpeed;
            phase = movementPhase;
            leftArm = armLeft;
            rightArm = armRight;
            leftLeg = legLeft;
            rightLeg = legRight;
        }

        private void Update()
        {
            float cycle = Time.time * speed + phase;
            float travel = Mathf.Sin(cycle);
            transform.position = origin + axis * travel * distance;

            Vector3 facing = axis * Mathf.Sign(Mathf.Cos(cycle));
            if (facing.sqrMagnitude > 0.01f)
            {
                transform.rotation = Quaternion.Slerp(
                    transform.rotation,
                    Quaternion.LookRotation(facing, Vector3.up),
                    Time.deltaTime * 4f);
            }

            float stride = Mathf.Sin(cycle * 4f) * 22f;
            if (leftArm != null) leftArm.localRotation = Quaternion.Euler(stride, 0f, 5f);
            if (rightArm != null) rightArm.localRotation = Quaternion.Euler(-stride, 0f, -5f);
            if (leftLeg != null) leftLeg.localRotation = Quaternion.Euler(-stride, 0f, 0f);
            if (rightLeg != null) rightLeg.localRotation = Quaternion.Euler(stride, 0f, 0f);
        }
    }
}
