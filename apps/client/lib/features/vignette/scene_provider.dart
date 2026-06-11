// Riverpod plumbing for explorable 3D scenes (T-CLIENT-201).
//
// Loads the Season's VignetteScene manifest from the bundled assets and exposes
// a `VignetteScene?` lookup keyed by vignette id. Fails open exactly like the
// backdrop provider: a missing or malformed manifest, or a vignette with no
// authored scene, yields `null` and the renderer falls back to the parallax
// backdrop (and ultimately the 2D atmospheric layer). No scene is always better
// than a crash, and most vignettes will not have full scenes authored yet.

import 'dart:convert';

import 'package:echo_client/features/vignette/backdrop/backdrop_provider.dart';
import 'package:echo_client/features/vignette/scene_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Loads the scene manifest for [seasonId] from the bundled assets. Returns
/// `null` on any failure so the renderer degrades to the backdrop path.
final FutureProviderFamily<VignetteSceneManifest?, String>
    sceneManifestProvider =
    FutureProvider.family<VignetteSceneManifest?, String>((
  Ref ref,
  String seasonId,
) async {
  final assetKey = 'assets/scenes/$seasonId/scenes.manifest.json';
  try {
    final raw = await rootBundle.loadString(assetKey);
    return VignetteSceneManifest.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
  } catch (e, st) {
    debugPrint('scene manifest unavailable for $seasonId: $e');
    debugPrintStack(stackTrace: st, label: 'sceneManifestProvider');
    return null;
  }
});

/// Returns the [VignetteScene] for a specific vignette, or `null` if the
/// manifest is unavailable or no scene is authored for that vignette.
final ProviderFamily<VignetteScene?, VignetteBackdropKey>
    sceneForVignetteProvider =
    Provider.family<VignetteScene?, VignetteBackdropKey>(
        (Ref ref, VignetteBackdropKey key) {
  final async = ref.watch(sceneManifestProvider(key.seasonId));
  return async.maybeWhen<VignetteScene?>(
    data: (VignetteSceneManifest? m) => m?.forVignette(key.vignetteId),
    orElse: () => null,
  );
});
