import 'package:echo_client/features/vignette/backdrop/performance_manager.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PerformanceManager resolveTier', () {
    test('web mobile degrades to low tier', () {
      expect(
        PerformanceManager.resolveTier(
          isWeb: true,
          platform: TargetPlatform.iOS,
        ),
        PerformanceTier.low,
      );
      expect(
        PerformanceManager.resolveTier(
          isWeb: true,
          platform: TargetPlatform.android,
        ),
        PerformanceTier.low,
      );
    });

    test('web desktop maps to mid tier', () {
      expect(
        PerformanceManager.resolveTier(
          isWeb: true,
          platform: TargetPlatform.macOS,
        ),
        PerformanceTier.mid,
      );
      expect(
        PerformanceManager.resolveTier(
          isWeb: true,
          platform: TargetPlatform.windows,
        ),
        PerformanceTier.mid,
      );
    });

    test('native with low cores maps to low tier', () {
      expect(
        PerformanceManager.resolveTier(
          isWeb: false,
          platform: TargetPlatform.iOS,
          cores: 2,
        ),
        PerformanceTier.low,
      );
    });

    test('native with medium cores maps to mid tier', () {
      expect(
        PerformanceManager.resolveTier(
          isWeb: false,
          platform: TargetPlatform.android,
          cores: 6,
        ),
        PerformanceTier.mid,
      );
    });

    test('native with high cores maps to high tier', () {
      expect(
        PerformanceManager.resolveTier(
          isWeb: false,
          platform: TargetPlatform.macOS,
          cores: 8,
        ),
        PerformanceTier.high,
      );
    });

    test('native fallback without core info maps to high tier', () {
      expect(
        PerformanceManager.resolveTier(
          isWeb: false,
          platform: TargetPlatform.windows,
          cores: null,
        ),
        PerformanceTier.high,
      );
    });
  });

  group('PerformanceManager properties', () {
    test('static tier property resolves to a valid tier', () {
      expect(PerformanceManager.tier, isNotNull);
    });

    test('is3DSupported maps correctly', () {
      final tier = PerformanceManager.tier;
      expect(PerformanceManager.is3DSupported, tier != PerformanceTier.low);
    });

    test('particleMultiplier maps correctly', () {
      final tier = PerformanceManager.tier;
      double expectedMultiplier;
      switch (tier) {
        case PerformanceTier.low:
          expectedMultiplier = 0.0;
          break;
        case PerformanceTier.mid:
          expectedMultiplier = 0.5;
          break;
        case PerformanceTier.high:
          expectedMultiplier = 1.0;
          break;
      }
      expect(PerformanceManager.particleMultiplier, expectedMultiplier);
    });
  });
}
