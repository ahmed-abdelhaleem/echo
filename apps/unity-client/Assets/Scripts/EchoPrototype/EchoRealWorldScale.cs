using System;
using UnityEngine;

namespace Echo.FreePrototype
{
    [Serializable]
    internal sealed class EchoAssetScaleCatalog
    {
        public int schemaVersion;
        public float playerHeightMeters = 1.78f;
        public float defaultToleranceMeters = 0.04f;
        public EchoAssetScaleProfile[] assets;
    }

    [Serializable]
    internal sealed class EchoAssetScaleProfile
    {
        public string assetId;
        public string category;
        public bool blocksPlayer;
        public float targetLongestMeters;
        public float minimumHeightMeters;
        public float maximumHeightMeters;
    }

    /// <summary>
    /// Runtime evidence attached to every normalized model. Play-mode tests use
    /// this rather than relying on a human to notice scale drift in screenshots.
    /// </summary>
    public sealed class EchoScaleAudit : MonoBehaviour
    {
        public string AssetId { get; private set; }
        public string Category { get; private set; }
        public Vector3 ActualBoundsMeters { get; private set; }
        public float TargetLongestMeters { get; private set; }
        public float MinimumHeightMeters { get; private set; }
        public float MaximumHeightMeters { get; private set; }
        public float ToleranceMeters { get; private set; }
        public bool BlocksPlayer { get; private set; }
        public BoxCollider BlockingCollider { get; private set; }

        internal void Configure(
            string assetId,
            string category,
            Vector3 actualBounds,
            float targetLongest,
            float minimumHeight,
            float maximumHeight,
            float tolerance,
            bool blocksPlayer)
        {
            AssetId = assetId;
            Category = category;
            ActualBoundsMeters = actualBounds;
            TargetLongestMeters = targetLongest;
            MinimumHeightMeters = minimumHeight;
            MaximumHeightMeters = maximumHeight;
            ToleranceMeters = tolerance;
            BlocksPlayer = blocksPlayer;
        }

        internal void SetBlockingCollider(BoxCollider blockingCollider)
        {
            BlockingCollider = blockingCollider;
        }
    }

    internal static class EchoRealWorldScale
    {
        private const string CatalogResourcePath = "Config/real_world_scale_profiles";
        private static EchoAssetScaleCatalog catalog;

        internal static float PlayerHeightMeters => LoadCatalog().playerHeightMeters;

        internal static Bounds NormalizePropAndPlace(
            GameObject instance,
            string assetId,
            Transform sceneRoot,
            Vector3 localPlacement)
        {
            Bounds bounds = VisibleBounds(instance);
            EchoAssetScaleCatalog activeCatalog = LoadCatalog();
            EchoAssetScaleProfile profile = FindProfile(activeCatalog, assetId);
            if (profile == null)
            {
                Debug.LogError(
                    $"[Echo Scale QA] Asset '{assetId}' has no real-world scale profile. " +
                    $"Add it to Resources/{CatalogResourcePath}.json before scene use.");
            }
            else
            {
                float currentLongest = Longest(bounds.size);
                if (currentLongest > 0.0001f && profile.targetLongestMeters > 0f)
                {
                    instance.transform.localScale *= profile.targetLongestMeters / currentLongest;
                    bounds = VisibleBounds(instance);
                }
            }

            Vector3 placement = sceneRoot.TransformPoint(localPlacement);
            Vector3 correction = new(
                placement.x - bounds.center.x,
                placement.y - bounds.min.y,
                placement.z - bounds.center.z);
            instance.transform.position += correction;
            bounds = VisibleBounds(instance);

            if (profile != null)
            {
                EchoScaleAudit audit = instance.AddComponent<EchoScaleAudit>();
                audit.Configure(
                    assetId,
                    profile.category,
                    bounds.size,
                    profile.targetLongestMeters,
                    profile.minimumHeightMeters,
                    profile.maximumHeightMeters,
                    activeCatalog.defaultToleranceMeters,
                    profile.blocksPlayer);
                if (profile.blocksPlayer)
                {
                    audit.SetBlockingCollider(AddBoundsCollider(instance, bounds));
                }
                ReportProfileMismatch(instance.name, audit);
            }

            Debug.Log(
                $"[Echo Scale QA] Placed {instance.name}: bounds {bounds.size}m, " +
                $"floor {placement.y:0.00}m, profile {profile?.category ?? "MISSING"}.");
            return bounds;
        }

