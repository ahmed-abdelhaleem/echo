using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using Echo.FreePrototype;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;

namespace Echo.Editor
{
    /// <summary>
    /// Renders the interaction review takes the acceptance gate runs over.
    ///
    /// This is the Unity half of <c>make unity-capture-interactions</c>: it builds
    /// the interaction lab once per take, steps it at a fixed timestep, writes a
    /// PNG per frame and a <c>metrics.json</c> beside them. Everything after that —
    /// H.264 encoding, contact sheets and the gates themselves — belongs to
    /// <c>tools/capture/encode_interaction_capture.py</c>, which keeps the project
    /// free of <c>com.unity.recorder</c> and lets the gate run without a GPU.
    ///
    /// Determinism is the point of the whole path. The frame step is fixed, the
    /// random seed is fixed, nothing reads a wall clock, and every number written
    /// out uses an invariant fixed-decimal format. Two runs over the same commit
    /// must produce identical bytes, because the contact sheets are committed as
    /// golden images and a jittering capture would make them worthless.
    /// </summary>
    public static class EchoInteractionCapture
    {
        /// <summary>Command line flag selecting the take matrix; "fast" or "full".</summary>
        private const string MatrixArgument = "-echoCaptureMatrix";

        /// <summary>Command line flag carrying the absolute capture root.</summary>
        private const string RootArgument = "-echoCaptureRoot";

        private const string FastMatrix = "fast";
        private const string FullMatrix = "full";

        /// <summary>The prop the per-commit subset films; it is the reference.</summary>
        private const string FastInteractionId = "photograph";

        /// <summary>The character every take is filmed with, so takes stay comparable.</summary>
        private const string CaptureCharacterId = "YBot";

        private const int CaptureWidth = 1280;
        private const int CaptureHeight = 720;

        /// <summary>Fixed seed; no capture output may depend on when it was run.</summary>
        private const int DeterministicSeed = 20260101;

        /// <summary>Runaway guard. The longest authored interaction is ~5.5 s.</summary>
        private const int MaxFramesPerTake = 5000;

        private const int FastFrameRate = 60;
        private const int FastCameraPitchDegrees = 10;

        private static readonly int[] FastCameraYawsDegrees = { 315, 0, 45 };
        private static readonly int[] FullCameraYawsDegrees =
        {
            0, 45, 90, 135, 180, 225, 270, 315
        };
        private static readonly int[] FullCameraPitchesDegrees = { 0, 10, 25 };
        private static readonly int[] FullFrameRates = { 30, 60, 120 };

        private static readonly EchoCaptureZoom[] Zooms =
        {
            new("near", 0.9f),
            new("mid", 1.6f),
            new("far", 2.6f)
        };

        private static readonly EchoCaptureZoom MidZoom = Zooms[1];

        /// <summary>
        /// Batch entry point invoked by the Makefile as
        /// <c>-executeMethod Echo.Editor.EchoInteractionCapture.CaptureFromCommandLine</c>
        /// with <c>-echoCaptureMatrix</c> and <c>-echoCaptureRoot</c>.
        ///
        /// It always exits the editor explicitly. A capture that produced no takes,
        /// or a take that failed halfway, must fail the Make target loudly: an empty
        /// capture root reads to the gate exactly like a passing run.
        /// </summary>
        public static void CaptureFromCommandLine()
        {
            int exitCode;
            try
            {
                string matrix = ReadArgument(MatrixArgument, FastMatrix);
                string root = ReadArgument(RootArgument, string.Empty);
                exitCode = Capture(matrix, root);
            }
            catch (Exception error)
            {
                Debug.LogError($"[Echo Capture] The capture run failed: {error}");
                exitCode = 1;
            }

            EditorApplication.Exit(exitCode);
        }

