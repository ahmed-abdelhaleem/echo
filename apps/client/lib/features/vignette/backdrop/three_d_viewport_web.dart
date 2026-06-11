import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:echo_client/features/vignette/assets/asset_models.dart';
import 'package:echo_client/features/vignette/backdrop/glb_scene_composer.dart';
import 'package:echo_client/features/vignette/backdrop/three_d_debug.dart';
import 'package:flutter/material.dart';

// This is the web-only viewport, selected by the conditional import in
// three_d_viewport.dart (`if (dart.library.js_interop)`) and compiled only for
// web. Using dart:html here is intentional and never reaches a non-web build,
// so the two lints below — which guard against web libraries leaking into
// cross-platform code — do not apply to a platform-specific file like this.
// CHOICE: dart:html. Alternative considered: package:web + dart:js_interop (the
// non-deprecated path) — deferred because it would promote package:web to a
// direct dependency (an AGENTS.md dependency escalation) for a dev viewport.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

// Web 3D viewport.
//
// We create the <model-viewer> custom element directly through the platform
// view registry rather than going through model_viewer_plus's ModelViewer
// widget (which embeds an entire HTML document via innerHTML and exposes no
// load/error hooks). The <model-viewer> custom element is defined globally by
// the model-viewer script in web/index.html, so creating the bare element here
// is sufficient — and it lets us attach load/error listeners for diagnostics.
//
// CHOICE: direct element + dart:html. Alternative considered: keep
// model_viewer_plus's widget — rejected because it produced no visible result
// and gives no way to observe whether the model actually loaded.

// registerViewFactory throws if the same viewType is registered twice, so we
// register once per distinct source (keyed by its hash). Distinct GLBs are
// few in practice; the placeholder collapses to a single registration.
final Set<String> _registeredViewTypes = <String>{};

Widget buildThreeDViewport(BuildContext context, AssetScene scene) {
  // T-CLIENT-201: render the FULL composed scene on web. We merge every layer's
  // GLB into one model and place each by parallax depth; if composition isn't
  // possible (only one asset, or a GLB the composer can't merge losslessly) we
  // fall back to the first asset so the scene still renders.
  final src = _composedOrFirstSrc(scene);
  // Honor the OS "reduce motion" preference: flatten to a still framing with no
  // look-around (F-CORE-007 accessibility requirement). The flag is part of the
  // viewType key so toggling it re-registers a correctly-configured element.
  final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
  final viewType =
      'echo-model-viewer-${src.hashCode}-${reduceMotion ? 'still' : 'look'}';

  if (kEcho3dDebug) {
    final head = src.length > 64 ? '${src.substring(0, 64)}…' : src;
    debugPrint(
      '[echo3d] web viewport build; viewType=$viewType '
      'reduceMotion=$reduceMotion src=$head',
    );
  }

  if (_registeredViewTypes.add(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      final modelViewer = html.Element.tag('model-viewer')
        ..setAttribute('src', src)
        ..setAttribute('alt', 'Explorable vignette scene')
        ..setAttribute('loading', 'eager')
        ..setAttribute('reveal', 'auto')
        ..setAttribute('interaction-prompt', 'none');
      if (reduceMotion) {
        // Still framing — no orbit, no auto-motion.
        modelViewer
          ..setAttribute('disable-zoom', '')
          ..setAttribute('disable-pan', '')
          ..setAttribute('disable-tap', '');
      } else {
        // Bounded, damped free-look: drag to look around within limits; no
        // zoom/pan (calm, restrained — the Monument-Valley reference, not a
        // free-fly camera). See 04_Game_Design → "explorable 3D scene".
        modelViewer
          ..setAttribute('camera-controls', '')
          ..setAttribute('disable-zoom', '')
          ..setAttribute('disable-pan', '')
          ..setAttribute('camera-orbit', '0deg 80deg 105%')
          ..setAttribute('min-camera-orbit', '-35deg 65deg auto')
          ..setAttribute('max-camera-orbit', '35deg 95deg auto')
          ..setAttribute('interpolation-decay', '200');
        if (kEcho3dDebug) {
          modelViewer.setAttribute('auto-rotate', '');
        }
      }
      modelViewer.style
        ..width = '100%'
        ..height = '100%'
        ..backgroundColor = kEcho3dDebug ? '#1A1F29' : 'transparent';
      if (kEcho3dDebug) {
        modelViewer.style.border = '3px solid #FF00FF';
        modelViewer.addEventListener('load', (html.Event e) {
          debugPrint('[echo3d] <model-viewer> "load" — model is ready');
        });
        modelViewer.addEventListener('error', (html.Event e) {
          debugPrint('[echo3d] <model-viewer> "error" — failed to load model');
        });
      }
      return modelViewer;
    });
  }

  return HtmlElementView(viewType: viewType);
}

/// Compose every asset in [scene] into one GLB (placed by parallax depth), or
/// fall back to the first asset's source if there is only one asset or the
/// GLBs can't be merged losslessly.
String _composedOrFirstSrc(AssetScene scene) {
  final assets = scene.assets;
  if (assets.length <= 1) {
    return assets.first.renderSource;
  }
  final parts = <GlbScenePart>[];
  for (final asset in assets) {
    final bytes = _bytesFromDataUrl(asset.renderSource);
    if (bytes == null) {
      return assets.first.renderSource; // non-data-URL source; can't compose
    }
    parts.add(GlbScenePart(glb: bytes, z: -(asset.parallaxDepth / 100.0)));
  }
  final composed = composeSceneGlb(parts);
  if (composed == null) {
    return assets.first.renderSource;
  }
  return 'data:model/gltf-binary;base64,${base64Encode(composed)}';
}

Uint8List? _bytesFromDataUrl(String src) {
  const marker = ';base64,';
  final index = src.indexOf(marker);
  if (!src.startsWith('data:') || index < 0) {
    return null;
  }
  try {
    return base64Decode(src.substring(index + marker.length));
  } catch (_) {
    return null;
  }
}
