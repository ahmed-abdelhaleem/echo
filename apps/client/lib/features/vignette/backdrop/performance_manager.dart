import 'dart:io' show Platform;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

enum PerformanceTier { low, mid, high }

class PerformanceManager {
  PerformanceManager._();

  static PerformanceTier _getTier() {
    int? nativeCores;
    if (!kIsWeb) {
      try {
        nativeCores = Platform.numberOfProcessors;
      } catch (_) {}
    }
    return resolveTier(
      isWeb: kIsWeb,
      platform: defaultTargetPlatform,
      cores: nativeCores,
    );
  }

  /// Resolve the performance tier based on platform parameters. Exposed for
  /// unit testing.
  static PerformanceTier resolveTier({
    required bool isWeb,
    required TargetPlatform platform,
    int? cores,
  }) {
    if (isWeb) {
      // Mobile web browsers are low-tier due to WASM/WebGL overhead.
      final isMobileWeb = platform == TargetPlatform.android ||
          platform == TargetPlatform.iOS;
      if (isMobileWeb) {
        return PerformanceTier.low;
      }
      return PerformanceTier.mid;
    }

    if (cores != null) {
      if (cores < 4) {
        return PerformanceTier.low;
      } else if (cores < 8) {
        return PerformanceTier.mid;
      }
    }

    return PerformanceTier.high;
  }

  static final PerformanceTier tier = _getTier();

  static bool get is3DSupported => tier != PerformanceTier.low;

  static double get particleMultiplier {
    switch (tier) {
      case PerformanceTier.low:
        return 0.0;
      case PerformanceTier.mid:
        return 0.5;
      case PerformanceTier.high:
        return 1.0;
    }
  }
}
