import 'package:echo_client/features/vignette/scene_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// The translation column (indices 12..14) of a column-major matrix.
List<double> _translationOf(SceneMatrix m) => <double>[m[12], m[13], m[14]];

/// Apply a column-major matrix to a point.
List<double> _apply(SceneMatrix m, List<double> p) {
  final x = p[0], y = p[1], z = p[2];
  return <double>[
    m[0] * x + m[4] * y + m[8] * z + m[12],
    m[1] * x + m[5] * y + m[9] * z + m[13],
    m[2] * x + m[6] * y + m[10] * z + m[14],
  ];
}

void _expectVec(List<double> actual, List<double> expected) {
  expect(actual, hasLength(expected.length));
  for (var i = 0; i < expected.length; i++) {
    expect(actual[i], closeTo(expected[i], 1e-9), reason: 'index $i');
  }
}

const Map<String, dynamic> _sceneJson = <String, dynamic>{
  'vignette_id': 'vignette-001',
  'mood': <String, dynamic>{'time_of_day': 'dawn', 'palette': 'warm'},
  'environment': <String, dynamic>{
    'id': 'env-bedroom',
    'asset_id': 'morning-bedroom-window',
    'transform': <String, dynamic>{
      'position': <double>[0, 0, 0],
      'scale': 1,
    },
  },
  'props': <dynamic>[
    <String, dynamic>{
      'id': 'unmade-bed',
      'asset_id': 'unmade-bed',
      'anchor': 'env-bedroom',
      'transform': <String, dynamic>{
        'position': <double>[-0.6, 0, -0.4],
        'rotation_deg': <double>[0, 12, 0],
        'scale': 1,
      },
    },
    <String, dynamic>{
      'id': 'nightstand-phone',
      'asset_id': 'nightstand-phone',
      'anchor': 'unmade-bed',
      'interactive': true,
      'notice': <String, dynamic>{'label': 'The phone', 'body': 'Face-down.'},
      'transform': <String, dynamic>{
        'position': <double>[0.9, 0.5, -0.2],
        'scale': 1,
      },
    },
  ],
  'lighting': <String, dynamic>{
    'preset': 'dawn',
    'intensity': 1.4,
    'ambient': 0.45,
    'color': '#ffd9a8',
    'direction': <String, dynamic>{'azimuth_deg': -35, 'elevation_deg': 14},
  },
  'camera': <String, dynamic>{
    'look_at': <double>[0, 1.0, 0],
    'distance': 4.6,
    'default_framing': <String, dynamic>{'azimuth_deg': 0, 'polar_deg': 9},
    'bounds': <String, dynamic>{
      'azimuth_deg': <String, dynamic>{'min': -28, 'max': 28},
      'polar_deg': <String, dynamic>{'min': -4, 'max': 18},
    },
  },
  'asset_budget': <String, dynamic>{
    'max_polycount': 120000,
    'max_size_bytes': 31457280,
  },
};

