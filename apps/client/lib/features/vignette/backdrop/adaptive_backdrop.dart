import 'package:echo_client/features/vignette/assets/asset_models.dart';
import 'package:echo_client/features/vignette/assets/asset_provider.dart';
import 'package:echo_client/features/vignette/backdrop/atmospheric_backdrop.dart';
import 'package:echo_client/features/vignette/backdrop/backdrop_models.dart';
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
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        AtmosphericBackdrop(spec: spec),
        if (scene.valueOrNull case final AssetScene ready when !ready.isEmpty)
          IgnorePointer(
            child: RepaintBoundary(
              key: const ValueKey<String>('three-d-backdrop'),
              child: viewportBuilder(context, ready),
            ),
          ),
      ],
    );
  }
}
