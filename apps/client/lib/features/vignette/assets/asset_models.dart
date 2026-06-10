import 'package:echo_client/features/vignette/backdrop/backdrop_models.dart';

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
  });

  final AssetDescriptor descriptor;
  final String? localPath;
  final String renderSource;
  final int sizeBytes;
  final double parallaxDepth;
}

class AssetScene {
  const AssetScene({required this.assets});

  static const AssetScene empty = AssetScene(assets: <CachedAsset>[]);

  final List<CachedAsset> assets;

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
  });
}