        /// <summary>
        /// Runs a whole matrix into a capture root.
        /// </summary>
        /// <param name="matrix">"fast" for the per-commit subset, "full" for review.</param>
        /// <param name="root">Absolute capture root; <c>takes/</c> is created under it.</param>
        /// <returns>Zero when every take was rendered and measured.</returns>
        public static int Capture(string matrix, string root)
        {
            if (string.IsNullOrEmpty(root))
            {
                Debug.LogError(
                    $"[Echo Capture] {RootArgument} is required and must be an absolute path.");
                return 2;
            }

            string selectedMatrix = string.IsNullOrEmpty(matrix)
                ? FastMatrix
                : matrix.ToLowerInvariant();
            if (selectedMatrix != FastMatrix && selectedMatrix != FullMatrix)
            {
                Debug.LogError(
                    $"[Echo Capture] {MatrixArgument} '{matrix}' is not one of " +
                    $"{FastMatrix}, {FullMatrix}.");
                return 2;
            }

            EchoCaptureEnvironment environment = EchoCaptureEnvironment.Capture();
            RenderTexture target = null;
            Texture2D readback = null;
            int renderedTakes = 0;
            try
            {
                List<EchoCaptureTake> takes = BuildTakes(selectedMatrix);
                if (takes.Count == 0)
                {
                    throw new EchoCaptureException(
                        $"the '{selectedMatrix}' matrix produced no takes; there is nothing " +
                        "for the acceptance gate to read.");
                }

                string takesRoot = Path.Combine(root, "takes");
                Directory.CreateDirectory(takesRoot);
                WarnAboutHeadlessRendering();
                Debug.Log(
                    $"[Echo Capture] matrix '{selectedMatrix}': {takes.Count} take(s) into {root}");

                environment.ApplyDeterministicDefaults();
                target = new RenderTexture(
                    CaptureWidth,
                    CaptureHeight,
                    24,
                    RenderTextureFormat.ARGB32)
                {
                    name = "EchoInteractionCaptureTarget",
                    antiAliasing = 1
                };
                readback = new Texture2D(CaptureWidth, CaptureHeight, TextureFormat.RGB24, false);

                foreach (EchoCaptureTake take in takes)
                {
                    RunTake(take, takesRoot, target, readback);
                    renderedTakes++;
                }

                Debug.Log($"[Echo Capture] {renderedTakes} take(s) written under {takesRoot}");
            }
            catch (EchoCaptureException failure)
            {
                Debug.LogError($"[Echo Capture] {failure.Message}");
                return 1;
            }
            finally
            {
                environment.Restore();
                DestroyIfPresent(readback);
                DestroyIfPresent(target);
            }

            return 0;
        }

        /// <summary>
        /// Expands a matrix name into its ordered take list. The order is a pure
        /// function of the authored catalog and the constants above, so the same
        /// matrix always yields the same takes in the same order.
        /// </summary>
        /// <param name="matrix">"fast" or "full", already lower-cased.</param>
        /// <returns>The takes to render, in render order.</returns>
        private static List<EchoCaptureTake> BuildTakes(string matrix)
        {
            List<EchoCaptureTake> takes = new();
            if (matrix == FastMatrix)
            {
                EchoInteractionProfile profile =
                    EchoInteractionProfileCatalog.Find(FastInteractionId);
                if (profile == null)
                {
                    throw new EchoCaptureException(
                        $"the catalog has no '{FastInteractionId}' profile, so the fast matrix " +
                        "cannot be built.");
                }

                float frontApproach = profile.approachYawDegrees[0];
                foreach (int yaw in FastCameraYawsDegrees)
                {
                    takes.Add(new EchoCaptureTake(
                        profile.interactionId,
                        frontApproach,
                        yaw,
                        FastCameraPitchDegrees,
                        MidZoom,
                        FastFrameRate));
                }
                return takes;
            }

            foreach (EchoInteractionProfile profile in EchoInteractionProfileCatalog.All)
            {
                foreach (float approach in profile.approachYawDegrees)
                {
                    foreach (int yaw in FullCameraYawsDegrees)
                    {
                        foreach (int pitch in FullCameraPitchesDegrees)
                        {
                            foreach (EchoCaptureZoom zoom in Zooms)
                            {
                                foreach (int frameRate in FullFrameRates)
                                {
                                    takes.Add(new EchoCaptureTake(
                                        profile.interactionId,
                                        approach,
                                        yaw,
                                        pitch,
                                        zoom,
                                        frameRate));
                                }
                            }
                        }
                    }
                }
            }
            return takes;
        }

