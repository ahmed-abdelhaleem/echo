// Riverpod plumbing for atmospheric backdrops (T-CLIENT-041).
//
// Loads the Season's backdrop manifest from the bundled assets and exposes a
// `BackdropSpec?` lookup keyed by vignette id. Fails open: if the manifest is
// missing, malformed, or the requested vignette has no entry, callers get
// `null` and the renderer simply renders no backdrop. That is the desired
// degradation — no backdrop is always better than a crash, and many vignettes
// will not have backdrops authored yet.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backdrop_models.dart';

/// Loads the backdrop manifest for [seasonId] from the bundled assets. Returns
/// `null` on any failure so the renderer degrades gracefully.
final FutureProviderFamily<BackdropManifest?, String> backdropManifestProvider =
    FutureProvider.family<BackdropManifest?, String>((Ref ref, String seasonId) async {
  final assetKey = 'assets/backdrops/$seasonId/backdrops.manifest.json';
  try {
    final raw = await rootBundle.loadString(assetKey);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return BackdropManifest.fromJson(json);
  } catch (e, st) {
    // Asset missing in this build, or the file is malformed. Either way we
    // render no backdrop — the choice UI keeps working.
    debugPrint('backdrop manifest unavailable for $seasonId: $e');
    debugPrintStack(stackTrace: st, label: 'backdropManifestProvider');
    return null;
  }
});

/// Returns the [BackdropSpec] for a specific vignette, or `null` if the
/// manifest is unavailable or no backdrop is authored for that vignette.
final ProviderFamily<BackdropSpec?, _BackdropKey> backdropForVignetteProvider =
    Provider.family<BackdropSpec?, _BackdropKey>((Ref ref, _BackdropKey key) {
  final async = ref.watch(backdropManifestProvider(key.seasonId));
  return async.maybeWhen<BackdropSpec?>(
    data: (BackdropManifest? m) => m?.forVignette(key.vignetteId),
    orElse: () => null,
  );
});

/// Composite key for [backdropForVignetteProvider]. Riverpod families are
/// single-arg, so we wrap (seasonId, vignetteId) in a value type.
@immutable
class _BackdropKey {
  const _BackdropKey({required this.seasonId, required this.vignetteId});

  final String seasonId;
  final String vignetteId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _BackdropKey &&
          other.seasonId == seasonId &&
          other.vignetteId == vignetteId;

  @override
  int get hashCode => Object.hash(seasonId, vignetteId);
}

/// Public helper so consumers don't construct the private key directly.
BackdropSpec? readBackdropFor(
  WidgetRef ref, {
  required String seasonId,
  required String vignetteId,
}) {
  return ref.watch(
    backdropForVignetteProvider(
      _BackdropKey(seasonId: seasonId, vignetteId: vignetteId),
    ),
  );
}
