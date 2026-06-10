import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_client/features/vignette/assets/asset_models.dart';

typedef AssetDownloader = Future<Uint8List?> Function(
  Uri uri,
  int maxSizeBytes,
);

class StoredAsset {
  const StoredAsset({
    required this.localPath,
    required this.renderSource,
    required this.sizeBytes,
  });

  final String? localPath;
  final String renderSource;
  final int sizeBytes;
}

abstract interface class AssetFileStore {
  Future<StoredAsset?> find(String digest);
  Future<StoredAsset> write(String digest, Uint8List bytes);
}

class AssetCache implements AssetCacheReader {
  const AssetCache({required this.store, required this.downloader});

  final AssetFileStore store;
  final AssetDownloader downloader;

  @override
  Future<CachedAsset?> obtain({
    required AssetDescriptor descriptor,
    required Uri? remoteUri,
    required int maxSizeBytes,
    required double parallaxDepth,
  }) async {
    final cached = await store.find(descriptor.digest);
    if (cached != null && cached.sizeBytes <= maxSizeBytes) {
      return _resolved(descriptor, cached, parallaxDepth);
    }
    if (remoteUri == null || maxSizeBytes < 12) {
      return null;
    }

    final bytes = await downloader(remoteUri, maxSizeBytes);
    if (bytes == null ||
        bytes.lengthInBytes > maxSizeBytes ||
        !isValidGlb(bytes)) {
      return null;
    }
    final stored = await store.write(descriptor.digest, bytes);
    return _resolved(descriptor, stored, parallaxDepth);
  }

  CachedAsset _resolved(
    AssetDescriptor descriptor,
    StoredAsset stored,
    double parallaxDepth,
  ) {
    return CachedAsset(
      descriptor: descriptor,
      localPath: stored.localPath,
      renderSource: stored.renderSource,
      sizeBytes: stored.sizeBytes,
      parallaxDepth: parallaxDepth,
    );
  }
}

AssetDownloader dioAssetDownloader(Dio dio) {
  return (Uri uri, int maxSizeBytes) async {
    try {
      final response = await dio.get<List<int>>(
        uri.toString(),
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
      if (response.statusCode != 200 || response.data == null) {
        return null;
      }
      final declaredLength = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      if (declaredLength != null && declaredLength > maxSizeBytes) {
        return null;
      }
      return Uint8List.fromList(response.data!);
    } on DioException {
      return null;
    }
  };
}

bool isValidGlb(Uint8List bytes) {
  if (bytes.lengthInBytes < 12) {
    return false;
  }
  final header = ByteData.sublistView(bytes, 0, 12);
  final magic = header.getUint32(0, Endian.little);
  final version = header.getUint32(4, Endian.little);
  final declaredLength = header.getUint32(8, Endian.little);
  return magic == 0x46546C67 &&
      version == 2 &&
      declaredLength == bytes.lengthInBytes;
}
