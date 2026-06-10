import 'dart:io';
import 'dart:typed_data';

import 'package:echo_client/features/vignette/assets/asset_cache.dart';
import 'package:path_provider/path_provider.dart';

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
