// Dart projection of packages/content-schema/vignette_scene.schema.json
// (T-CONTENT-200 / T-CLIENT-201).
//
// A VignetteScene generalizes the parallax backdrop into a single composed,
// gently explorable 3D diorama: one environment plus placed props in a shared
// 3D space, each with its own transform (and optional anchor to another node),
// scene-level lighting, and a *bounded* camera rig. Presence, not assessment:
// exploration never gates a choice and is never fed to the trait engine.
//
// Plain Dart data + the small amount of transform math the renderer needs to
// turn authored TRS + anchor chains into per-asset world matrices. No Flutter
// imports, so it is unit-tested on the VM (see test/.../scene_models_test.dart).
// Hand-rolled to match the style of backdrop_models.dart.

import 'dart:math' as math;

/// A 4x4 transform as 16 doubles in **column-major** order — the glTF
/// `node.matrix` and `vector_math` `Matrix4` convention, so it can be handed to
/// either the web GLB composer or the native Thermion viewer without
/// re-ordering. `m[12..14]` is the translation column.
typedef SceneMatrix = List<double>;

/// All explorable scenes for a Season, keyed by vignette id.
class VignetteSceneManifest {
  const VignetteSceneManifest({required this.seasonId, required this.scenes});

  factory VignetteSceneManifest.fromJson(Map<String, dynamic> json) {
    return VignetteSceneManifest(
      seasonId: json['season_id'] as String,
      scenes: <VignetteScene>[
        for (final s in json['scenes'] as List<dynamic>)
          VignetteScene.fromJson(s as Map<String, dynamic>),
      ],
    );
  }

  final String seasonId;
  final List<VignetteScene> scenes;

  VignetteScene? forVignette(String vignetteId) {
    for (final s in scenes) {
      if (s.vignetteId == vignetteId) return s;
    }
    return null;
  }
}

class VignetteScene {
  const VignetteScene({
    required this.vignetteId,
    required this.environment,
    required this.camera,
    this.mood,
    this.props = const <PlacedAsset>[],
    this.lighting,
    this.assetBudget = const SceneAssetBudget(),
  });

  factory VignetteScene.fromJson(Map<String, dynamic> json) {
    return VignetteScene(
      vignetteId: json['vignette_id'] as String,
      mood: json['mood'] is Map<String, dynamic>
          ? SceneMood.fromJson(json['mood'] as Map<String, dynamic>)
          : null,
      environment: PlacedAsset.fromJson(
        json['environment'] as Map<String, dynamic>,
      ),
      props: <PlacedAsset>[
        for (final p in (json['props'] as List<dynamic>? ?? const <dynamic>[]))
          PlacedAsset.fromJson(p as Map<String, dynamic>),
      ],
      lighting: json['lighting'] is Map<String, dynamic>
          ? SceneLighting.fromJson(json['lighting'] as Map<String, dynamic>)
          : null,
      camera: CameraRig.fromJson(json['camera'] as Map<String, dynamic>),
      assetBudget: json['asset_budget'] is Map<String, dynamic>
          ? SceneAssetBudget.fromJson(
              json['asset_budget'] as Map<String, dynamic>,
            )
          : const SceneAssetBudget(),
    );
  }

  final String vignetteId;
  final SceneMood? mood;
  final PlacedAsset environment;
  final List<PlacedAsset> props;
  final SceneLighting? lighting;
  final CameraRig camera;
  final SceneAssetBudget assetBudget;

  /// The environment followed by every prop, in authored order. The
  /// environment is first so a constrained asset budget spends on it before
  /// the props (it is the asset that defines the space).
  List<PlacedAsset> get placedAssets => <PlacedAsset>[environment, ...props];

