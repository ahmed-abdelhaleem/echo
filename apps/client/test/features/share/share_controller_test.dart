// ShareController unit tests — exercise the happy path, every named
// error class (auth, youth-safe, not-found, not-complete, transient),
// the system-share-sheet handoff failing, and the revoke flow. The
// controller is injected with a stub ApiClient (Dio adapter override)
// and a recording SystemSharer fake so no platform channels are touched.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_client/features/share/share_controller.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter({required this.createStatus, this.bytesStatus = 200});

  final int createStatus;
  final int bytesStatus;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.uri.path;
    if (path.endsWith('/share') && options.method == 'POST') {
      if (createStatus == 201) {
        const Map<String, dynamic> body = <String, dynamic>{
          'token': 'tok-abc',
          'playthrough_id': '11111111-1111-1111-1111-111111111111',
          'share_url': 'https://share.echo.test/share/tok-abc',
          'portrait_png_url': 'https://api.echo.test/share/tok-abc/portrait',
          'portrait_webp_url':
              'https://api.echo.test/share/tok-abc/portrait?format=webp',
          'created_at': '2026-05-21T12:00:00Z',
        };
        return ResponseBody.fromString(
          jsonEncode(body),
          createStatus,
          headers: <String, List<String>>{
            HttpHeaders.contentTypeHeader: <String>['application/json'],
          },
        );
      }
      return ResponseBody.fromString('', createStatus);
    }
    if (path.contains('/portrait')) {
      if (bytesStatus != 200) {
        return ResponseBody.fromString('', bytesStatus);
      }
      // Smallest possible PNG header — enough to prove bytes flowed.
      final fakePng = Uint8List.fromList(<int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk header
      ]);
      return ResponseBody.fromBytes(
        fakePng,
        200,
        headers: <String, List<String>>{
          HttpHeaders.contentTypeHeader: <String>['image/png'],
        },
      );
    }
    if (path.startsWith('/share/') && options.method == 'DELETE') {
      return ResponseBody.fromString('', 204);
    }
    return ResponseBody.fromString('', 500);
  }
}

class _RecordingSharer {
  Uint8List? bytes;
  String? shareUrl;
  String? subject;
  bool shouldThrow = false;

  Future<void> call({
    required Uint8List portraitBytes,
    required String shareUrl,
    String? subject,
  }) async {
    if (shouldThrow) {
      throw Exception('share sheet not available');
    }
    bytes = portraitBytes;
    this.shareUrl = shareUrl;
    this.subject = subject;
  }
}

// ignore: library_private_types_in_public_api
ApiClient buildClient(_StubAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return ApiClient(baseUrl: 'http://example.test', dio: dio);
}

void main() {
  group('ShareController.shareNow', () {
    test('happy path: mints link, downloads bytes, invokes sharer', () async {
      final adapter = _StubAdapter(createStatus: 201);
      final sharer = _RecordingSharer();
      final controller = ShareController(
        api: buildClient(adapter),
        sharer: sharer.call,
      );

      final ok = await controller.shareNow(playthroughId: 'p-1');

      expect(ok, isTrue);
      expect(controller.state, isA<ShareReady>());
      final ready = controller.state as ShareReady;
      expect(ready.shareUrl, 'https://share.echo.test/share/tok-abc');
      expect(ready.token, 'tok-abc');
      expect(ready.portraitBytes, isNotEmpty);
      // System sharer received the bytes + the URL.
      expect(sharer.bytes, equals(ready.portraitBytes));
      expect(sharer.shareUrl, ready.shareUrl);
      expect(sharer.subject, 'My Echo Portrait');
    });

    test('401 → ShareError(unauthorised), sharer never invoked', () async {
      final adapter = _StubAdapter(createStatus: 401);
      final sharer = _RecordingSharer();
      final controller = ShareController(
        api: buildClient(adapter),
        sharer: sharer.call,
      );

      final ok = await controller.shareNow(playthroughId: 'p-1');
      expect(ok, isFalse);
      expect(controller.state, isA<ShareError>());
      expect(
        (controller.state as ShareError).kind,
        ShareErrorKind.unauthorised,
      );
      expect(sharer.bytes, isNull);
    });

    test('403 → ShareError(youthSafe)', () async {
      final controller = ShareController(
        api: buildClient(_StubAdapter(createStatus: 403)),
        sharer: _RecordingSharer().call,
      );
      final ok = await controller.shareNow(playthroughId: 'p-1');
      expect(ok, isFalse);
      expect(
        (controller.state as ShareError).kind,
        ShareErrorKind.youthSafe,
      );
    });

    test('404 → ShareError(notFound)', () async {
      final controller = ShareController(
        api: buildClient(_StubAdapter(createStatus: 404)),
        sharer: _RecordingSharer().call,
      );
      final ok = await controller.shareNow(playthroughId: 'p-1');
      expect(ok, isFalse);
      expect(
        (controller.state as ShareError).kind,
        ShareErrorKind.notFound,
      );
    });

    test('409 → ShareError(notComplete)', () async {
      final controller = ShareController(
        api: buildClient(_StubAdapter(createStatus: 409)),
        sharer: _RecordingSharer().call,
      );
      final ok = await controller.shareNow(playthroughId: 'p-1');
      expect(ok, isFalse);
      expect(
        (controller.state as ShareError).kind,
        ShareErrorKind.notComplete,
      );
    });

    test('portrait fetch failure → ShareError(transient)', () async {
      final controller = ShareController(
        api: buildClient(
          _StubAdapter(createStatus: 201, bytesStatus: 500),
        ),
        sharer: _RecordingSharer().call,
      );
      final ok = await controller.shareNow(playthroughId: 'p-1');
      expect(ok, isFalse);
      expect(
        (controller.state as ShareError).kind,
        ShareErrorKind.transient,
      );
    });

    test('system sharer throwing → ShareError(transient)', () async {
      final adapter = _StubAdapter(createStatus: 201);
      final sharer = _RecordingSharer()..shouldThrow = true;
      final controller = ShareController(
        api: buildClient(adapter),
        sharer: sharer.call,
      );

      final ok = await controller.shareNow(playthroughId: 'p-1');
      expect(ok, isFalse);
      expect(
        (controller.state as ShareError).kind,
        ShareErrorKind.transient,
      );
    });
  });

  group('ShareController.revoke', () {
    test('204 → returns true', () async {
      final adapter = _StubAdapter(createStatus: 201);
      final controller = ShareController(
        api: buildClient(adapter),
        sharer: _RecordingSharer().call,
      );
      expect(await controller.revoke(token: 'tok-abc'), isTrue);
    });
  });

  test('reset() flips state back to idle', () {
    final controller = ShareController(
      api: buildClient(_StubAdapter(createStatus: 201)),
      sharer: _RecordingSharer().call,
    );
    controller.reset();
    expect(controller.state, isA<ShareIdle>());
  });
}
