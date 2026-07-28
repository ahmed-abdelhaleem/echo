using System;
using UnityEngine;

namespace Echo.FreePrototype
{
    /// <summary>
    /// Deterministic, royalty-free rain/room tone generated at runtime.
    /// It keeps the free vertical slice alive without bundling an opaque audio asset.
    /// </summary>
    public sealed class EchoBedroomAmbience : MonoBehaviour
    {
        private const int SampleRate = 22050;
        private const int DurationSeconds = 8;

        private AudioSource source;

        private void Awake()
        {
            source = gameObject.AddComponent<AudioSource>();
            source.name = "Bedroom_RainRoomTone";
            source.loop = true;
            source.playOnAwake = false;
            source.spatialBlend = 0f;
            source.volume = 0.16f;
            source.clip = BuildRainLoop();
        }

        private void OnEnable()
        {
            if (source != null && source.clip != null && !source.isPlaying)
            {
                source.Play();
            }
        }

        private void OnDisable()
        {
            source?.Pause();
        }

        private static AudioClip BuildRainLoop()
        {
            int sampleCount = SampleRate * DurationSeconds;
            float[] samples = new float[sampleCount];
            System.Random random = new(1847);
            float filteredNoise = 0f;
            for (int index = 0; index < sampleCount; index++)
            {
                float whiteNoise = (float)(random.NextDouble() * 2.0 - 1.0);
                filteredNoise = Mathf.Lerp(filteredNoise, whiteNoise, 0.035f);
                float time = index / (float)SampleRate;
                float slowWindow = 0.82f + Mathf.Sin(time * 0.71f) * 0.12f;
                samples[index] = filteredNoise * 0.24f * slowWindow;
            }

            AddDrop(samples, 0.72f, 0.32f);
            AddDrop(samples, 2.15f, 0.24f);
            AddDrop(samples, 3.91f, 0.29f);
            AddDrop(samples, 5.46f, 0.2f);
            AddDrop(samples, 7.18f, 0.26f);

            AudioClip clip = AudioClip.Create(
                "Echo_RainRoomTone",
                sampleCount,
                1,
                SampleRate,
                false);
            clip.SetData(samples, 0);
            return clip;
        }

        private static void AddDrop(float[] samples, float startSeconds, float amplitude)
        {
            int start = Mathf.RoundToInt(startSeconds * SampleRate);
            int length = Mathf.RoundToInt(0.085f * SampleRate);
            for (int offset = 0; offset < length && start + offset < samples.Length; offset++)
            {
                float progress = offset / (float)length;
                float envelope = Mathf.Pow(1f - progress, 3f);
                samples[start + offset] +=
                    Mathf.Sin(progress * Mathf.PI * 18f) * envelope * amplitude;
            }
        }
    }
}
