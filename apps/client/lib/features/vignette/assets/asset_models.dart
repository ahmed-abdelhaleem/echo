import 'package:echo_client/features/vignette/backdrop/backdrop_models.dart';
import 'package:echo_client/features/vignette/scene_models.dart';

class AssetManifest {
  const AssetManifest({required this.seasonId, required this.assets});

  factory AssetManifest.fromJson(Map<String, dynamic> json) {
    return AssetManifest(
      seasonId: json['season_id'] as String,
      assets: <AssetDescriptor>[
        for (final value in json['assets'] as List<dynamic>)
          AssetDescriptor.fromJson(value as Map<String, dynamic>),
      ],
    );
  }

  final String seasonId;
  final List<AssetDescriptor> assets;

  AssetDescriptor? find(String assetId) {
    for (final asset in assets) {
      if (asset.assetId == assetId) {
        return asset;
      }
    }
    return null;
  }
}

class AssetDescriptor {
  const AssetDescriptor({
    required this.assetId,
    required this.contentAddress,
    required this.targetPolycount,
    required this.isReady,
  });

  factory AssetDescriptor.fromJson(Map<String, dynamic> json) {
    final generation = json['generation'] as Map<String, dynamic>;
    final params = generation['params'] as Map<String, dynamic>;
    return AssetDescriptor(
      assetId: json['id'] as String,
      contentAddress: json['content_address'] as String,
      targetPolycount: (params['target_polycount'] as num?)?.toInt() ?? 0,
      isReady: json['status'] == 'ready',
    );
  }

  final String assetId;
  final String contentAddress;
  final int targetPolycount;
  final bool isReady;

  String get digest => contentAddress.substring('sha256:'.length);

  Uri? remoteUri(String cdnBaseUrl) {
    final base = cdnBaseUrl.trim();
    if (base.isEmpty) {
      return null;
    }
    return Uri.parse(
      '${base.replaceFirst(RegExp(r'/$'), '')}/assets/sha256/$digest/asset.glb',
    );
  }
}

class CachedAsset {
  const CachedAsset({
    required this.descriptor,
    required this.localPath,
    required this.renderSource,
    required this.sizeBytes,
    required this.parallaxDepth,
    this.worldMatrix,
    this.nodeId,
    this.interactive = false,
  });

  final AssetDescriptor descriptor;
  final String? localPath;
  final String renderSource;
  final int sizeBytes;

  /// Legacy single-axis parallax placement (0 = at camera, 100 = at infinity).
  /// Used by the renderers only when [worldMatrix] is null.
  final double parallaxDepth;

  /// Resolved column-major world transform from the VignetteScene (TRS + anchor
  /// chain). When present the renderers place the asset by this matrix instead
  /// of by [parallaxDepth]. See [SceneMatrix].
  final SceneMatrix? worldMatrix;

  /// Scene node id this asset was placed as (for diagnostics / future
  /// tap-to-inspect). Null on the parallax path.
  final String? nodeId;

  /// Tap-to-inspect "noticing point" — calm, optional, never assessed.
  final bool interactive;

  /// The placement the renderers should use: the resolved scene matrix, or the
  /// legacy parallax depth expressed as a translation-only matrix so both
  /// paths share one transform codepath.
  SceneMatrix get placementMatrix =>
      worldMatrix ?? translationMatrix(0, 0, -parallaxDepth / 100.0);
}

class AssetScene {
  const AssetScene({required this.assets, this.camera});

  static const AssetScene empty = AssetScene(assets: <CachedAsset>[]);

  final List<CachedAsset> assets;

  /// Bounded orbit rig when this scene came from a VignetteScene; null on the
  /// parallax-backdrop fallback (the renderers then use their default framing).
  final CameraRig? camera;

  bool get isEmpty => assets.isEmpty;
  int get totalPolycount => assets.fold(
        0,
        (total, asset) => total + asset.descriptor.targetPolycount,
      );
  int get totalSizeBytes =>
      assets.fold(0, (total, asset) => total + asset.sizeBytes);
}

class AssetSceneLoader {
  const AssetSceneLoader({required this.cache});

  final AssetCacheReader cache;

  /// Scene-driven load (T-CLIENT-201): place every ready asset in [scene] by
  /// its resolved world transform (TRS + anchor chain) and carry the bounded
  /// camera rig. The environment is loaded before its props so a constrained
  /// budget spends on it first. Returns an empty scene when nothing resolves,
  /// so the caller can fall back to the parallax backdrop.
  Future<AssetScene> loadScene({
    required VignetteScene scene,
    required AssetManifest manifest,
    required String cdnBaseUrl,
  }) async {
    final loaded = <CachedAsset>[];
    final seen = <String>{};
    var remainingPolycount = scene.assetBudget.maxPolycount;
    var remainingSizeBytes = scene.assetBudget.maxSizeBytes;

    for (final placement in scene.resolvePlacements()) {
      final placed = placement.asset;
      if (!seen.add(placed.assetId)) {
        continue;
      }
      final descriptor = manifest.find(placed.assetId);
      if (descriptor == null ||
          !descriptor.isReady ||
          descriptor.targetPolycount <= 0 ||
          descriptor.targetPolycount > remainingPolycount) {
        continue;
      }
      final asset = await cache.obtain(
        descriptor: descriptor,
        remoteUri: descriptor.remoteUri(cdnBaseUrl),
        maxSizeBytes: remainingSizeBytes,
        parallaxDepth: 0,
        worldMatrix: placement.worldMatrix,
        nodeId: placed.id,
        interactive: placed.interactive,
      );
      if (asset == null) {
        continue;
      }
      loaded.add(asset);
      remainingPolycount -= descriptor.targetPolycount;
      remainingSizeBytes -= asset.sizeBytes;
    }

    return AssetScene(assets: loaded, camera: scene.camera);
  }

  Future<AssetScene> load({
    required BackdropSpec backdrop,
    required AssetManifest manifest,
    required String cdnBaseUrl,
  }) async {
    final loaded = <CachedAsset>[];
    final seen = <String>{};
    var remainingPolycount = backdrop.assetBudget.maxPolycount;
    var remainingSizeBytes = backdrop.assetBudget.maxSizeBytes;

    for (final layer in backdrop.layersBackToFront) {
      if (!seen.add(layer.assetId)) {
        continue;
      }
      final descriptor = manifest.find(layer.assetId);
      if (descriptor == null ||
          !descriptor.isReady ||
          descriptor.targetPolycount <= 0 ||
          descriptor.targetPolycount > remainingPolycount) {
        continue;
      }
      final asset = await cache.obtain(
        descriptor: descriptor,
        remoteUri: descriptor.remoteUri(cdnBaseUrl),
        maxSizeBytes: remainingSizeBytes,
        parallaxDepth: layer.parallaxDepth,
      );
      if (asset == null) {
        continue;
      }
      loaded.add(asset);
      remainingPolycount -= descriptor.targetPolycount;
      remainingSizeBytes -= asset.sizeBytes;
    }

    return AssetScene(assets: loaded);
  }
}

abstract interface class AssetCacheReader {
  Future<CachedAsset?> obtain({
    required AssetDescriptor descriptor,
    required Uri? remoteUri,
    required int maxSizeBytes,
    required double parallaxDepth,
    SceneMatrix? worldMatrix,
    String? nodeId,
    bool interactive,
  });
}
