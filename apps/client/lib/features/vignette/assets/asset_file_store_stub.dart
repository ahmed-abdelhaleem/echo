import 'dart:convert';
import 'dart:typed_data';

import 'package:echo_client/features/vignette/assets/asset_cache.dart';

AssetFileStore createAssetFileStore() => _MemoryAssetFileStore();

class _MemoryAssetFileStore implements AssetFileStore {
  final Map<String, Uint8List> _assets = <String, Uint8List>{};

  @override
  Future<StoredAsset?> find(String digest) async {
    final bytes = _assets[digest];
    if (bytes == null) {
      return null;
    }
    return _stored(bytes);
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