void main() {
  group('SceneTransform.toMatrix', () {
    test('identity transform is the identity matrix', () {
      _expectVec(const SceneTransform().toMatrix(), identityMatrix());
    });

    test('translation lands in the matrix translation column', () {
      const t = SceneTransform(position: <double>[1.5, -2, 3]);
      _expectVec(_translationOf(t.toMatrix()), <double>[1.5, -2, 3]);
    });

    test('uniform scalar scale applies to all three axes', () {
      const t = SceneTransform(scale: <double>[2, 2, 2]);
      _expectVec(_apply(t.toMatrix(), <double>[1, 1, 1]), <double>[2, 2, 2]);
    });

    test('per-axis scale applies independently', () {
      const t = SceneTransform(scale: <double>[2, 3, 4]);
      _expectVec(_apply(t.toMatrix(), <double>[1, 1, 1]), <double>[2, 3, 4]);
    });

    test('+90deg about Y sends +X to -Z (right-handed, Y up)', () {
      const t = SceneTransform(rotationDeg: <double>[0, 90, 0]);
      _expectVec(_apply(t.toMatrix(), <double>[1, 0, 0]), <double>[0, 0, -1]);
    });
  });

  group('multiplyMatrix', () {
    test('identity is the multiplicative unit', () {
      const t = SceneTransform(position: <double>[1, 2, 3]);
      _expectVec(
        multiplyMatrix(identityMatrix(), t.toMatrix()),
        t.toMatrix(),
      );
    });

    test('translationMatrix matches a translation-only transform', () {
      _expectVec(
        translationMatrix(0, 0, -0.9),
        const SceneTransform(position: <double>[0, 0, -0.9]).toMatrix(),
      );
    });
  });

  group('VignetteScene.resolvePlacements (anchors)', () {
    test('an anchored prop adds its parent world translation', () {
      final scene = VignetteScene.fromJson(_sceneJson);
      final placements = <String, ResolvedPlacement>{
        for (final p in scene.resolvePlacements()) p.asset.id: p,
      };

      // env at origin; bed anchored to env at [-0.6,0,-0.4]; phone anchored to
      // bed at [0.9,0.5,-0.2] → phone world translation is the bed's + its own
      // (both anchor transforms here are translations, plus the bed's 12deg yaw
      // which leaves a pure translation unchanged in the translation column).
      _expectVec(
        _translationOf(placements['env-bedroom']!.worldMatrix),
        <double>[0, 0, 0],
      );
      _expectVec(
        _translationOf(placements['unmade-bed']!.worldMatrix),
        <double>[-0.6, 0, -0.4],
      );
      // Phone: bed yaw (12deg about Y) rotates the phone's local offset before
      // adding the bed origin, so compute the expected with the same matrix.
      final bedWorld = placements['unmade-bed']!.worldMatrix;
      final expectedPhone = _apply(bedWorld, <double>[0.9, 0.5, -0.2]);
      _expectVec(
        _translationOf(placements['nightstand-phone']!.worldMatrix),
        expectedPhone,
      );
    });

    test('a missing anchor degrades to a scene root (local == world)', () {
      final scene = VignetteScene.fromJson(<String, dynamic>{
        ..._sceneJson,
        'props': <dynamic>[
          <String, dynamic>{
            'id': 'floating',
            'asset_id': 'lamp',
            'anchor': 'does-not-exist',
            'transform': <String, dynamic>{
              'position': <double>[5, 0, 0],
            },
          },
        ],
      });
      final floating =
          scene.resolvePlacements().firstWhere((p) => p.asset.id == 'floating');
      _expectVec(_translationOf(floating.worldMatrix), <double>[5, 0, 0]);
    });

    test('a self-referential anchor cycle terminates without throwing', () {
      final scene = VignetteScene.fromJson(<String, dynamic>{
        ..._sceneJson,
        'environment': <String, dynamic>{
          'id': 'a',
          'asset_id': 'a',
          'anchor': 'b',
          'transform': <String, dynamic>{
            'position': <double>[1, 0, 0],
          },
        },
        'props': <dynamic>[
          <String, dynamic>{
            'id': 'b',
            'asset_id': 'b',
            'anchor': 'a',
            'transform': <String, dynamic>{
              'position': <double>[0, 1, 0],
            },
          },
        ],
      });
      expect(scene.resolvePlacements(), hasLength(2));
    });

    test('environment is placed before props', () {
      final scene = VignetteScene.fromJson(_sceneJson);
      expect(scene.placedAssets.first.id, 'env-bedroom');
      expect(scene.placedAssets, hasLength(3));
    });
  });

  group('JSON projection', () {
    test('parses environment, props, camera, lighting and mood', () {
      final manifest = VignetteSceneManifest.fromJson(<String, dynamic>{
        'season_id': 'season-001',
        'scenes': <dynamic>[_sceneJson],
      });
      final scene = manifest.forVignette('vignette-001')!;

      expect(scene.environment.assetId, 'morning-bedroom-window');
      expect(scene.props, hasLength(2));
      expect(scene.props[1].interactive, isTrue);
      expect(scene.props[1].notice?.label, 'The phone');
      expect(scene.mood?.timeOfDay, 'dawn');
      expect(scene.lighting?.preset, 'dawn');
      expect(scene.lighting?.direction?.elevationDeg, 14);
      expect(scene.camera.distance, 4.6);
      expect(scene.camera.bounds.azimuth.max, 28);
      expect(scene.camera.bounds.zoom.enabled, isFalse);
      expect(scene.assetBudget.maxPolycount, 120000);
    });

    test('unknown vignette returns null', () {
      final manifest = VignetteSceneManifest.fromJson(<String, dynamic>{
        'season_id': 'season-001',
        'scenes': <dynamic>[_sceneJson],
      });
      expect(manifest.forVignette('vignette-999'), isNull);
    });
  });
}