        /// <summary>
        /// Builds the lab, runs one interaction, and writes the frames and metrics.
        ///
        /// The lab is rebuilt into a fresh empty scene for every take rather than
        /// reset between takes, because a reset that misses one field would leak
        /// state from the previous take and quietly break reproducibility.
        /// </summary>
        /// <param name="take">The take to render.</param>
        /// <param name="takesRoot">Absolute path of the capture root's takes folder.</param>
        /// <param name="target">Shared render target the camera draws into.</param>
        /// <param name="readback">Shared CPU texture the target is read back into.</param>
        private static void RunTake(
            EchoCaptureTake take,
            string takesRoot,
            RenderTexture target,
            Texture2D readback)
        {
            string takeId = take.TakeId;
            string takeDirectory = Path.Combine(takesRoot, takeId);
            Directory.CreateDirectory(takeDirectory);

            float frameDeltaSeconds = 1f / take.FrameRate;
            Time.captureDeltaTime = frameDeltaSeconds;
            Time.fixedDeltaTime = frameDeltaSeconds;
            Time.maximumDeltaTime = frameDeltaSeconds;
            UnityEngine.Random.InitState(DeterministicSeed);

            EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);

            EchoInteractionLab lab = EchoInteractionLab.Build(
                CaptureCharacterId,
                take.InteractionId);
            if (lab == null)
            {
                throw new EchoCaptureException(
                    $"take '{takeId}': the interaction lab failed to build.");
            }

            EchoInteractionMetricsRecorder recorder = null;
            try
            {
                if (!lab.IsReady)
                {
                    throw new EchoCaptureException(
                        $"take '{takeId}': the lab is not ready for '{take.InteractionId}' on " +
                        $"'{CaptureCharacterId}'.");
                }

                if (!lab.SetApproachYawDegrees(take.ApproachYawDegrees))
                {
                    throw new EchoCaptureException(
                        $"take '{takeId}': the lab could not place the character on " +
                        $"approach yaw {take.ApproachYawDegrees:0.0} degrees.");
                }

                lab.SetCameraPose(
                    take.CameraYawDegrees,
                    take.CameraPitchDegrees,
                    take.CameraDistanceMeters);

                Camera camera = ResolveCamera(takeId);
                EchoInteractionCoordinator coordinator =
                    ResolveSingle<EchoInteractionCoordinator>(takeId);
                EchoCharacterInteractionRig rig =
                    ResolveSingle<EchoCharacterInteractionRig>(takeId);
                EchoHeroProp prop = ResolveProp(take.InteractionId, takeId);

                GameObject recorderHost = new("EchoInteractionMetricsRecorder");
                recorder = recorderHost.AddComponent<EchoInteractionMetricsRecorder>();
                recorder.BeginTake(coordinator, prop, rig, takeId, frameDeltaSeconds);
                if (!recorder.IsRecording)
                {
                    throw new EchoCaptureException(
                        $"take '{takeId}': the metrics recorder refused the take; see the errors " +
                        "above. An unmeasured take reads to the gate like a passing one.");
                }

                int frameIndex = RunFrames(takeId, lab, camera, target, readback, takeDirectory);
                recorder.EndTake();

                if (frameIndex == 0)
                {
                    throw new EchoCaptureException(
                        $"take '{takeId}': the interaction produced no frames.");
                }

                if (recorder.FrameCount == 0)
                {
                    throw new EchoCaptureException(
                        $"take '{takeId}': {frameIndex} frame(s) rendered but the rig never " +
                        "evaluated, so nothing was measured.");
                }

                File.WriteAllText(
                    Path.Combine(takeDirectory, "metrics.json"),
                    recorder.ToJson(),
                    new UTF8Encoding(false));
                Debug.Log(
                    $"[Echo Capture] {takeId}: {frameIndex} frame(s), " +
                    $"{recorder.FrameCount} sample(s)");
            }
            finally
            {
                if (recorder != null)
                {
                    recorder.EndTake();
                }
                DestroyIfPresent(lab.gameObject);
            }
        }

