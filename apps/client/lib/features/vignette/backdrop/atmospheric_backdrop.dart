// AtmosphericBackdrop — the continuous, always-alive layer behind a vignette
// (T-CLIENT-041).
//
// The backdrop's job is to keep the world *living* while the player thinks.
// It runs forever — no start/stop tied to vignette state — composing parallax
// layers from a [BackdropSpec] with continuous ambient motion (drift, pulse,
// particles, parallax-breathe) and damped pointer-driven parallax.
//
// This widget renders the 2D fallback path. The Thermion/Filament + glTF
// renderer (T-CLIENT-040) plugs in by replacing `_LayerVisual`'s draw routine
// with a GLB-backed scene; everything else (the animation driver, parallax
// math, transitions) is unchanged. Asset binaries themselves are fetched and
// cached by a separate asset loader, which is not in M1 scope.
//
// Usage:
//   Stack(
//     children: <Widget>[
//       Positioned.fill(child: AtmosphericBackdrop(spec: spec)),
//       Positioned.fill(child: vignetteContent),
//     ],
//   )

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

import 'backdrop_models.dart';

class AtmosphericBackdrop extends StatefulWidget {
  const AtmosphericBackdrop({
    required this.spec,
    this.parallaxEnabled = true,
    super.key,
  });

  final BackdropSpec spec;

  /// Set to false to suppress pointer-driven parallax (e.g. on a desktop
  /// build where the cursor is far from the surface, or for accessibility).
  /// Ambient motion always runs.
  final bool parallaxEnabled;

  @override
  State<AtmosphericBackdrop> createState() => _AtmosphericBackdropState();
}

