using System;
using UnityEditor;

namespace Echo.Editor
{
    /// <summary>
    /// Forces the local Mixamo character downloads to import as Humanoid.
    /// <para>
    /// This has to be an importer rule rather than a checked-in <c>.meta</c> file:
    /// the FBX files under <c>Resources/Characters/</c> are deliberately gitignored
    /// and re-downloaded per machine (see each character's README), so their
    /// <c>.meta</c> is regenerated locally and defaults to Generic.
    /// </para>
    /// <para>
    /// A Generic avatar has no <see cref="HumanBodyBones"/> mapping, so
    /// <c>Animator.isHuman</c> is false and <c>Animator.GetBoneTransform</c> returns
    /// null. That silently disables everything that reaches for a hand: the
    /// interaction rig cannot bind its Two Bone IK constraints at all, and the older
    /// action director falls back to a fixed offset from the character root — which
    /// is exactly why props read as floating rather than held.
    /// </para>
    /// </summary>
    public sealed class EchoCharacterImportSettings : AssetPostprocessor
    {
        private const string CharacterRoot = "Assets/Resources/Characters/";

        private void OnPreprocessModel()
        {
            if (!assetPath.StartsWith(CharacterRoot, StringComparison.Ordinal))
            {
                return;
            }

            ModelImporter importer = assetImporter as ModelImporter;
            if (importer == null || importer.animationType == ModelImporterAnimationType.Human)
            {
                return;
            }

            importer.animationType = ModelImporterAnimationType.Human;
            // Mixamo rigs follow a conventional humanoid naming scheme, so Unity's
            // own auto-mapping resolves them without a hand-authored avatar.
            importer.avatarSetup = ModelImporterAvatarSetup.CreateFromThisModel;
            importer.importAnimation = true;
        }
    }
}