        /// <summary>
        /// Steps the interaction one frame at a time and photographs each step.
        ///
        /// The routine is pumped by hand rather than started as a coroutine so the
        /// capture, not the engine, decides when a frame is finished and safe to
        /// read back. Each <c>MoveNext</c> is exactly one frame of
        /// <c>Time.captureDeltaTime</c>.
        /// </summary>
        /// <returns>How many frames were written.</returns>
        private static int RunFrames(
            string takeId,
            EchoInteractionLab lab,
            Camera camera,
            RenderTexture target,
            Texture2D readback,
            string takeDirectory)
        {
            if (!lab.BeginInteraction())
            {
                throw new EchoCaptureException(
                    $"take '{takeId}': the lab refused to begin the interaction.");
            }

            int frameIndex = 0;
            while (lab.IsInteractionRunning)
            {
                lab.Tick(Time.captureDeltaTime > 0f ? Time.captureDeltaTime : (1f / 60f));
                WriteFrame(camera, target, readback, takeDirectory, frameIndex);
                frameIndex++;
                if (frameIndex >= MaxFramesPerTake)
                {
                    throw new EchoCaptureException(
                        $"take '{takeId}': the interaction did not finish within " +
                        $"{MaxFramesPerTake} frames.");
                }
            }
            return frameIndex;
        }

        /// <summary>
        /// Renders one frame and writes it as <c>frame_%05d.png</c>. The readback
        /// runs immediately after the render so the pixels belong to the pose the
        /// metrics recorder sampled on the same frame.
        /// </summary>
        private static void WriteFrame(
            Camera camera,
            RenderTexture target,
            Texture2D readback,
            string takeDirectory,
            int frameIndex)
        {
            RenderInto(camera, target);

            RenderTexture previousActive = RenderTexture.active;
            try
            {
                RenderTexture.active = target;
                readback.ReadPixels(new Rect(0f, 0f, CaptureWidth, CaptureHeight), 0, 0, false);
                readback.Apply(false);
            }
            finally
            {
                RenderTexture.active = previousActive;
            }

            string index = frameIndex.ToString("00000", CultureInfo.InvariantCulture);
            string fileName = "frame_" + index + ".png";
            File.WriteAllBytes(Path.Combine(takeDirectory, fileName), readback.EncodeToPNG());
        }

        /// <summary>
        /// Draws one camera into the capture target. The project renders through
        /// URP, so the render request path is the supported way to draw a camera on
        /// demand; the direct <c>Camera.Render</c> call is kept as the fallback for
        /// a configuration with no scriptable pipeline active.
        /// </summary>
        private static void RenderInto(Camera camera, RenderTexture target)
        {
            RenderPipeline.StandardRequest request = new() { destination = target };
            if (RenderPipeline.SupportsRenderRequest(camera, request))
            {
                RenderPipeline.SubmitRenderRequest(camera, request);
                return;
            }

            RenderTexture previousTarget = camera.targetTexture;
            try
            {
                camera.targetTexture = target;
                camera.Render();
            }
            finally
            {
                camera.targetTexture = previousTarget;
            }
        }

        private static Camera ResolveCamera(string takeId)
        {
            Camera camera = Camera.main;
            if (camera != null)
            {
                return camera;
            }

            Camera[] cameras = UnityEngine.Object.FindObjectsByType<Camera>(
                FindObjectsInactive.Exclude);
            if (cameras.Length == 0)
            {
                throw new EchoCaptureException($"take '{takeId}': the lab scene has no camera.");
            }
            return cameras[0];
        }

        /// <summary>
        /// Finds the one component of a type the lab scene is expected to contain.
        /// Looking the components up in the scene rather than through lab properties
        /// keeps the surface this file depends on to the handful of lab methods it
        /// actually calls.
        /// </summary>
        private static TComponent ResolveSingle<TComponent>(string takeId)
            where TComponent : Component
        {
            TComponent[] found = UnityEngine.Object.FindObjectsByType<TComponent>(
                FindObjectsInactive.Include);
            if (found.Length == 0)
            {
                throw new EchoCaptureException(
                    $"take '{takeId}': the lab scene has no {typeof(TComponent).Name}.");
            }
            if (found.Length > 1)
            {
                Debug.LogWarning(
                    $"[Echo Capture] take '{takeId}': the lab scene has {found.Length} " +
                    $"{typeof(TComponent).Name} components; the first one was measured.");
            }
            return found[0];
        }

        private static EchoHeroProp ResolveProp(string interactionId, string takeId)
        {
            EchoHeroProp[] props = UnityEngine.Object.FindObjectsByType<EchoHeroProp>(
                FindObjectsInactive.Include);
            foreach (EchoHeroProp candidate in props)
            {
                if (candidate.Profile != null &&
                    string.Equals(
                        candidate.Profile.interactionId,
                        interactionId,
                        StringComparison.Ordinal))
                {
                    return candidate;
                }
            }

            throw new EchoCaptureException(
                $"take '{takeId}': the lab scene has no configured hero prop for " +
                $"'{interactionId}' (found {props.Length} prop(s)).");
        }

