import 'dart:typed_data';

import 'package:echo_client/features/vignette/assets/asset_cache.dart';
import 'package:echo_client/features/vignette/assets/asset_models.dart';
import 'package:echo_client/features/vignette/backdrop/backdrop_models.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements AssetFileStore {
  final Map<String, Uint8List> assets = <String, Uint8List>{};

  @override
  Future<StoredAsset?> find(String digest) async {
    final bytes = assets[digest];
    if (bytes == null) {
      return null;
    }
    return StoredAsset(
      localPath: '/cache/$digest.glb',
      renderSource: 'file:///cache/$digest.glb',
      sizeBytes: bytes.lengthInBytes,
    );
  }

  @override
  Future<StoredAsset> write(String digest, Uint8List bytes) async {
    assets[digest] = bytes;
    return StoredAsset(
      localPath: '/cache/$digest.glb',
      renderSource: 'file:///cache/$digest.glb',
      sizeBytes: bytes.lengthInBytes,
    );
  }
}

Uint8List _glb([int payloadBytes = 0]) {
  final bytes = Uint8List(12 + payloadBytes);
  final header = ByteData.sublistView(bytes);
  header
    ..setUint32(0, 0x46546C67, Endian.little)
    ..setUint32(4, 2, Endian.little)
    ..setUint32(8, bytes.lengthInBytes, Endian.little);
  return bytes;
}

const AssetDescriptor _descriptor = AssetDescriptor(
  assetId: 'room',
  contentAddress:
      'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  targetPolycount: 40000,
  isReady: true,
);

BackdropSpec _backdrop({int maxPolycount = 50000, int maxSizeBytes = 1024}) {
  return BackdropSpec(
    vignetteId: 'vignette-001',
    assetBudget: AssetBudgetSpec(
      maxPolycount: maxPolycount,
      maxSizeBytes: maxSizeBytes,
    ),
    layers: const <BackdropLayer>[
      BackdropLayer(id: 'far-room', assetId: 'room', parallaxDepth: 90),
      BackdropLayer(id: 'near-room', assetId: 'room', parallaxDepth: 20),
    ],
  );
}

void main() {
  test('validates the GLB header and declared length', () {
    expect(isValidGlb(_glb()), isTrue);
    expect(isValidGlb(Uint8List(11)), isFalse);

    final invalidLength = _glb();
    ByteData.sublistView(invalidLength).setUint32(8, 99, Endian.little);
    expect(isValidGlb(invalidLength), isFalse);
  });

  test('offline load reuses a previously downloaded cached asset', () async {
    final store = _MemoryStore();
    var downloads = 0;
    final online = AssetSceneLoader(
      cache: AssetCache(
        store: store,
        downloader: (uri, maxSizeBytes) async {
          downloads++;
          return _glb(24);
        },
      ),
    );
    const manifest = AssetManifest(
      seasonId: 'season-001',
      assets: <AssetDescriptor>[_descriptor],
    );

    final first = await online.load(
      backdrop: _backdrop(),
      manifest: manifest,
      cdnBaseUrl: 'https://cdn.example.test',
    );
    final offline = AssetSceneLoader(
      cache: AssetCache(
        store: store,
        downloader: (uri, maxSizeBytes) async {
          fail('offline cache hit must not access the network');
        },
      ),
    );
    final second = await offline.load(
      backdrop: _backdrop(),
      manifest: manifest,
      cdnBaseUrl: '',
    );

    expect(first.assets, hasLength(1));
    expect(second.assets, hasLength(1));
    expect(downloads, 1);
    expect(second.assets.single.localPath, contains(_descriptor.digest));
  });

  test('missing or invalid assets produce an empty fallback scene', () async {
    final store = _MemoryStore();
    final missing = AssetSceneLoader(
      cache: AssetCache(
        store: store,
        downloader: (uri, maxSizeBytes) async => null,
      ),
    );
    final invalid = AssetSceneLoader(
      cache: AssetCache(
        store: store,
        downloader: (uri, maxSizeBytes) async => Uint8List(20),
      ),
    );
    const manifest = AssetManifest(
      seasonId: 'season-001',
      assets: <AssetDescriptor>[_descriptor],
    );

    expect(
      (await missing.load(
        backdrop: _backdrop(),
        manifest: manifest,
        cdnBaseUrl: 'https://cdn.example.test',
      ))
          .isEmpty,
      isTrue,
    );
    expect(
      (await invalid.load(
        backdrop: _backdrop(),
        manifest: manifest,
        cdnBaseUrl: 'https://cdn.example.test',
      ))
          .isEmpty,
      isTrue,
    );
  });

  test('desired assets are not downloaded before the pipeline marks ready',
      () async {
    var downloads = 0;
    final loader = AssetSceneLoader(
      cache: AssetCache(
        store: _MemoryStore(),
        downloader: (uri, maxSizeBytes) async {
          downloads++;
          return _glb();
        },
      ),
    );
    const manifest = AssetManifest(
      seasonId: 'season-001',
      assets: <AssetDescriptor>[
        AssetDescriptor(
          assetId: 'room',
          contentAddress:
              'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          targetPolycount: 40000,
          isReady: false,
        ),
      ],
    );

    final scene = await loader.load(
      backdrop: _backdrop(),
      manifest: manifest,
      cdnBaseUrl: 'https://cdn.example.test',
    );

    expect(scene.isEmpty, isTrue);
    expect(downloads, 0);
  });

  test('dev placeholder GLB is bundled and isValidGlb', () async {
    // Guards the T-CLIENT-040 debug-only fallback: the file stores hydrate
    // the cache from this exact bundle key, so dropping it from
    // pubspec.yaml or shipping a malformed GLB would silently break the
    // dev "3D shows up" affordance. Production builds strip this asset
    // via the kDebugMode gate.
    final data = await rootBundle.load('assets/3d/dev/placeholder.glb');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    expect(isValidGlb(bytes), isTrue);
  });

  test(
    'poly and byte budgets reject assets before they enter the scene',
    () async {
      var downloads = 0;
      final loader = AssetSceneLoader(
        cache: AssetCache(
          store: _MemoryStore(),
          downloader: (uri, maxSizeBytes) async {
            downloads++;
            return _glb(100);
          },
        ),
      );
      const manifest = AssetManifest(
        seasonId: 'season-001',
        assets: <AssetDescriptor>[_descriptor],
      );

      final polyRejected = await loader.load(
        backdrop: _backdrop(maxPolycount: 39999),
        manifest: manifest,
        cdnBaseUrl: 'https://cdn.example.test',
      );
      final sizeRejected = await loader.load(
        backdrop: _backdrop(maxSizeBytes: 64),
        manifest: manifest,
        cdnBaseUrl: 'https://cdn.example.test',
      );

      expect(polyRejected.isEmpty, isTrue);
      expect(sizeRejected.isEmpty, isTrue);
      expect(downloads, 1);
    },
  );
}