  /// Resolve every node's **world** matrix by composing its local TRS with its
  /// anchor's world matrix (recursively). A missing or cyclic anchor degrades
  /// to treating the node as a scene root rather than throwing — the renderer
  /// must never crash on authored data. Order matches [placedAssets].
  List<ResolvedPlacement> resolvePlacements() {
    final byId = <String, PlacedAsset>{
      for (final a in placedAssets) a.id: a,
    };
    final worldById = <String, SceneMatrix>{};

    SceneMatrix worldFor(String id, Set<String> visiting) {
      final cached = worldById[id];
      if (cached != null) return cached;
      final asset = byId[id];
      if (asset == null) return identityMatrix();
      final local = asset.transform.toMatrix();
      final anchor = asset.anchor;
      SceneMatrix world;
      if (anchor == null ||
          anchor == id ||
          !byId.containsKey(anchor) ||
          visiting.contains(anchor)) {
        world = local; // root, self-anchor, missing, or cycle → no parent
      } else {
        world = multiplyMatrix(worldFor(anchor, {...visiting, id}), local);
      }
      worldById[id] = world;
      return world;
    }

    return <ResolvedPlacement>[
      for (final a in placedAssets)
        ResolvedPlacement(asset: a, worldMatrix: worldFor(a.id, <String>{})),
    ];
  }
}

/// A placed asset with its resolved world transform.
class ResolvedPlacement {
  const ResolvedPlacement({required this.asset, required this.worldMatrix});

  final PlacedAsset asset;
  final SceneMatrix worldMatrix;
}

class PlacedAsset {
  const PlacedAsset({
    required this.id,
    required this.assetId,
    required this.transform,
    this.anchor,
    this.interactive = false,
    this.notice,
  });

  factory PlacedAsset.fromJson(Map<String, dynamic> json) {
    return PlacedAsset(
      id: json['id'] as String,
      assetId: json['asset_id'] as String,
      anchor: json['anchor'] as String?,
      transform: json['transform'] is Map<String, dynamic>
          ? SceneTransform.fromJson(json['transform'] as Map<String, dynamic>)
          : const SceneTransform(),
      interactive: json['interactive'] as bool? ?? false,
      notice: json['notice'] is Map<String, dynamic>
          ? SceneNotice.fromJson(json['notice'] as Map<String, dynamic>)
          : null,
    );
  }

  final String id;
  final String assetId;

  /// Another node id this asset's transform is relative to, or null for a root.
  final String? anchor;
  final SceneTransform transform;

  /// Tap-to-inspect "noticing point". Calm and optional — never gates a choice
  /// and never feeds the trait engine.
  final bool interactive;
  final SceneNotice? notice;
}

class SceneTransform {
  const SceneTransform({
    this.position = const <double>[0, 0, 0],
    this.rotationDeg = const <double>[0, 0, 0],
    this.scale = const <double>[1, 1, 1],
  });

  factory SceneTransform.fromJson(Map<String, dynamic> json) {
    return SceneTransform(
      position: _vec3(json['position'], const <double>[0, 0, 0]),
      rotationDeg: _vec3(json['rotation_deg'], const <double>[0, 0, 0]),
      scale: _scale(json['scale']),
    );
  }

  /// Local position in meters [x, y, z].
  final List<double> position;

  /// Euler rotation in degrees [x, y, z].
  final List<double> rotationDeg;

  /// Per-axis scale [x, y, z]. A scalar scale is normalized to three axes here.
  final List<double> scale;

  /// Build the local transform as a column-major matrix `T * R * S`. Rotation
  /// uses the Three.js intrinsic `XYZ` Euler convention so the matrix the web
  /// composer bakes into `node.matrix` is interpreted identically by
  /// `<model-viewer>` (Three.js) and the native viewer.
  SceneMatrix toMatrix() {
    final rx = _rad(rotationDeg[0]);
    final ry = _rad(rotationDeg[1]);
    final rz = _rad(rotationDeg[2]);
    final c1 = math.cos(rx), s1 = math.sin(rx);
    final c2 = math.cos(ry), s2 = math.sin(ry);
    final c3 = math.cos(rz), s3 = math.sin(rz);

    // Rotation (column-major elements, Three.js makeRotationFromEuler 'XYZ').
    final r00 = c2 * c3;
    final r10 = c1 * s3 + s1 * s2 * c3;
    final r20 = s1 * s3 - c1 * s2 * c3;
    final r01 = -c2 * s3;
    final r11 = c1 * c3 - s1 * s2 * s3;
    final r21 = s1 * c3 + c1 * s2 * s3;
    final r02 = s2;
    final r12 = -s1 * c2;
    final r22 = c1 * c2;

    final kx = scale[0], ky = scale[1], kz = scale[2];
    return <double>[
      r00 * kx, r10 * kx, r20 * kx, 0, // column 0
      r01 * ky, r11 * ky, r21 * ky, 0, // column 1
      r02 * kz, r12 * kz, r22 * kz, 0, // column 2
      position[0], position[1], position[2], 1, // column 3 (translation)
    ];
  }
}