        /// <summary>
        /// Says so once when the editor has no graphics device. The metrics are still
        /// valid without one — they are measured off transforms, not pixels — but the
        /// PNGs will be blank, so a reviewer must not read a black contact sheet as a
        /// broken interaction.
        /// </summary>
        private static void WarnAboutHeadlessRendering()
        {
            if (SystemInfo.graphicsDeviceType == GraphicsDeviceType.Null)
            {
                Debug.LogWarning(
                    "[Echo Capture] The editor is running without a graphics device, so the " +
                    "rendered frames will be blank. The acceptance metrics are unaffected; the " +
                    "review video is not usable from this run.");
            }
        }

        /// <summary>
        /// Reads one custom command line flag's value.
        /// </summary>
        /// <param name="flag">The flag, including its leading dash.</param>
        /// <param name="fallback">Value to use when the flag is absent or has no value.</param>
        /// <returns>The flag's value, or the fallback.</returns>
        private static string ReadArgument(string flag, string fallback)
        {
            string[] arguments = Environment.GetCommandLineArgs();
            for (int index = 0; index < arguments.Length - 1; index++)
            {
                if (string.Equals(arguments[index], flag, StringComparison.Ordinal))
                {
                    return arguments[index + 1];
                }
            }
            return fallback;
        }

        private static void DestroyIfPresent(UnityEngine.Object target)
        {
            if (target != null)
            {
                UnityEngine.Object.DestroyImmediate(target);
            }
        }

        /// <summary>A capture take could not be rendered or measured.</summary>
        private sealed class EchoCaptureException : Exception
        {
            /// <summary>Creates the failure with the message the batch log will carry.</summary>
            /// <param name="message">Why the take failed.</param>
            public EchoCaptureException(string message)
                : base(message)
            {
            }
        }

        /// <summary>One camera distance and the name it appears under in a take id.</summary>
        private readonly struct EchoCaptureZoom
        {
            /// <summary>Filesystem-safe zoom name, one of "near", "mid", "far".</summary>
            public readonly string Label;

            /// <summary>Distance from the framed interaction to the camera, in metres.</summary>
            public readonly float DistanceMeters;

            /// <summary>Creates a zoom step.</summary>
            /// <param name="label">Zoom name used in the take id.</param>
            /// <param name="distanceMeters">Camera distance in metres.</param>
            public EchoCaptureZoom(string label, float distanceMeters)
            {
                Label = label;
                DistanceMeters = distanceMeters;
            }
        }

