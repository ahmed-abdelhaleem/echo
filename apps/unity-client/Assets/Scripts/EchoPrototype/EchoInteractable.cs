using UnityEngine;

namespace Echo.FreePrototype
{
    /// <summary>
    /// A contextual interaction anchor for a playable vignette.
    /// The anchor is separate from visual mesh complexity and collision.
    /// </summary>
    public sealed class EchoInteractable : MonoBehaviour
    {
        public string Id { get; private set; }
        public string Prompt { get; private set; }
        public string Observation { get; private set; }
        public int UnlockStage { get; private set; }
        public bool IsOptional { get; private set; }

        public void Configure(
            string id,
            string prompt,
            string observation,
            int unlockStage,
            bool isOptional)
        {
            Id = id;
            Prompt = prompt;
            Observation = observation;
            UnlockStage = unlockStage;
            IsOptional = isOptional;
        }

        public bool IsAvailable(int currentStage)
        {
            return IsOptional || currentStage >= UnlockStage;
        }
    }
}
