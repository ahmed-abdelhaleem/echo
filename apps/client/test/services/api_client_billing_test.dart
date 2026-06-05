// Tests for billing-related ApiClient methods (T-MONEY-001).

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:echo_client/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

// ─── stub adapter ─────────────────────────────────────────────────────────────

class _JsonStubAdapter implements HttpClientAdapter {
  _JsonStubAdapter(this.status, this.body);

  final int status;
  final Map<String, dynamic> body;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: <String, List<String>>{
        HttpHeaders.contentTypeHeader: ['application/json'],
      },
    );
  }
}

ApiClient _client(int status, Map<String, dynamic> body) {
  final dio = Dio()..httpClientAdapter = _JsonStubAdapter(status, body);
  return ApiClient(baseUrl: 'http://test.local', dio: dio);
}

// ─── tests ────────────────────────────────────────────────────────────────────

void main() {
  group('getSubscription', () {
    test('returns free tier on 200 with is_premium=false', () async {
      final client = _client(200, {
        'tier': 'free',
        'status': 'active',
        'store': 'none',
        'is_premium': false,
      });
      final sub = await client.getSubscription();
      expect(sub.tier, 'free');
      expect(sub.isPremium, isFalse);
    });

    test('returns echo_plus on 200 with is_premium=true', () async {
      final client = _client(200, {
        'tier': 'echo_plus',
        'status': 'active',
        'store': 'stripe',
        'is_premium': true,
        'current_period_end': '2027-06-04T00:00:00Z',
      });
      final sub = await client.getSubscription();
      expect(sub.tier, 'echo_plus');
      expect(sub.isPremium, isTrue);
      expect(sub.currentPeriodEnd, '2027-06-04T00:00:00Z');
    });

    test('throws SubscriptionUnauthorised on 401', () async {
      final client = _client(401, {'error': 'unauthorized'});
      expect(
          client.getSubscription(), throwsA(isA<SubscriptionUnauthorised>()));
    });
  });

  group('createStripeCheckout', () {
    test('returns session on 201', () async {
      final client = _client(201, {
        'session_id': 'cs_test_123',
        'url': 'https://checkout.stripe.com/pay/cs_test_123',
      });
      final session = await client.createStripeCheckout();
      expect(session.sessionId, 'cs_test_123');
      expect(session.url, contains('cs_test_123'));
    });

    test('throws SubscriptionUnauthorised on 401', () async {
      final client = _client(401, {'error': 'unauthorized'});
      expect(
        client.createStripeCheckout(),
        throwsA(isA<SubscriptionUnauthorised>()),
      );
    });
  });

  group('createStripePortal', () {
    test('returns portal url on 201', () async {
      final client = _client(201, {
        'url': 'https://billing.stripe.com/session/test_portal',
      });
      final session = await client.createStripePortal();
      expect(session.url, contains('billing.stripe.com'));
    });
  });

  group('SubscriptionStatus', () {
    test('fromJson parses all fields', () {
      const json = {
        'tier': 'echo_plus',
        'status': 'trialing',
        'store': 'apple',
        'is_premium': true,
        'current_period_end': '2026-07-01T00:00:00Z',
      };
      final sub = SubscriptionStatus.fromJson(json);
      expect(sub.tier, 'echo_plus');
      expect(sub.status, 'trialing');
      expect(sub.store, 'apple');
      expect(sub.isPremium, isTrue);
      expect(sub.currentPeriodEnd, '2026-07-01T00:00:00Z');
    });

    test('fromJson works without optional current_period_end', () {
      const json = {
        'tier': 'free',
        'status': 'active',
        'store': 'none',
        'is_premium': false,
      };
      final sub = SubscriptionStatus.fromJson(json);
      expect(sub.currentPeriodEnd, isNull);
    });
  });
}
