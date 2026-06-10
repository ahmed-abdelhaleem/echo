import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:echo_client/features/vignette/assets/asset_cache.dart';
import 'package:echo_client/features/vignette/assets/asset_file_store.dart';
import 'package:echo_client/features/vignette/assets/asset_models.dart';
import 'package:echo_client/features/vignette/backdrop/backdrop_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

final Provider<String> assetCdnBaseUrlProvider = Provider<String>((Ref ref) {
  return const String.fromEnvironment('ECHO_ASSET_CDN_URL');
});

final FutureProviderFamily<AssetManifest?, String> assetManifestProvider =
    FutureProvider.family<AssetManifest?, String>((
  Ref ref,
  String seasonId,
) async {
  final assetKey = 'assets/assets-3d/$seasonId/assets.manifest.json';
  try {
    final raw = await rootBundle.loadString(assetKey);
    return AssetManifest.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  } catch (error, stackTrace) {
    debugPrint('3D asset manifest unavailable for $seasonId: $error');
    debugPrintStack(stackTrace: stackTrace, label: 'assetManifestProvider');
    return null;
  }
});

final Provider<AssetCacheReader> assetCacheProvider =
    Provider<AssetCacheReader>((Ref ref) {
  return AssetCache(
    store: createAssetFileStore(),
    downloader: dioAssetDownloader(Dio()),
  );
});

final Provider<AssetSceneLoader> assetSceneLoaderProvider =
    Provider<AssetSceneLoader>((Ref ref) {
  return AssetSceneLoader(cache: ref.watch(assetCacheProvider));
});

final FutureProviderFamily<AssetScene, VignetteBackdropKey> assetSceneProvider =
    FutureProvider.family<AssetScene, VignetteBackdropKey>((
  Ref ref,
  VignetteBackdropKey key,
) async {
  final backdrop = ref.watch(backdropForVignetteProvider(key));
  if (backdrop == null) {
    return AssetScene.empty;
  }
  final manifest = await ref.watch(
    assetManifestProvider(key.seasonId).future,
  );
  if (manifest == null) {
    return AssetScene.empty;
  }
  return ref.watch(assetSceneLoaderProvider).load(
        backdrop: backdrop,
        manifest: manifest,
        cdnBaseUrl: ref.watch(assetCdnBaseUrlProvider),
      );
});
