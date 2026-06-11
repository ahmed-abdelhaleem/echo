import 'dart:convert';
import 'dart:typed_data';

import 'package:echo_client/features/vignette/assets/asset_cache.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// See asset_file_store_io.dart for the rationale behind the dev-only
/// placeholder. The web build keeps assets in memory; on debug we hydrate
/// the cache from the bundled GLB so the 3D viewport has something to
/// render even when no CDN is configured.
const String _kDevPlaceholderAssetKey = 'assets/3d/dev/placeholder.glb';

AssetFileStore createAssetFileStore() => _MemoryAssetFileStore();

class _MemoryAssetFileStore implements AssetFileStore {
  final Map<String, Uint8List> _assets = <String, Uint8List>{};

  @override
  Future<StoredAsset?> find(String digest) async {
    final cached = _assets[digest];
    if (cached != null) {
      return _stored(cached);
    }
    if (kDebugMode) {
      final hydrated = await _hydrateFromBundle(digest);
      if (hydrated != null) {
        return _stored(hydrated);
      }
    }
    return null;
  }

  Future<Uint8List?> _hydrateFromBundle(String digest) async {
    try {
      final data = await rootBundle.load(_kDevPlaceholderAssetKey);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      _assets[digest] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<StoredAsset> write(String digest, Uint8List bytes) async {
    _assets[digest] = bytes;
    return _stored(bytes);
  }

  StoredAsset _stored(Uint8List bytes) {
    return StoredAsset(
      localPath: null,
      renderSource: 'data:model/gltf-binary;base64,${base64Encode(bytes)}',
      sizeBytes: bytes.lengthInBytes,
    );
  }
}