class SceneAssetBudget {
  const SceneAssetBudget({
    this.maxPolycount = 120000,
    this.maxSizeBytes = 30 * 1024 * 1024,
  });

  factory SceneAssetBudget.fromJson(Map<String, dynamic> json) {
    return SceneAssetBudget(
      maxPolycount: (json['max_polycount'] as num?)?.toInt() ?? 120000,
      maxSizeBytes:
          (json['max_size_bytes'] as num?)?.toInt() ?? 30 * 1024 * 1024,
    );
  }

  final int maxPolycount;
  final int maxSizeBytes;
}

class SceneMood {
  const SceneMood({this.timeOfDay, this.weather, this.palette});

  factory SceneMood.fromJson(Map<String, dynamic> json) {
    return SceneMood(
      timeOfDay: json['time_of_day'] as String?,
      weather: json['weather'] as String?,
      palette: json['palette'] as String?,
    );
  }

  final String? timeOfDay;
  final String? weather;
  final String? palette;
}

class SceneNotice {
  const SceneNotice({required this.label, this.body});

  factory SceneNotice.fromJson(Map<String, dynamic> json) {
    return SceneNotice(
      label: json['label'] as String,
      body: json['body'] as String?,
    );
  }

  final String label;
  final String? body;
}

class SceneLighting {
  const SceneLighting({
    this.preset,
    this.intensity,
    this.ambient,
    this.color,
    this.direction,
  });

  factory SceneLighting.fromJson(Map<String, dynamic> json) {
    return SceneLighting(
      preset: json['preset'] as String?,
      intensity: (json['intensity'] as num?)?.toDouble(),
      ambient: (json['ambient'] as num?)?.toDouble(),
      color: json['color'] as String?,
      direction: json['direction'] is Map<String, dynamic>
          ? LightDirection.fromJson(json['direction'] as Map<String, dynamic>)
          : null,
    );
  }

  final String? preset;
  final double? intensity;
  final double? ambient;

  /// Key-light color, `#rrggbb`.
  final String? color;
  final LightDirection? direction;
}

class LightDirection {
  const LightDirection({this.azimuthDeg = 0, this.elevationDeg = 45});

  factory LightDirection.fromJson(Map<String, dynamic> json) {
    return LightDirection(
      azimuthDeg: (json['azimuth_deg'] as num?)?.toDouble() ?? 0,
      elevationDeg: (json['elevation_deg'] as num?)?.toDouble() ?? 45,
    );
  }

  final double azimuthDeg;
  final double elevationDeg;
}

/// Bounded orbit rig. The renderer clamps free-look to [bounds]; exploration is
/// always calm and restrained (the Monument-Valley reference, never a free-fly
/// camera). See docs/04_Game_Design.md "explorable 3D scene".
class CameraRig {
  const CameraRig({
    required this.lookAt,
    required this.distance,
    required this.defaultFraming,
    required this.bounds,
  });

  factory CameraRig.fromJson(Map<String, dynamic> json) {
    return CameraRig(
      lookAt: _vec3(json['look_at'], const <double>[0, 0, 0]),
      distance: (json['distance'] as num).toDouble(),
      defaultFraming: CameraFraming.fromJson(
        json['default_framing'] as Map<String, dynamic>,
      ),
      bounds: CameraBounds.fromJson(json['bounds'] as Map<String, dynamic>),
    );
  }

  /// World-space focal point the camera orbits, in meters.
  final List<double> lookAt;

  /// Camera distance from [lookAt], in meters.
  final double distance;
  final CameraFraming defaultFraming;
  final CameraBounds bounds;
}

class CameraFraming {
  const CameraFraming({required this.azimuthDeg, required this.polarDeg});

