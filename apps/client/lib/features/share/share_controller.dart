// ShareController — orchestrates the public-Portrait share flow
// (T-CLIENT-030).
//
// The controller owns three phases and emits a sealed-class state per
// phase so the widget can render the right thing without sprinkling
// nullability checks everywhere:
//
//   1. Idle — nothing happening; user hasn't tapped Share yet.
//   2. Preparing — POSTing /playthroughs/{id}/share + downloading the
//      high-res Portrait so the system share sheet can attach an image.
//   3. Ready / Error — terminal states. Ready carries the URL + image
//      bytes; Error carries a renderable message and a discriminating
//      [ShareErrorKind].
//
// The actual native share-sheet handoff (share_plus) is injected as a
// [SystemSharer] callback so unit tests can verify the controller
// without booting the Flutter plugin platform channel.

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

sealed class ShareState {
  const ShareState();
}

class ShareIdle extends ShareState {
  const ShareIdle();
}

class SharePreparing extends ShareState {
  const SharePreparing();
}

class ShareReady extends ShareState {
  const ShareReady({
    required this.shareUrl,
    required this.token,
    required this.portraitBytes,
  });

  final String shareUrl;
  final String token;
  final Uint8List portraitBytes;
}

class ShareError extends ShareState {
  const ShareError(this.kind, this.message);
  final ShareErrorKind kind;
  final String message;
}

/// Mutually-exclusive failure modes. The widget switches on these
/// to decide whether to surface a recoverable toast (transient),
/// log the user out (auth), or hide the surface (youth-safe).
enum ShareErrorKind {
  unauthorised,
  youthSafe,
  notFound,
  notComplete,
  transient,
}

/// SystemSharer is the seam between the controller and `share_plus`.
/// The default production implementation calls `Share.shareXFiles`;
/// tests substitute a recording fake.
typedef SystemSharer = Future<void> Function({
  required Uint8List portraitBytes,
  required String shareUrl,
  String? subject,
});

class ShareController extends StateNotifier<ShareState> {
  ShareController({
    required ApiClient api,
    required SystemSharer sharer,
  })  : _api = api,
        _sharer = sharer,
        super(const ShareIdle());

  final ApiClient _api;
  final SystemSharer _sharer;

  /// Mints a fresh share link for [playthroughId], downloads the
  /// high-resolution PNG, then hands both to the system share sheet.
  ///
  /// Returns true if the share sheet was successfully invoked; false
  /// otherwise (state holds a [ShareError]).
  Future<bool> shareNow({required String playthroughId}) async {
    state = const SharePreparing();
    final SharePayload payload;
    try {
      payload = await _api.createShare(playthroughId: playthroughId);
    } on ShareUnauthorised {
      state = const ShareError(
        ShareErrorKind.unauthorised,
        'Sign in again to share your Portrait.',
      );
      return false;
    } on ShareForbidden {
      state = const ShareError(
        ShareErrorKind.youthSafe,
        'Sharing is disabled for your account.',
      );
      return false;
    } on ShareNotFound {
      state = const ShareError(
        ShareErrorKind.notFound,
        'This playthrough is not available to share.',
      );
      return false;
    } on SharePlaythroughIncomplete {
      state = const ShareError(
        ShareErrorKind.notComplete,
        'Finish the season first, then come back to share.',
      );
      return false;
    } on DioException catch (e) {
      state = ShareError(
        ShareErrorKind.transient,
        'Could not reach the server (${e.message ?? 'no message'}).',
      );
      return false;
    } catch (e) {
      state = ShareError(
        ShareErrorKind.transient,
        'Unexpected error: $e',
      );
      return false;
    }

    Uint8List bytes;
    try {
      final raw = await _api.fetchBytes(payload.portraitPngUrl);
      bytes = Uint8List.fromList(raw);
    } catch (e) {
      state = ShareError(
        ShareErrorKind.transient,
        'Could not download Portrait: $e',
      );
      return false;
    }

    try {
      await _sharer(
        portraitBytes: bytes,
        shareUrl: payload.shareUrl,
        subject: 'My Echo Portrait',
      );
    } catch (e) {
      state = ShareError(
        ShareErrorKind.transient,
        'System share sheet failed: $e',
      );
      return false;
    }

    state = ShareReady(
      shareUrl: payload.shareUrl,
      token: payload.token,
      portraitBytes: bytes,
    );
    return true;
  }

  /// Resets the controller back to idle.
  void reset() {
    state = const ShareIdle();
  }

  /// Revokes [token] server-side. Returns true on success. Idempotent.
  Future<bool> revoke({required String token}) async {
    try {
      await _api.revokeShare(token: token);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Production implementation of [SystemSharer]. Handed `XFile.fromData`
/// + a text URL; share_plus does the rest. Kept top-level so it can be
/// referenced from tests that want to exercise the real adapter under
/// integration (M3+ scope).
Future<void> defaultSystemSharer({
  required Uint8List portraitBytes,
  required String shareUrl,
  String? subject,
}) async {
  final file = XFile.fromData(
    portraitBytes,
    name: 'portrait.png',
    mimeType: 'image/png',
  );
  await Share.shareXFiles(<XFile>[file], text: shareUrl, subject: subject);
}

/// Default Riverpod wiring — production uses [defaultSystemSharer].
/// Tests override this provider with their own [ShareController]
/// constructed against a recording sharer.
final shareControllerProvider =
    StateNotifierProvider<ShareController, ShareState>((ref) {
  final api = ref.watch(apiClientProvider);
  return ShareController(api: api, sharer: defaultSystemSharer);
});
