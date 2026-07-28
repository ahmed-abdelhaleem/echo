using System;
using UnityEditor;
using UnityEditor.Build.Reporting;

namespace Echo.Editor
{
    public static class EchoBuild
    {
        private const string ScenePath = "Assets/Scenes/SampleScene.unity";
        private const string MacOutputPath = "Builds/macOS/Echo.app";

        public static void BuildMacOS()
        {
            BuildPlayerOptions options = new()
            {
                scenes = new[] { ScenePath },
                locationPathName = MacOutputPath,
                target = BuildTarget.StandaloneOSX,
                options = BuildOptions.None
            };

            BuildReport report = BuildPipeline.BuildPlayer(options);
            if (report.summary.result != BuildResult.Succeeded)
            {
                throw new InvalidOperationException(
                    $"Echo macOS build failed: {report.summary.result}, {report.summary.totalErrors} error(s).");
            }

            UnityEngine.Debug.Log(
                $"[Echo] macOS build completed at {MacOutputPath} " +
                $"({report.summary.totalSize} bytes in {report.summary.totalTime}).");
        }
    }
}
