// BackdropManifest parsing — locks the Dart projection of
// packages/content-schema/vignette_backdrop.schema.json.

import 'dart:convert';

import 'package:echo_client/features/vignette/backdrop/backdrop_models.dart';
import 'package:flutter_test/flutter_test.dart';

const String _kSampleJson = '''
{
  "schema_version": "1.0",
  "season_id": "season-001",
  "backdrops": [
    {
      "vignette_id": "vignette-001",
      "mood": {
        "time_of_day": "dawn",
        "weather": "clear",
        "palette": "warm"
      },
      "camera": { "mode": "parallax", "sensitivity": 0.35 },
      "transition": { "in_ms": 1200, "out_ms": 600, "curve": "ease_out" },
      "layers": [
        {
          "id": "sky",
          "asset_id": "morning-bedroom-window",
          "parallax_depth": 90,
          "opacity": 1.0,
          "ambient": [
            { "type": "drift", "axis": "x", "amplitude_px": 8, "period_ms": 14000 },
            { "type": "pulse", "amplitude": 0.06, "period_ms": 9000 }
          ]
        },
        {
          "id": "room",
          "asset_id": "morning-bedroom-window",
          "parallax_depth": 30,
          "ambient": [
            { "type": "particles", "kind": "dust_motes", "density": 0.35 },
            { "type": "parallax_breathe", "amplitude": 0.015, "period_ms": 12000 }
          ]
        }
      ]
    }
  ]
}
''';

void main() {
  group('BackdropManifest', () {
    test('parses the sample manifest', () {
      final manifest = BackdropManifest.fromJson(
        jsonDecode(_kSampleJson) as Map<String, dynamic>,
      );
      expect(manifest.seasonId, 'season-001');
      expect(manifest.backdrops, hasLength(1));

      final b = manifest.forVignette('vignette-001');
      expect(b, isNotNull);
      expect(b!.mood?.timeOfDay, 'dawn');
      expect(b.camera.mode, CameraMode.parallax);
      expect(b.camera.sensitivity, closeTo(0.35, 1e-9));
      expect(b.transition.inMs, 1200);
      expect(b.transition.curve, TransitionCurve.easeOut);
    });

    test('forVignette returns null for an unknown id', () {
      final manifest = BackdropManifest.fromJson(
        jsonDecode(_kSampleJson) as Map<String, dynamic>,
      );
      expect(manifest.forVignette('vignette-999'), isNull);
    });

    test('layersBackToFront sorts by descending depth', () {
      final manifest = BackdropManifest.fromJson(
        jsonDecode(_kSampleJson) as Map<String, dynamic>,
      );
      final layers = manifest.backdrops.first.layersBackToFront;
      expect(
        layers.map((BackdropLayer l) => l.id).toList(),
        <String>['sky', 'room'],
      );
    });

    test('decodes all ambient effect variants', () {
      final manifest = BackdropManifest.fromJson(
        jsonDecode(_kSampleJson) as Map<String, dynamic>,
      );
      final sky = manifest.backdrops.first.layers
          .firstWhere((BackdropLayer l) => l.id == 'sky');
      final room = manifest.backdrops.first.layers
          .firstWhere((BackdropLayer l) => l.id == 'room');

      expect(sky.ambient[0], isA<DriftEffect>());
      expect((sky.ambient[0] as DriftEffect).amplitudePx, 8);
      expect(sky.ambient[1], isA<PulseEffect>());
      expect(room.ambient[0], isA<ParticlesEffect>());
      expect((room.ambient[0] as ParticlesEffect).kind, 'dust_motes');
      expect(room.ambient[1], isA<ParallaxBreatheEffect>());
    });

    test('rejects unknown ambient effect type', () {
      expect(
        () => AmbientEffect.fromJson(
          <String, dynamic>{'type': 'earthquake', 'magnitude': 7},
        ),
        throwsFormatException,
      );
    });

    test('parallaxWeight maps depth to [0, 1]', () {
      final manifest = BackdropManifest.fromJson(
        jsonDecode(_kSampleJson) as Map<String, dynamic>,
      );
      final sky = manifest.backdrops.first.layers
          .firstWhere((BackdropLayer l) => l.id == 'sky');
      expect(sky.parallaxWeight, closeTo(0.9, 1e-9));
    });
  });
}