        internal static Bounds NormalizeCharacter(GameObject visual, Transform playerRoot)
        {
            Bounds bounds = VisibleBounds(visual);
            float targetHeight = PlayerHeightMeters;
            if (bounds.size.y > 0.0001f)
            {
                visual.transform.localScale *= targetHeight / bounds.size.y;
                bounds = VisibleBounds(visual);
            }

            visual.transform.position +=
                Vector3.up * (playerRoot.position.y - bounds.min.y);
            bounds = VisibleBounds(visual);
            EchoScaleAudit audit = visual.AddComponent<EchoScaleAudit>();
            audit.Configure(
                "player_character",
                "character",
                bounds.size,
                targetHeight,
                targetHeight - 0.03f,
                targetHeight + 0.03f,
                0.03f,
                false);
            Debug.Log(
                $"[Echo Scale QA] Normalized player visual to {bounds.size.y:0.00}m " +
                $"against the {targetHeight:0.00}m reference.");
            return bounds;
        }

        internal static Bounds VisibleBounds(GameObject instance)
        {
            Renderer[] renderers = instance.GetComponentsInChildren<Renderer>(true);
            if (renderers.Length == 0)
            {
                return new Bounds(instance.transform.position, Vector3.zero);
            }

            Bounds bounds = renderers[0].bounds;
            for (int index = 1; index < renderers.Length; index++)
            {
                bounds.Encapsulate(renderers[index].bounds);
            }
            return bounds;
        }

        internal static float Longest(Vector3 size)
        {
            return Mathf.Max(size.x, Mathf.Max(size.y, size.z));
        }

        private static BoxCollider AddBoundsCollider(GameObject instance, Bounds worldBounds)
        {
            GameObject collision = new($"{instance.name}_AutoCollider");
            collision.transform.SetParent(instance.transform.parent, true);
            collision.transform.SetPositionAndRotation(worldBounds.center, Quaternion.identity);
            BoxCollider collider = collision.AddComponent<BoxCollider>();
            // A small horizontal navigation margin prevents the controller's
            // skin width from visually clipping thin or angled silhouettes.
            collider.size = worldBounds.size + new Vector3(0.16f, 0f, 0.16f);
            Debug.Log(
                $"[Echo Scale QA] Collision {collision.name}: " +
                $"center {collider.bounds.center}, size {collider.bounds.size}.");
            return collider;
        }

        private static EchoAssetScaleCatalog LoadCatalog()
        {
            if (catalog != null)
            {
                return catalog;
            }

            TextAsset source = Resources.Load<TextAsset>(CatalogResourcePath);
            if (source == null)
            {
                throw new InvalidOperationException(
                    $"Missing real-world scale catalog at Resources/{CatalogResourcePath}.json.");
            }

            catalog = JsonUtility.FromJson<EchoAssetScaleCatalog>(source.text);
            if (catalog == null || catalog.schemaVersion != 1 || catalog.assets == null)
            {
                throw new InvalidOperationException("Invalid real-world scale profile schema.");
            }
            return catalog;
        }

        private static EchoAssetScaleProfile FindProfile(
            EchoAssetScaleCatalog activeCatalog,
            string assetId)
        {
            foreach (EchoAssetScaleProfile profile in activeCatalog.assets)
            {
                if (string.Equals(profile.assetId, assetId, StringComparison.Ordinal))
                {
                    return profile;
                }
            }
            return null;
        }

        private static void ReportProfileMismatch(string objectName, EchoScaleAudit audit)
        {
            float actualLongest = Longest(audit.ActualBoundsMeters);
            if (Mathf.Abs(actualLongest - audit.TargetLongestMeters) > audit.ToleranceMeters)
            {
                Debug.LogError(
                    $"[Echo Scale QA] {objectName} longest dimension {actualLongest:0.00}m " +
                    $"does not match target {audit.TargetLongestMeters:0.00}m.");
            }
            if (audit.ActualBoundsMeters.y < audit.MinimumHeightMeters ||
                audit.ActualBoundsMeters.y > audit.MaximumHeightMeters)
            {
                Debug.LogError(
                    $"[Echo Scale QA] {objectName} height {audit.ActualBoundsMeters.y:0.00}m " +
                    $"is outside {audit.MinimumHeightMeters:0.00}–" +
                    $"{audit.MaximumHeightMeters:0.00}m; check import orientation.");
            }
        }
    }
}
