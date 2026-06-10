import 'package:echo_client/features/vignette/assets/asset_models.dart';
import 'package:echo_client/features/vignette/assets/asset_provider.dart';
import 'package:echo_client/features/vignette/backdrop/adaptive_backdrop.dart';
import 'package:echo_client/features/vignette/backdrop/atmospheric_backdrop.dart';
import 'package:echo_client/features/vignette/backdrop/backdrop_models.dart';
import 'package:echo_client/features/vignette/backdrop/backdrop_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const BackdropSpec _backdrop = BackdropSpec(
  vignetteId: 'vignette-001',
  camera: CameraSpec(mode: CameraMode.static, sensitivity: 0),
  layers: <BackdropLayer>[
    BackdropLayer(
      id: 'room',
      assetId: 'morning-bedroom-window',
      parallaxDepth: 50,
    ),
  ],
);

const AssetScene _scene = AssetScene(
  assets: <CachedAsset>[
    CachedAsset(
      descriptor: AssetDescriptor(
        assetId: 'morning-bedroom-window',
        contentAddress:
            'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        targetPolycount: 40000,
        isReady: true,
      ),
      localPath: '/cache/room.glb',
      renderSource: 'file:///cache/room.glb',
      sizeBytes: 4096,
      parallaxDepth: 50,
    ),
  ],
);

Widget _testApp({
  required AssetScene scene,
  required ThreeDViewportBuilder viewportBuilder,
}) {
  return ProviderScope(
    overrides: <Override>[
      assetSceneProvider.overrideWith(
        (Ref ref, VignetteBackdropKey key) async => scene,
      ),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: AdaptiveAtmosphericBackdrop(
          seasonId: 'season-001',
          spec: _backdrop,
          viewportBuilder: viewportBuilder,
        ),
      ),
    ),
  );
}

Widget _fakeViewport(BuildContext context, AssetScene scene) {
  return const ColoredBox(
    key: ValueKey<String>('fake-3d-viewport'),
    color: Color(0x66476A82),
  );
}

void main() {
  testWidgets('missing 3D assets leave the continuous 2D fallback intact', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _testApp(scene: AssetScene.empty, viewportBuilder: _fakeViewport),
    );
    await tester.pump();

    expect(find.byType(AtmosphericBackdrop), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('fake-3d-viewport')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('ready assets enrich the fallback without replacing it', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _testApp(scene: _scene, viewportBuilder: _fakeViewport),
    );
    await tester.pump();

    expect(find.byType(AtmosphericBackdrop), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('fake-3d-viewport')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('three-d-backdrop')),
      findsOneWidget,
    );
  });

  testWidgets('representative vignette matches the adaptive backdrop golden', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _testApp(scene: _scene, viewportBuilder: _fakeViewport),
    );
    await tester.pump(const Duration(milliseconds: 16));

    await expectLater(
      find.byType(AdaptiveAtmosphericBackdrop),
      matchesGoldenFile('goldens/adaptive_backdrop.png'),
    );
  });

  testWidgets('representative vignette sustains 120 simulated frames', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _testApp(scene: _scene, viewportBuilder: _fakeViewport),
    );
    await tester.pump();

    final stopwatch = Stopwatch()..start();
    for (var frame = 0; frame < 120; frame++) {
      await tester.pump(const Duration(microseconds: 16667));
    }
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 8)));
    expect(tester.takeException(), isNull);
  });
}
