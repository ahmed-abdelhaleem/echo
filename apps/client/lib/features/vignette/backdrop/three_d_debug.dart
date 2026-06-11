// Dev-only diagnostics flag for the atmospheric 3D backdrop viewport.
//
// Enable it at launch:
//   flutter run -d chrome --dart-define=ECHO_3D_DEBUG=true
//
// When true the renderer becomes loud and visible so you can tell, in the
// browser console and on screen, whether the asset *scene* loaded and whether
// the platform `<model-viewer>` actually paints:
//   * AdaptiveAtmosphericBackdrop logs the scene's async state + asset count.
//   * The 3D viewport gets a magenta border and an opaque dark background so a
//     mounted-but-untextured model is unmistakable.
//   * VignetteScreen drops the legibility scrim so the viewport is not washed
//     toward white.
//
// It is a compile-time const, so with the default (false) every guarded branch
// is tree-shaken away and production rendering / golden tests are unchanged.
const bool kEcho3dDebug = bool.fromEnvironment('ECHO_3D_DEBUG');
