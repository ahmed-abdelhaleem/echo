import 'dart:io';
import 'dart:typed_data';

import 'package:echo_client/features/vignette/assets/asset_cache.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// Asset-bundle key for the dev-only placeholder GLB. See gen_placeholder.py
/// for how it is regenerated; declared in pubspec.yaml.
const String _kDevPlaceholderAssetKey = 'assets/3d/dev/placeholder.glb';

AssetFileStore createAssetFileStore() => _NativeAssetFileStore();

class _NativeAssetFileStore implements AssetFileStore {
  Future<Directory> _cacheDirectory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory('${support.path}/assets/sha256');
    await directory.create(recursive: true);
    return directory;
  }

  @override
  Future<StoredAsset?> find(String digest) async {
    final directory = await _cacheDirectory();
    final file = File('${directory.path}/$digest.glb');
    if (!await file.exists()) {
      // T-CLIENT-040 dev affordance. Production assets are streamed from
      // R2 via the asset CDN (configured via --dart-define=ECHO_ASSET_CDN_URL);
      // local dev has neither a CDN nor a pre-warmed cache, so the
      // 3D viewport would silently render nothing. In a debug build we
      // hydrate the cache from the bundled placeholder GLB so the
      // adaptive backdrop is visibly wired end-to-end. Gated on
      // kDebugMode so release builds never serve placeholders.
      if (kDebugMode) {
        final hydrated = await _hydrateFromBundle(digest, file);
        if (hydrated != null) {
          return hydrated;
        }
      }
      return null;
    }
    final length = await file.length();
    if (length < 12) {
      await file.delete();
      return null;
    }
    final handle = await file.open();
    var valid = false;
    try {
      final headerBytes = await handle.read(12);
      final header = ByteData.sublistView(headerBytes);
      valid = header.getUint32(0, Endian.little) == 0x46546C67 &&
          header.getUint32(4, Endian.little) == 2 &&
          header.getUint32(8, Endian.little) == length;
    } finally {
      await handle.close();
    }
    if (!valid) {
      await file.delete();
      return null;
    }
    return StoredAsset(
      localPath: file.path,
      renderSource: file.uri.toString(),
      sizeBytes: length,
    );
  }

  /// Copy the bundled placeholder GLB into the cache as if it were the
  /// asset for *digest*. Returns null when the placeholder is missing from
  /// the bundle (e.g. tests with a fake AssetBundle). Debug-only — see find().
  Future<StoredAsset?> _hydrateFromBundle(
      String digest, File destination) async {
    try {
      final data = await rootBundle.load(_kDevPlaceholderAssetKey);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      await destination.parent.create(recursive: true);
      final temporary = File('${destination.path}.part');
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(destination.path);
      return StoredAsset(
        localPath: destination.path,
        renderSource: destination.uri.toString(),
        sizeBytes: bytes.lengthInBytes,
      );
    } catch (_) {
      // The placeholder isn't bundled in this build (or rootBundle is
      // unavailable in this test environment). Fall through; production
      // path serves nothing rather than guessing.
      return null;
    }
  }

  @override
  Future<StoredAsset> write(String digest, Uint8List bytes) async {
    final directory = await _cacheDirectory();
    final destination = File('${directory.path}/$digest.glb');
    final temporary = File('${destination.path}.part');
    await temporary.writeAsBytes(bytes, flush: true);
    if (await destination.exists()) {
      await destination.delete();
    }
    await temporary.rename(destination.path);
    return StoredAsset(
      localPath: destination.path,
      renderSource: destination.uri.toString(),
      sizeBytes: bytes.lengthInBytes,
    );
  }
}
