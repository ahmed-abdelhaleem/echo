// Dart projection of packages/content-schema/vignette_backdrop.schema.json.
//
// A VignetteBackdrop describes the atmospheric scene that lives behind a
// vignette's choice UI: layered, parallaxed, and continuously animated so the
// world never freezes while the player thinks. Rendering lives in
// [AtmosphericBackdrop]; this file is plain Dart data only (no Flutter).
//
// Hand-rolled rather than codegen'd to match the style of data/models/content.
// When the schema gains optional fields, add nullable getters here rather than
// running a generator.

/// All backdrops for a Season, keyed by vignette id.
class BackdropManifest {
  const BackdropManifest({required this.seasonId, required this.backdrops});

  factory BackdropManifest.fromJson(Map<String, dynamic> json) {
    return BackdropManifest(
      seasonId: json['season_id'] as String,
      backdrops: <BackdropSpec>[
        for (final b in json['backdrops'] as List<dynamic>)
          BackdropSpec.fromJson(b as Map<String, dynamic>),
      ],
    );
  }

  final String seasonId;
  final List<BackdropSpec> backdrops;

  BackdropSpec? forVignette(String vignetteId) {
    for (final b in backdrops) {
      if (b.vignetteId == vignetteId) return b;
    }
    return null;
  }
}

class BackdropSpec {
  const BackdropSpec({
    required this.vignetteId,
    required this.layers,
    this.mood,
    this.camera = const CameraSpec(),
    this.transition = const TransitionSpec(),
  });

  factory BackdropSpec.fromJson(Map<String, dynamic> json) {
    return BackdropSpec(
      vignetteId: json['vignette_id'] as String,
      mood: json['mood'] is Map<String, dynamic>
          ? MoodSpec.fromJson(json['mood'] as Map<String, dynamic>)
          : null,
      camera: json['camera'] is Map<String, dynamic>
          ? CameraSpec.fromJson(json['camera'] as Map<String, dynamic>)
          : const CameraSpec(),
      transition: json['transition'] is Map<String, dynamic>
          ? TransitionSpec.fromJson(json['transition'] as Map<String, dynamic>)
          : const TransitionSpec(),
      layers: <BackdropLayer>[
        for (final l in json['layers'] as List<dynamic>)
          BackdropLayer.fromJson(l as Map<String, dynamic>),
      ],
    );
  }

  final String vignetteId;
  final MoodSpec? mood;
  final CameraSpec camera;
  final TransitionSpec transition;
  final List<BackdropLayer> layers;

  /// Layers sorted back-to-front (descending parallax depth) for painter's order.
  List<BackdropLayer> get layersBackToFront {
    final sorted = List<BackdropLayer>.of(layers)
      ..sort((BackdropLayer a, BackdropLayer b) =>
          b.parallaxDepth.compareTo(a.parallaxDepth));
    return sorted;
  }
}

enum CameraMode { parallax, orbital, static }

CameraMode _cameraModeFromString(String s) {
  switch (s) {
    case 'orbital':
      return CameraMode.orbital;
    case 'static':
      return CameraMode.static;
    case 'parallax':
    default:
      return CameraMode.parallax;
  }
}

class CameraSpec {
  const CameraSpec({this.mode = CameraMode.parallax, this.sensitivity = 0.4});

  factory CameraSpec.fromJson(Map<String, dynamic> json) {
    return CameraSpec(
      mode: _cameraModeFromString((json['mode'] as String?) ?? 'parallax'),
      sensitivity: (json['sensitivity'] as num?)?.toDouble() ?? 0.4,
    );
  }

  final CameraMode mode;
  final double sensitivity;
}

class MoodSpec {
  const MoodSpec({this.timeOfDay, this.weather, this.palette});

  factory MoodSpec.fromJson(Map<String, dynamic> json) {
    return MoodSpec(
      timeOfDay: json['time_of_day'] as String?,
      weather: json['weather'] as String?,
      palette: json['palette'] as String?,
    );
  }

  final String? timeOfDay;
  final String? weather;
  final String? palette;
}

enum TransitionCurve { linear, easeIn, easeOut, easeInOut }

TransitionCurve _curveFromString(String s) {
  switch (s) {
    case 'linear':
      return TransitionCurve.linear;
    case 'ease_in':
      return TransitionCurve.easeIn;
    case 'ease_in_out':
      return TransitionCurve.easeInOut;
    case 'ease_out':
    default:
      return TransitionCurve.easeOut;
  }
}

