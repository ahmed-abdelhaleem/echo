import 'dart:io';
import 'dart:math' as math;

import 'package:echo_client/features/vignette/assets/asset_models.dart';
import 'package:echo_client/features/vignette/scene_models.dart';
import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:thermion_flutter/thermion_flutter.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

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
        final m = asset.placementMatrix;
        if (widget.scene.camera == null) {
          // Parallax fallback path: scale to unit cube and set translation only.
          await thermionAsset.transformToUnitCube();
          final transform = await thermionAsset.getLocalTransform();
          transform.setTranslationRaw(m[12], m[13], m[14]);
          await thermionAsset.setTransform(transform);
        } else {
          // Full-fidelity scene composition: apply the resolved world matrix directly.
          final matrix = Matrix4.fromList(m);
          await thermionAsset.setTransform(matrix);
        }
      }
      await viewer.addDirectLight(
        DirectLight.sun(color: 6500, intensity: 90000),
      );
      final camera = await viewer.getActiveCamera();
      final rig = widget.scene.camera;
      final targetPoint = rig != null
          ? Vector3(rig.lookAt[0], rig.lookAt[1], rig.lookAt[2])
          : Vector3.zero();
      await camera.lookAt(_cameraPosition(rig), focus: targetPoint);
      await viewer.setBackgroundColor(0, 0, 0, 0);
      await viewer.setPostProcessing(true);
      await viewer.setRendering(true);
      InputHandler? inputHandler;
      if (mounted) {
        final reduceMotion =
            MediaQuery.maybeOf(context)?.disableAnimations ?? false;
        if (!reduceMotion) {
          try {
            inputHandler = DelegateInputHandler(
              viewer: viewer,
              delegates: <InputHandlerDelegate>[
                BoundedOrbitInputHandlerDelegate(
                  viewer.view,
                  rig: widget.scene.camera,
                ),
              ],
            );
          } on Object {
            inputHandler = null; // orbit unavailable → static render
          }
        }
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

class BoundedOrbitInputHandlerDelegate extends InputHandlerDelegate {
  BoundedOrbitInputHandlerDelegate(
    this.view, {
    required CameraRig? rig,
    this.sensitivity = const InputSensitivityOptions(),
  })  : targetPoint = rig != null
            ? Vector3(rig.lookAt[0], rig.lookAt[1], rig.lookAt[2])
            : Vector3.zero(),
        minZoomDistance = (rig != null && rig.bounds.zoom.enabled)
            ? (rig.bounds.zoom.minDistance ?? (rig.distance * 0.5))
            : (rig?.distance ?? 4.0),
        maxZoomDistance = (rig != null && rig.bounds.zoom.enabled)
            ? (rig.bounds.zoom.maxDistance ?? (rig.distance * 2.0))
            : (rig?.distance ?? 4.0),
        minAzimuth = rig != null
            ? rig.bounds.azimuth.min * math.pi / 180.0
            : -35.0 * math.pi / 180.0,
        maxAzimuth = rig != null
            ? rig.bounds.azimuth.max * math.pi / 180.0
            : 35.0 * math.pi / 180.0,
        minElevation = rig != null
            ? rig.bounds.polar.min * math.pi / 180.0
            : -5.0 * math.pi / 180.0,
        maxElevation = rig != null
            ? rig.bounds.polar.max * math.pi / 180.0
            : 25.0 * math.pi / 180.0,
        zoomEnabled = rig != null ? rig.bounds.zoom.enabled : false,
        _radius = rig?.distance ?? 4.0,
        _azimuth = rig != null
            ? rig.defaultFraming.azimuthDeg * math.pi / 180.0
            : 0.0,
        _elevation = rig != null
            ? rig.defaultFraming.polarDeg * math.pi / 180.0
            : 10.0 * math.pi / 180.0;

  final View view;
  final InputSensitivityOptions sensitivity;
  final Vector3 targetPoint;
  final double minZoomDistance;
  final double maxZoomDistance;
  final double minAzimuth;
  final double maxAzimuth;
  final double minElevation;
  final double maxElevation;
  final bool zoomEnabled;
  final worldUp = Vector3(0, 1, 0);

  double _radius;
  double _radiusScaleFactor = 1.0;
  double _azimuth;
  double _elevation;

  bool _isMouseDown = false;
  Vector2? _lastPointerPosition;

  @override
  Future<void> handle(List<InputEvent> events) async {
    final activeCamera = await view.getCamera();

    double deltaAzimuth = 0;
    double deltaElevation = 0;
    double deltaRadius = 0;

    for (final event in events) {
      switch (event) {
        case ScrollEvent(delta: final scrollDelta):
          if (zoomEnabled) {
            deltaRadius += sensitivity.scrollWheelSensitivity * scrollDelta;
          }
          break;

        case MouseEvent(
            type: final type,
            button: final button,
            localPosition: final localPosition,
          ):
          switch (type) {
            case MouseEventType.buttonDown:
              if (button == MouseButton.left) {
                _isMouseDown = true;
                _lastPointerPosition = localPosition;
              }
              break;
            case MouseEventType.buttonUp:
              if (button == MouseButton.left) {
                _isMouseDown = false;
                _lastPointerPosition = null;
              }
              break;
            case MouseEventType.move:
            case MouseEventType.hover:
              if (_isMouseDown && _lastPointerPosition != null) {
                final dragDelta = localPosition - _lastPointerPosition!;
                deltaAzimuth -= dragDelta.x * sensitivity.mouseSensitivity;
                deltaElevation -= dragDelta.y * sensitivity.mouseSensitivity;
                _lastPointerPosition = localPosition;
              } else if (type == MouseEventType.hover) {
                _lastPointerPosition = localPosition;
              }
              break;
          }
          break;

        case TouchEvent():
          break;

        case ScaleUpdateEvent(
            numPointers: final numPointers,
            scale: final scaleFactor,
            localFocalPointDelta: final localFocalPointDelta,
          ):
          if (numPointers == 1) {
            if (localFocalPointDelta != null) {
              deltaAzimuth -=
                  localFocalPointDelta.$1 * sensitivity.touchSensitivity;
              deltaElevation -=
                  localFocalPointDelta.$2 * sensitivity.touchSensitivity;
            }
          } else if (zoomEnabled) {
            _radiusScaleFactor = scaleFactor;
          }
          break;

        case ScaleEndEvent():
          if (zoomEnabled) {
            _radius *= _radiusScaleFactor;
            _radiusScaleFactor = 1.0;
          }
          break;

        default:
          break;
      }
    }

    _azimuth += deltaAzimuth;
    _elevation += deltaElevation;
    if (zoomEnabled) {
      _radius += deltaRadius;
    }

    var radius = _radius * _radiusScaleFactor;

    // Clamp parameters
    _elevation = _elevation.clamp(minElevation, maxElevation);
    _azimuth = _azimuth.clamp(minAzimuth, maxAzimuth);
    if (zoomEnabled) {
      radius = radius.clamp(minZoomDistance, maxZoomDistance);
    } else {
      radius = _radius;
    }

    final double xOffset = radius * math.cos(_elevation) * math.sin(_azimuth);
    final double yOffset = radius * math.sin(_elevation);
    final double zOffset = radius * math.cos(_elevation) * math.cos(_azimuth);

    final cameraPosition = targetPoint + Vector3(xOffset, yOffset, zOffset);
    final modelMatrix = makeViewMatrix(cameraPosition, targetPoint, worldUp)
      ..invert();

    await activeCamera.setModelMatrix(modelMatrix);
  }
}
