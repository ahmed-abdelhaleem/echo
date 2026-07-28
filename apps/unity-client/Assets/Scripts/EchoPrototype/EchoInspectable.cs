using UnityEngine;

namespace Echo.FreePrototype
{
    /// <summary>
    /// A noticing point in an Echo diorama. Observations are optional flavor and
    /// intentionally carry no scoring or gameplay consequence.
    /// </summary>
    public sealed class EchoInspectable : MonoBehaviour
    {
        public string Observation { get; private set; }

        public void Configure(string observation)
        {
            Observation = observation;
        }
    }
}