  factory CameraFraming.fromJson(Map<String, dynamic> json) {
    return CameraFraming(
      azimuthDeg: (json['azimuth_deg'] as num).toDouble(),
      polarDeg: (json['polar_deg'] as num).toDouble(),
    );
  }

  /// Yaw around the look-at point, in degrees.
  final double azimuthDeg;

  /// Pitch from horizontal, in degrees (0 = horizon, + = above).
  final double polarDeg;
}

class CameraBounds {
  const CameraBounds({
    required this.azimuth,
    required this.polar,
    this.zoom = const ZoomBounds(),
  });

  factory CameraBounds.fromJson(Map<String, dynamic> json) {
    return CameraBounds(
      azimuth: Range.fromJson(json['azimuth_deg'] as Map<String, dynamic>),
      polar: Range.fromJson(json['polar_deg'] as Map<String, dynamic>),
      zoom: json['zoom'] is Map<String, dynamic>
          ? ZoomBounds.fromJson(json['zoom'] as Map<String, dynamic>)
          : const ZoomBounds(),
    );
  }

  final Range azimuth;
  final Range polar;
  final ZoomBounds zoom;
}

class Range {
  const Range({required this.min, required this.max});

  factory Range.fromJson(Map<String, dynamic> json) {
    return Range(
      min: (json['min'] as num).toDouble(),
      max: (json['max'] as num).toDouble(),
    );
  }

  final double min;
  final double max;
}

/// Dolly bounds. Disabled by default — T-CLIENT-200 keeps exploration to
/// clamped orbit with no zoom unless a scene explicitly enables it.
class ZoomBounds {
  const ZoomBounds({this.enabled = false, this.minDistance, this.maxDistance});

  factory ZoomBounds.fromJson(Map<String, dynamic> json) {
    return ZoomBounds(
      enabled: json['enabled'] as bool? ?? false,
      minDistance: (json['min_distance'] as num?)?.toDouble(),
      maxDistance: (json['max_distance'] as num?)?.toDouble(),
    );
  }

  final bool enabled;
  final double? minDistance;
  final double? maxDistance;
}

// --------------------------------------------------------------------------- //
// Matrix helpers (column-major, glTF / vector_math convention)
// --------------------------------------------------------------------------- //

/// The 4x4 identity as a column-major [SceneMatrix].
SceneMatrix identityMatrix() => <double>[
      1, 0, 0, 0, //
      0, 1, 0, 0,
      0, 0, 1, 0,
      0, 0, 0, 1,
    ];

/// Column-major 4x4 product `a * b` (applies `b` then `a`).
SceneMatrix multiplyMatrix(SceneMatrix a, SceneMatrix b) {
  final out = List<double>.filled(16, 0.0);
  for (var col = 0; col < 4; col++) {
    for (var row = 0; row < 4; row++) {
      var sum = 0.0;
      for (var k = 0; k < 4; k++) {
        sum += a[k * 4 + row] * b[col * 4 + k];
      }
      out[col * 4 + row] = sum;
    }
  }
  return out;
}

/// Translation-only column-major matrix. Used to express the legacy parallax
/// placement (`z = -depth/100`) as a world matrix so the renderers have a
/// single transform code path.
SceneMatrix translationMatrix(double x, double y, double z) => <double>[
      1, 0, 0, 0, //
      0, 1, 0, 0,
      0, 0, 1, 0,
      x, y, z, 1,
    ];

double _rad(double deg) => deg * math.pi / 180.0;

List<double> _vec3(Object? raw, List<double> fallback) {
  if (raw is List && raw.length >= 3) {
    return <double>[
      (raw[0] as num).toDouble(),
      (raw[1] as num).toDouble(),
      (raw[2] as num).toDouble(),
    ];
  }
  return fallback;
}

List<double> _scale(Object? raw) {
  if (raw is num) {
    final v = raw.toDouble();
    return <double>[v, v, v];
  }
  if (raw is List && raw.length >= 3) {
    return <double>[
      (raw[0] as num).toDouble(),
      (raw[1] as num).toDouble(),
      (raw[2] as num).toDouble(),
    ];
  }
  return const <double>[1, 1, 1];
}
