// ShareButton widget tests.
//
// We override `shareControllerProvider` with controllers backed by a
// recording sharer + stub Dio adapter so the widget exercises the
// real ShareController state machine end-to-end without touching the
// share_plus platform channel.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:echo_client/features/share/share_button.dart';
import 'package:echo_client/features/share/share_controller.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoopAdapter implements HttpClientAdapter {
  _NoopAdapter(this.status);
  final int status;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path.contains('/portrait')) {
      return ResponseBody.fromBytes(
        <int>[0x89, 0x50, 0x4E, 0x47],
        200,
        headers: <String, List<String>>{
          HttpHeaders.contentTypeHeader: <String>['image/png'],
        },
      );
    }
    if (options.method == 'POST') {
      return ResponseBody.fromString(
        '{"token":"tok-abc","playthrough_id":"p","share_url":"https://share.echo.test/share/tok-abc","portrait_png_url":"https://api.echo.test/share/tok-abc/portrait","portrait_webp_url":"https://api.echo.test/share/tok-abc/portrait?format=webp","created_at":"2026-05-21T12:00:00Z"}',
        status,
        headers: <String, List<String>>{
          HttpHeaders.contentTypeHeader: <String>['application/json'],
        },
      );
    }
    return ResponseBody.fromString('', 204);
  }
}

ShareController buildController({required int status}) {
  final dio = Dio()..httpClientAdapter = _NoopAdapter(status);
  final api = ApiClient(baseUrl: 'http://example.test', dio: dio);
  return ShareController(
    api: api,
    sharer: ({required portraitBytes, required shareUrl, subject}) async {},
  );
}

Future<void> pumpButton(
  WidgetTester tester, {
  required ShareController controller,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        shareControllerProvider.overrideWith((ref) => controller),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: ShareButton(playthroughId: 'p-1'),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders default label when idle', (tester) async {
    await pumpButton(tester, controller: buildController(status: 201));
    expect(find.text('Share my Portrait'), findsOneWidget);
    expect(find.byIcon(Icons.ios_share), findsOneWidget);
  });

  testWidgets('tapping starts the share flow and shows success',
      (tester) async {
    final controller = buildController(status: 201);
    await pumpButton(tester, controller: controller);

    await tester.tap(find.byKey(const Key('share-button')));
    await tester.pump(); // schedule shareNow
    // While preparing, label flips and the button is disabled.
    expect(find.text('Preparing…'), findsOneWidget);
    await tester.pumpAndSettle();
    // Once done, the success surface should be visible.
    expect(find.byKey(const Key('share-success')), findsOneWidget);
    expect(
      find.textContaining('https://share.echo.test/share/tok-abc'),
      findsOneWidget,
    );
  });

  testWidgets('renders the error message when 403 (youth-safe) returned',
      (tester) async {
    final controller = buildController(status: 403);
    await pumpButton(tester, controller: controller);

    await tester.tap(find.byKey(const Key('share-button')));
    await tester.pumpAndSettle();
    final errorFinder = find.byKey(const Key('share-error'));
    expect(errorFinder, findsOneWidget);
    expect(
      find.textContaining('disabled for your account'),
      findsOneWidget,
    );
  });
}
