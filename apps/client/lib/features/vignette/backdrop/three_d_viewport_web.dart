import 'package:echo_client/features/vignette/assets/asset_models.dart';
import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

Widget buildThreeDViewport(BuildContext context, AssetScene scene) {
  return ModelViewer(
    src: scene.assets.first.renderSource,
    alt: 'Atmospheric vignette scene',
    backgroundColor: Colors.transparent,
    cameraControls: false,
    disablePan: true,
    disableTap: true,
    disableZoom: true,
    loading: Loading.eager,
    interactionPrompt: InteractionPrompt.none,
    debugLogging: false,
  );
}
