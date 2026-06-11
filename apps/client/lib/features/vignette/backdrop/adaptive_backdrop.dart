import 'package:echo_client/features/vignette/assets/asset_models.dart';
import 'package:echo_client/features/vignette/assets/asset_provider.dart';
import 'package:echo_client/features/vignette/backdrop/atmospheric_backdrop.dart';
import 'package:echo_client/features/vignette/backdrop/backdrop_models.dart';
import 'package:echo_client/features/vignette/backdrop/three_d_debug.dart';
import 'package:echo_client/features/vignette/backdrop/three_d_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef ThreeDViewportBuilder = Widget Function(
  BuildContext context,
  AssetScene scene,
);

class AdaptiveAtmosphericBackdrop extends ConsumerWidget {
  const AdaptiveAtmosphericBackdrop({
    required this.seasonId,
    required this.spec,
    this.viewportBuilder = buildThreeDViewport,
    super.key,
  });

  final String seasonId;
  final BackdropSpec spec;
  final ThreeDViewportBuilder viewportBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scene = ref.watch(
      assetSceneProvider((seasonId: seasonId, vignetteId: spec.vignetteId)),
    );
    if (kEcho3dDebug) {
      _logScene(scene);
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        AtmosphericBackdrop(spec: spec),
        if (scene.valueOrNull case final AssetScene ready when !ready.isEmpty)
          IgnorePointer(
            child: RepaintBoundary(
              key: const ValueKey<String>('three-d-backdrop'),
              child: kEcho3dDebug
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: const Color(0xFFFF00FF),
                          width: 3,
                        ),
                      ),
                      child: viewportBuilder(context, ready),
                    )
                  : viewportBuilder(context, ready),
            ),
          ),
      ],
    );
  }

  void _logScene(AsyncValue<AssetScene> scene) {
    scene.when(
      loading: () => debugPrint(
        '[echo3d] vignette=${spec.vignetteId} scene: loading…',
      ),
      error: (Object e, StackTrace st) => debugPrint(
        '[echo3d] vignette=${spec.vignetteId} scene: ERROR $e',
      ),
      data: (AssetScene s) {
        final src = s.assets.isEmpty ? '<none>' : s.assets.first.renderSource;
        final head = src.length > 64 ? '${src.substring(0, 64)}…' : src;
        debugPrint(
          '[echo3d] vignette=${spec.vignetteId} scene: '
          '${s.assets.length} asset(s); firstRenderSource=$head',
        );
      },
    );
  }
}