class _AtmosphericBackdropState extends State<AtmosphericBackdrop>
    with SingleTickerProviderStateMixin {
  // A single long-running ticker drives every ambient effect. Each effect
  // computes its phase from elapsed time + its own period, so there is one
  // animation, not N — keeps the cost flat as layers grow.
  late final AnimationController _ticker;

  // Normalized pointer offset in [-1, 1] for x and y. Lazily smoothed toward
  // the latest pointer position so movement feels alive but never jittery.
  Offset _pointer = Offset.zero;
  Offset _smoothedPointer = Offset.zero;

  @override
  void initState() {
    super.initState();
    // Period is arbitrary; we only use elapsed time, not the controller value.
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    _ticker.addListener(_advancePointerSmoothing);
  }

  @override
  void dispose() {
    _ticker
      ..removeListener(_advancePointerSmoothing)
      ..dispose();
    super.dispose();
  }

  void _advancePointerSmoothing() {
    // Critically-damped smoothing. ~0.08 per frame is gentle (full settle in
    // ~30 frames @ 60Hz, ~0.5s).
    final next = Offset(
      _smoothedPointer.dx + (_pointer.dx - _smoothedPointer.dx) * 0.08,
      _smoothedPointer.dy + (_pointer.dy - _smoothedPointer.dy) * 0.08,
    );
    if ((next - _smoothedPointer).distanceSquared > 1e-6) {
      setState(() => _smoothedPointer = next);
    }
  }

  void _handlePointer(PointerEvent e, Size size) {
    if (!widget.parallaxEnabled) return;
    if (size.width <= 0 || size.height <= 0) return;
    final nx = (e.position.dx / size.width) * 2 - 1;
    final ny = (e.position.dy / size.height) * 2 - 1;
    _pointer = Offset(nx.clamp(-1.0, 1.0), ny.clamp(-1.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final layers = widget.spec.layersBackToFront;
        final sensitivity = widget.spec.camera.sensitivity;

        return MouseRegion(
          // Use the generic PointerEvent so we don't need to import the
          // specific subtypes; _handlePointer already takes PointerEvent.
          onHover: (PointerEvent e) => _handlePointer(e, size),
          child: Listener(
            onPointerMove: (PointerEvent e) => _handlePointer(e, size),
            behavior: HitTestBehavior.translucent,
            child: AnimatedBuilder(
              animation: _ticker,
              builder: (BuildContext _, Widget? __) {
                final t = _ticker.lastElapsedDuration ?? Duration.zero;
                final tMs = t.inMicroseconds / 1000.0;
                return RepaintBoundary(
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      _MoodWash(mood: widget.spec.mood),
                      for (final layer in layers)
                        _LayerVisual(
                          layer: layer,
                          tMs: tMs,
                          pointer: _smoothedPointer,
                          sensitivity: sensitivity,
                          cameraMode: widget.spec.camera.mode,
                          size: size,
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// A flat color/gradient wash keyed by the mood. Cheap; always under the
/// layers. Real time-of-day grading happens in a shader once 3D lands.
class _MoodWash extends StatelessWidget {
  const _MoodWash({required this.mood});

  final MoodSpec? mood;

  @override
  Widget build(BuildContext context) {
    final colors = _washColors(mood);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
        ),
      ),
    );
  }

  static List<Color> _washColors(MoodSpec? mood) {
    switch (mood?.timeOfDay) {
      case 'dawn':
        return const <Color>[Color(0xFFFCD9B6), Color(0xFFE99A8D)];
      case 'morning':
        return const <Color>[Color(0xFFE8F0FA), Color(0xFFB7D2E8)];
      case 'midday':
        return const <Color>[Color(0xFFCDE4F4), Color(0xFFEAF1F5)];
      case 'afternoon':
        return const <Color>[Color(0xFFF4E4C7), Color(0xFFD7B98F)];
      case 'evening':
        return const <Color>[Color(0xFFD3B7C5), Color(0xFF6F5C8A)];
      case 'dusk':
        return const <Color>[Color(0xFFB17BA6), Color(0xFF2D3050)];
      case 'night':
        return const <Color>[Color(0xFF13182B), Color(0xFF050811)];
      default:
        return const <Color>[Color(0xFFE9EEF3), Color(0xFFBCC7D2)];
    }
  }
}

class _LayerVisual extends StatelessWidget {
  const _LayerVisual({
    required this.layer,
    required this.tMs,
    required this.pointer,
    required this.sensitivity,
    required this.cameraMode,
    required this.size,
  });

  final BackdropLayer layer;
  final double tMs;
  final Offset pointer;
  final double sensitivity;
  final CameraMode cameraMode;
  final Size size;

  @override
  Widget build(BuildContext context) {
    // Closer layers (low depth) move further; far layers stay put. The
    // pointer drives camera_mode=parallax; for camera_mode=static we still
    // let ambient motion run, but the pointer is ignored. Orbital mode
    // applies a slow circular sweep based on elapsed time.
    final closeness = 1.0 - layer.parallaxWeight; // 0..1
    Offset cameraOffset = Offset.zero;
    if (cameraMode == CameraMode.parallax) {
      final magnitude = 30.0 * sensitivity * closeness; // px at full deflection
      cameraOffset = -pointer * magnitude;
    } else if (cameraMode == CameraMode.orbital) {
      final phase = 2 * math.pi * (tMs / 24000.0);
      final r = 18.0 * sensitivity * closeness;
      cameraOffset = Offset(math.cos(phase) * r, math.sin(phase) * r);
    }

    // Ambient additions.
    var dx = cameraOffset.dx;
    var dy = cameraOffset.dy;
    var opacity = layer.opacity;
    var depthScale = 1.0;

    for (final effect in layer.ambient) {
      if (effect is DriftEffect) {
        final phase = 2 * math.pi * (tMs / effect.periodMs);
        final v = math.sin(phase) * effect.amplitudePx;
        if (effect.axis == 'y') {
          dy += v;
        } else {
          dx += v;
        }
      } else if (effect is PulseEffect) {
        final phase = 2 * math.pi * (tMs / effect.periodMs);
        opacity = (opacity + math.sin(phase) * effect.amplitude).clamp(0.0, 1.0);
      } else if (effect is ParallaxBreatheEffect) {
        final phase = 2 * math.pi * (tMs / effect.periodMs);
        depthScale = 1.0 + math.sin(phase) * effect.amplitude;
      } else if (effect is ParticlesEffect) {
        // Particles are drawn by the painter; nothing to accumulate here.
      }
    }

    final particles = <ParticlesEffect>[
      for (final e in layer.ambient)
        if (e is ParticlesEffect) e,
    ];

    return Positioned.fill(
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(dx, dy),
          child: Transform.scale(
            scale: depthScale,
            child: CustomPaint(
              size: size,
              painter: _LayerPainter(
                layer: layer,
                tMs: tMs,
                particles: particles,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 2D placeholder painter. Produces a stable, asset-keyed silhouette so the
/// scene reads as composed layers even before real GLB assets are loaded.
/// Replace with a Thermion (Filament) scene per T-CLIENT-040.
class _LayerPainter extends CustomPainter {
  _LayerPainter({
    required this.layer,
    required this.tMs,
    required this.particles,
  });

  final BackdropLayer layer;
  final double tMs;
  final List<ParticlesEffect> particles;

  @override
  void paint(Canvas canvas, Size size) {
    final tint = _tintForAsset(layer.assetId);
    final paint = Paint()..color = tint.withValues(alpha: 0.85);
    final h = size.height * (0.45 + (layer.parallaxWeight * 0.45));
    final rect = Rect.fromLTWH(0, size.height - h, size.width, h);
    canvas.drawRect(rect, paint);

    for (final p in particles) {
      _drawParticles(canvas, size, p);
    }
  }

  void _drawParticles(Canvas canvas, Size size, ParticlesEffect effect) {
    // A small, stable jitter field per effect kind. Count is mapped from
    // density; positions are seeded by asset+layer id so each layer's field
    // is consistent across frames. Motion advances with tMs.
    final count = (40 + effect.density * 120).round();
    final seed = (layer.id.hashCode ^ effect.kind.hashCode) & 0x7fffffff;
    final rng = math.Random(seed);
    final paint = Paint()..color = _particleColor(effect.kind);
    for (var i = 0; i < count; i++) {
      final baseX = rng.nextDouble() * size.width;
      final baseY = rng.nextDouble() * size.height;
      final phase = rng.nextDouble() * 2 * math.pi;
      final speed = _particleSpeed(effect.kind);
      final wobble =
          math.sin(phase + tMs / 1800.0) * _particleWobble(effect.kind);
      final fall = (tMs * speed) % size.height;
      final x = baseX + wobble;
      final y = effect.kind == 'rain' || effect.kind == 'snow'
          ? (baseY + fall) % size.height
          : baseY + math.sin(phase + tMs / 2200.0) * 6;
      final r = _particleRadius(effect.kind);
      if (effect.kind == 'rain') {
        canvas.drawLine(Offset(x, y), Offset(x - 1, y + 6), paint);
      } else {
        canvas.drawCircle(Offset(x, y), r, paint);
      }
    }
  }

  Color _particleColor(String kind) {
    switch (kind) {
      case 'rain':
        return const Color(0xFFAEC7E5).withValues(alpha: 0.45);
      case 'snow':
        return const Color(0xFFF6FBFF).withValues(alpha: 0.65);
      case 'embers':
        return const Color(0xFFFFB377).withValues(alpha: 0.75);
      case 'fireflies':
        return const Color(0xFFFFEAA8).withValues(alpha: 0.7);
      case 'dust_motes':
      default:
        return const Color(0xFFFFE9C2).withValues(alpha: 0.4);
    }
  }

  double _particleSpeed(String kind) {
    switch (kind) {
      case 'rain':
        return 0.22;
      case 'snow':
        return 0.04;
      default:
        return 0.0;
    }
  }

  double _particleWobble(String kind) {
    switch (kind) {
      case 'snow':
        return 12;
      case 'dust_motes':
        return 4;
      default:
        return 2;
    }
  }

  double _particleRadius(String kind) {
    switch (kind) {
      case 'snow':
        return 1.6;
      case 'embers':
      case 'fireflies':
        return 1.2;
      default:
        return 0.9;
    }
  }

  Color _tintForAsset(String assetId) {
    // Deterministic tint from the asset id. Stable across frames; an
    // asset-set author can override by changing the asset id. Real visuals
    // come from the GLB; this is the renderer skeleton.
    final h = assetId.hashCode & 0x7fffffff;
    final hue = (h % 360).toDouble();
    return HSLColor.fromAHSL(1.0, hue, 0.18, 0.45).toColor();
  }

  @override
  bool shouldRepaint(covariant _LayerPainter old) =>
      old.tMs != tMs || old.layer != layer;
}
