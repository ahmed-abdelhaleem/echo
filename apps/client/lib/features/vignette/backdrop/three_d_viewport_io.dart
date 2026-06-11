import 'dart:io';
import 'dart:math' as math;

import 'package:echo_client/features/vignette/assets/asset_models.dart';
import 'package:echo_client/features/vignette/scene_models.dart';
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

/// Camera world position from the scene's bounded rig: the look-at point plus a
/// distance offset at the rig's default azimuth/polar framing. Falls back to
/// the historical fixed framing when the scene has no rig (parallax path).
Vector3 _cameraPosition(CameraRig? rig) {
  if (rig == null) {
    return Vector3(0, 0, 4);
  }
  final az = rig.defaultFraming.azimuthDeg * math.pi / 180.0;
  final polar = rig.defaultFraming.polarDeg * math.pi / 180.0;
  final d = rig.distance;
  return Vector3(
    rig.lookAt[0] + d * math.cos(polar) * math.sin(az),
    rig.lookAt[1] + d * math.sin(polar),
    rig.lookAt[2] + d * math.cos(polar) * math.cos(az),
  );
}

class _NativeThreeDViewportState extends State<_NativeThreeDViewport> {
  ThermionViewer? _viewer;
  // T-CLIENT-200: bounded free-look on native. Orbit is an *enhancement* — if
  // the input handler can't be created, we render the scene statically rather
  // than fail. (Refinement to validate on-device: clamp azimuth/polar and
  // disable zoom for the calm, bounded feel the web path already has.)
  InputHandler? _inputHandler;
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
        // Place by the resolved scene world matrix when present
        // (T-CLIENT-201): its translation column carries the authored position
        // + anchor offset. Parallax assets fall back to Z = -depth/100 via
        // placementMatrix. Per-asset rotation/scale fidelity on native is part
        // of the on-device pass (T-CLIENT-200); translation generalizes the
        // former Z-only parallax today.
        final m = asset.placementMatrix;
        transform.setTranslationRaw(m[12], m[13], m[14]);
        await thermionAsset.setTransform(transform);
      }
      await viewer.addDirectLight(
        DirectLight.sun(color: 6500, intensity: 90000),
      );
      final camera = await viewer.getActiveCamera();
      await camera.lookAt(_cameraPosition(widget.scene.camera));
      await viewer.setBackgroundColor(0, 0, 0, 0);
      await viewer.setPostProcessing(true);
      await viewer.setRendering(true);
      InputHandler? inputHandler;
      try {
        inputHandler = DelegateInputHandler.fixedOrbit(viewer);
      } on Object {
        inputHandler = null; // orbit unavailable → static render
      }
      if (!mounted) {
        await viewer.dispose();
        return;
      }
      setState(() {
        _viewer = viewer;
        _inputHandler = inputHandler;
      });
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
      final scene = ThermionWidget(
        viewer: viewer,
        initial: const SizedBox.expand(),
      );
      final handler = _inputHandler;
      if (handler != null) {
        // Forward pointer/drag gestures to the orbit handler so the player can
        // look around the composed scene.
        return ThermionListenerWidget(inputHandler: handler, child: scene);
      }
      return scene;
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