class TransitionSpec {
  const TransitionSpec({
    this.inMs = 800,
    this.outMs = 600,
    this.curve = TransitionCurve.easeOut,
  });

  factory TransitionSpec.fromJson(Map<String, dynamic> json) {
    return TransitionSpec(
      inMs: (json['in_ms'] as num?)?.toInt() ?? 800,
      outMs: (json['out_ms'] as num?)?.toInt() ?? 600,
      curve: _curveFromString((json['curve'] as String?) ?? 'ease_out'),
    );
  }

  final int inMs;
  final int outMs;
  final TransitionCurve curve;
}

class BackdropLayer {
  const BackdropLayer({
    required this.id,
    required this.assetId,
    required this.parallaxDepth,
    this.opacity = 1.0,
    this.ambient = const <AmbientEffect>[],
  });

  factory BackdropLayer.fromJson(Map<String, dynamic> json) {
    final ambientJson = json['ambient'];
    return BackdropLayer(
      id: json['id'] as String,
      assetId: json['asset_id'] as String,
      parallaxDepth: (json['parallax_depth'] as num).toDouble(),
      opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
      ambient: ambientJson is List<dynamic>
          ? <AmbientEffect>[
              for (final a in ambientJson)
                AmbientEffect.fromJson(a as Map<String, dynamic>),
            ]
          : const <AmbientEffect>[],
    );
  }

  final String id;
  final String assetId;

  /// 0 = at camera (largest motion); 100 = at infinity (no motion).
  final double parallaxDepth;
  final double opacity;
  final List<AmbientEffect> ambient;

  /// Parallax weight in [0, 1]. 0 means "moves with camera 1:1" (closest);
  /// 1 means "does not move" (furthest).
  double get parallaxWeight => (parallaxDepth.clamp(0, 100)) / 100.0;
}

/// One continuous animation applied to a layer. Sealed by name; the renderer
/// switches on [type].
abstract class AmbientEffect {
  const AmbientEffect();

  String get type;

  factory AmbientEffect.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    switch (type) {
      case 'drift':
        return DriftEffect.fromJson(json);
      case 'pulse':
        return PulseEffect.fromJson(json);
      case 'particles':
        return ParticlesEffect.fromJson(json);
      case 'parallax_breathe':
        return ParallaxBreatheEffect.fromJson(json);
      default:
        throw FormatException('Unknown ambient effect type: $type');
    }
  }
}

class DriftEffect extends AmbientEffect {
  const DriftEffect({
    required this.axis,
    required this.amplitudePx,
    required this.periodMs,
  });

  factory DriftEffect.fromJson(Map<String, dynamic> json) {
    return DriftEffect(
      axis: (json['axis'] as String?) ?? 'x',
      amplitudePx: (json['amplitude_px'] as num).toDouble(),
      periodMs: (json['period_ms'] as num).toInt(),
    );
  }

  @override
  String get type => 'drift';

  /// 'x' or 'y'.
  final String axis;
  final double amplitudePx;
  final int periodMs;
}

class PulseEffect extends AmbientEffect {
  const PulseEffect({required this.amplitude, required this.periodMs});

  factory PulseEffect.fromJson(Map<String, dynamic> json) {
    return PulseEffect(
      amplitude: (json['amplitude'] as num).toDouble(),
      periodMs: (json['period_ms'] as num).toInt(),
    );
  }

  @override
  String get type => 'pulse';

  final double amplitude;
  final int periodMs;
}

class ParticlesEffect extends AmbientEffect {
  const ParticlesEffect({required this.kind, required this.density});

  factory ParticlesEffect.fromJson(Map<String, dynamic> json) {
    return ParticlesEffect(
      kind: (json['kind'] as String?) ?? 'dust_motes',
      density: (json['density'] as num).toDouble(),
    );
  }

  @override
  String get type => 'particles';

  final String kind;
  final double density;
}

class ParallaxBreatheEffect extends AmbientEffect {
  const ParallaxBreatheEffect({
    required this.amplitude,
    required this.periodMs,
  });

  factory ParallaxBreatheEffect.fromJson(Map<String, dynamic> json) {
    return ParallaxBreatheEffect(
      amplitude: (json['amplitude'] as num).toDouble(),
      periodMs: (json['period_ms'] as num).toInt(),
    );
  }

  @override
  String get type => 'parallax_breathe';

  final double amplitude;
  final int periodMs;
}