        /// <summary>
        /// One rendered take: which prop, from which approach, seen from which
        /// camera pose, at which frame rate. Everything a take id has to be
        /// self-describing about lives here.
        /// </summary>
        private readonly struct EchoCaptureTake
        {
            /// <summary>Catalog interaction id, e.g. "photograph".</summary>
            public readonly string InteractionId;

            /// <summary>Approach direction the character stands on, in degrees.</summary>
            public readonly float ApproachYawDegrees;

            /// <summary>Camera orbit yaw about the interaction, in degrees.</summary>
            public readonly int CameraYawDegrees;

            /// <summary>Camera orbit pitch above the interaction, in degrees.</summary>
            public readonly int CameraPitchDegrees;

            /// <summary>Camera distance in metres.</summary>
            public readonly float CameraDistanceMeters;

            /// <summary>Captured frames per second.</summary>
            public readonly int FrameRate;

            private readonly string zoomLabel;

            /// <summary>Creates a take description.</summary>
            /// <param name="interactionId">Catalog interaction id.</param>
            /// <param name="approachYawDegrees">Approach the character stands on.</param>
            /// <param name="cameraYawDegrees">Camera orbit yaw.</param>
            /// <param name="cameraPitchDegrees">Camera orbit pitch.</param>
            /// <param name="zoom">Camera distance step.</param>
            /// <param name="frameRate">Captured frames per second.</param>
            public EchoCaptureTake(
                string interactionId,
                float approachYawDegrees,
                int cameraYawDegrees,
                int cameraPitchDegrees,
                EchoCaptureZoom zoom,
                int frameRate)
            {
                InteractionId = interactionId;
                ApproachYawDegrees = approachYawDegrees;
                CameraYawDegrees = cameraYawDegrees;
                CameraPitchDegrees = cameraPitchDegrees;
                CameraDistanceMeters = zoom.DistanceMeters;
                FrameRate = frameRate;
                zoomLabel = zoom.Label;
            }

            /// <summary>
            /// The take's folder name, e.g.
            /// <c>photograph_front_yaw045_pitch10_mid_60fps</c>. Lower case, ASCII
            /// and free of separators, so it is safe as a directory name, as an
            /// ffmpeg input pattern and as a committed golden file name.
            /// </summary>
            public string TakeId
            {
                get
                {
                    return string.Concat(
                        Sanitize(InteractionId),
                        "_",
                        ApproachTag,
                        "_yaw",
                        CameraYawDegrees.ToString("000", CultureInfo.InvariantCulture),
                        "_pitch",
                        CameraPitchDegrees.ToString("00", CultureInfo.InvariantCulture),
                        "_",
                        zoomLabel,
                        "_",
                        FrameRate.ToString(CultureInfo.InvariantCulture),
                        "fps");
                }
            }

            /// <summary>
            /// Names the approach: "front" for the head-on direction, otherwise the
            /// side the character stands on and by how many degrees. Negative
            /// approach yaws are the character's left of the prop's facing.
            /// </summary>
            private string ApproachTag
            {
                get
                {
                    int rounded = Mathf.RoundToInt(ApproachYawDegrees);
                    if (rounded == 0)
                    {
                        return "front";
                    }

                    string side = rounded < 0 ? "left" : "right";
                    return side + Mathf.Abs(rounded).ToString("000", CultureInfo.InvariantCulture);
                }
            }

            private static string Sanitize(string value)
            {
                if (string.IsNullOrEmpty(value))
                {
                    return "unknown";
                }

                StringBuilder safe = new(value.Length);
                foreach (char character in value)
                {
                    bool allowed = (character >= 'a' && character <= 'z') ||
                        (character >= 'A' && character <= 'Z') ||
                        (character >= '0' && character <= '9') ||
                        character == '-';
                    safe.Append(allowed ? char.ToLowerInvariant(character) : '_');
                }
                return safe.ToString();
            }
        }

        /// <summary>
        /// The engine settings the capture overwrites, and how to put them back.
        /// The editor keeps running after a batch capture in an interactive session,
        /// so leaving a 120 fps capture step installed would silently change how
        /// every later play-mode session behaves.
        /// </summary>
        private readonly struct EchoCaptureEnvironment
        {
            private readonly float captureDeltaTime;
            private readonly float fixedDeltaTime;
            private readonly float maximumDeltaTime;
            private readonly int vSyncCount;

            private EchoCaptureEnvironment(
                float captureDeltaTime,
                float fixedDeltaTime,
                float maximumDeltaTime,
                int vSyncCount)
            {
                this.captureDeltaTime = captureDeltaTime;
                this.fixedDeltaTime = fixedDeltaTime;
                this.maximumDeltaTime = maximumDeltaTime;
                this.vSyncCount = vSyncCount;
            }

            /// <summary>Snapshots the settings the capture is about to overwrite.</summary>
            /// <returns>The snapshot to hand to <see cref="Restore"/>.</returns>
            public static EchoCaptureEnvironment Capture()
            {
                return new EchoCaptureEnvironment(
                    Time.captureDeltaTime,
                    Time.fixedDeltaTime,
                    Time.maximumDeltaTime,
                    QualitySettings.vSyncCount);
            }

            /// <summary>
            /// Installs the settings every take shares. The per-take frame step is
            /// applied separately, because the frame rate is a matrix dimension.
            /// Physics transform sync is requested explicitly at measurement points,
            /// rather than through a global auto-sync mode.
            /// </summary>
            public void ApplyDeterministicDefaults()
            {
                QualitySettings.vSyncCount = 0;
                UnityEngine.Random.InitState(DeterministicSeed);
            }

            /// <summary>Puts every overwritten setting back.</summary>
            public void Restore()
            {
                Time.captureDeltaTime = captureDeltaTime;
                Time.fixedDeltaTime = fixedDeltaTime;
                Time.maximumDeltaTime = maximumDeltaTime;
                QualitySettings.vSyncCount = vSyncCount;
            }
        }
    }
}
