import 'dart:io';

import 'package:echo_client/features/vignette/assets/asset_models.dart';
import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:thermion_flutter/thermion_flutter.dart';

Widget buildThreeDViewport(BuildContext context, AssetScene scene) {
  return _NativeThreeDViewport(
    key: ValueKey<String>(
      scene.assets.map((asset) => asset.descriptor.digest).join(':'),
    ),
    scene: scene,
  );
}

class _NativeThreeDViewport extends StatefulWidget {
  const _NativeThreeDViewport({required this.scene, super.key});

  final AssetScene scene;

  @override
  State<_NativeThreeDViewport> createState() => _NativeThreeDViewportState();
}

class _NativeThreeDViewportState extends State<_NativeThreeDViewport> {
  ThermionViewer? _viewer;
  bool _thermionFailed = false;

  @override
  void initState() {
    super.initState();
    _initializeThermion();
  }

  Future<void> _initializeThermion() async {
    ThermionViewer? viewer;
    try {
      final localAssets = widget.scene.assets
          .where((asset) => asset.localPath != null)
          .toList(growable: false);
      if (localAssets.isEmpty) {
        throw StateError('Thermion requires a local GLB path');
      }
      viewer = await ThermionFlutterPlugin.createViewer();
      for (final asset in localAssets) {
        final thermionAsset = await viewer.loadGltf(asset.localPath!);
        await thermionAsset.transformToUnitCube();
        final transform = await thermionAsset.getLocalTransform();
        transform.setTranslationRaw(0, 0, -(asset.parallaxDepth / 100));
        await thermionAsset.setTransform(transform);
      }
      await viewer.addDirectLight(
        DirectLight.sun(color: 6500, intensity: 90000),
      );
      final camera = await viewer.getActiveCamera();
      await camera.lookAt(Vector3(0, 0, 4));
      await viewer.setBackgroundColor(0, 0, 0, 0);
      await viewer.setPostProcessing(true);
      await viewer.setRendering(true);
      if (!mounted) {
        await viewer.dispose();
        return;
      }
      setState(() => _viewer = viewer);
    } on Object {
      await viewer?.dispose();
      if (mounted) {
        setState(() => _thermionFailed = true);
      }
    }
  }

  @override
  void dispose() {
    final viewer = _viewer;
    _viewer = null;
    if (viewer != null) {
      viewer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewer = _viewer;
    if (viewer != null) {
      return ThermionWidget(viewer: viewer, initial: const SizedBox.expand());
    }
    if (_thermionFailed && (Platform.isAndroid || Platform.isIOS)) {
      return ModelViewer(
        src: widget.scene.assets.first.renderSource,
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
    return const SizedBox.expand();
  }
}
