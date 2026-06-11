import 'dart:typed_data';

import 'package:echo_client/features/vignette/assets/asset_cache.dart';
import 'package:echo_client/features/vignette/assets/asset_models.dart';
import 'package:echo_client/features/vignette/scene_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory file store seeded with the digests it should report as present.
/// A store hit returns a StoredAsset without re-validating bytes, so the tests
/// don't need real GLB payloads.
class _SeededStore implements AssetFileStore {
  _SeededStore(this.present);

  /// digest → sizeBytes.
  final Map<String, int> present;

  @override
  Future<StoredAsset?> find(String digest) async {
    final size = present[digest];
    if (size == null) return null;
    return StoredAsset(
      localPath: '/cache/$digest.glb',
      renderSource: 'file:///cache/$digest.glb',
      sizeBytes: size,
    );
  }

  @override
  Future<StoredAsset> write(String digest, Uint8List bytes) async {
    present[digest] = bytes.lengthInBytes;
    return StoredAsset(
      localPath: '/cache/$digest.glb',
      renderSource: 'file:///cache/$digest.glb',
      sizeBytes: bytes.lengthInBytes,
    );
  }
}

const String _envAddress =
    'sha256:1111111111111111111111111111111111111111111111111111111111111111';

AssetManifest _manifestWithReadyEnv() {
  return const AssetManifest(
    seasonId: 'season-001',
    assets: <AssetDescriptor>[
      AssetDescriptor(
        assetId: 'morning-bedroom-window',
        contentAddress: _envAddress,
        targetPolycount: 40000,
        isReady: true,
      ),
    ],
  );
}

Map<String, dynamic> _scene({required String envAssetId}) => <String, dynamic>{
      'vignette_id': 'vignette-001',
      'environment': <String, dynamic>{
        'id': 'env-bedroom',
        'asset_id': envAssetId,
        'transform': <String, dynamic>{
          'position': <double>[0, 0, 0],
          'scale': 1,
        },
      },
      'props': <dynamic>[
        // Not in the asset manifest → skipped; the scene still resolves on the
        // ready environment.
        <String, dynamic>{
          'id': 'unmade-bed',
          'asset_id': 'unmade-bed',
          'anchor': 'env-bedroom',
          'transform': <String, dynamic>{
            'position': <double>[-0.6, 0, -0.4],
          },
        },
      ],
      'camera': <String, dynamic>{
        'look_at': <double>[0, 1.0, 0],
        'distance': 4.6,
        'default_framing': <String, dynamic>{'azimuth_deg': 0, 'polar_deg': 9},
        'bounds': <String, dynamic>{
          'azimuth_deg': <String, dynamic>{'min': -28, 'max': 28},
          'polar_deg': <String, dynamic>{'min': -4, 'max': 18},
        },
      },
    };

void main() {
  test('loadScene places ready assets by world matrix and carries the rig',
      () async {
    final loader = AssetSceneLoader(
      cache: AssetCache(
        store: _SeededStore(<String, int>{
          _envAddress.substring('sha256:'.length): 4096,
        }),
        downloader: (Uri uri, int maxSizeBytes) async =>
            fail('a store hit must not hit the network'),
      ),
    );

    final scene = await loader.loadScene(
      scene: VignetteScene.fromJson(_scene(envAssetId: 'morning-bedroom-window')),
      manifest: _manifestWithReadyEnv(),
      cdnBaseUrl: '',
    );

    // Only the environment resolves (the prop's asset isn't in the manifest).
    expect(scene.assets, hasLength(1));
    final env = scene.assets.single;
    expect(env.nodeId, 'env-bedroom');
    expect(env.worldMatrix, isNotNull);
    // Environment is at the origin.
    expect(env.placementMatrix[12], closeTo(0, 1e-9));
    expect(env.placementMatrix[13], closeTo(0, 1e-9));
    expect(env.placementMatrix[14], closeTo(0, 1e-9));
    // The bounded camera rig rides along for the viewport.
    expect(scene.camera, isNotNull);
    expect(scene.camera!.distance, 4.6);
  });

  test('loadScene returns empty when no asset is ready (caller falls back)',
      () async {
    final loader = AssetSceneLoader(
      cache: AssetCache(
        store: _SeededStore(<String, int>{}),
        downloader: (Uri uri, int maxSizeBytes) async => null,
      ),
    );

    final scene = await loader.loadScene(
      // Environment references an asset id absent from the manifest.
      scene: VignetteScene.fromJson(_scene(envAssetId: 'unknown-environment')),
      manifest: _manifestWithReadyEnv(),
      cdnBaseUrl: '',
    );

    expect(scene.isEmpty, isTrue);
  });
}
