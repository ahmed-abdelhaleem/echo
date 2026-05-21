// Content repository for the Echo client.
//
// Reads a Season with a network-first / cache-fallback policy:
//   1. Fetch from /content/seasons/{id} via [ApiClient].
//   2. On success, upsert the JSON envelope into Drift and return the
//      parsed Season.
//   3. On any transport error (offline, 5xx, parse failure) consult the
//      Drift cache. If a row exists, return it; otherwise rethrow.
//
// 404s are not transport errors — a 404 means the player asked for a
// Season the server doesn't know about. We do NOT fall back to the cache
// for 404 because a server-side delete must be authoritative.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:echo_client/data/local/database.dart';
import 'package:echo_client/data/models/content.dart';
import 'package:echo_client/services/api_client.dart';

class ContentRepository {
  ContentRepository({
    required ApiClient api,
    required EchoDatabase db,
    DateTime Function() now = _defaultNow,
  })  : _api = api,
        _db = db,
        _now = now;

  final ApiClient _api;
  final EchoDatabase _db;
  final DateTime Function() _now;

  static DateTime _defaultNow() => DateTime.now();

  /// Returns the Season for [id], or null if the server says it doesn't
  /// exist. Throws only when there's no network result AND no cached
  /// copy.
  Future<Season?> getSeason(String id) async {
    try {
      final season = await _api.getSeason(id);
      if (season == null) {
        // Authoritative 404 — do not cache.
        return null;
      }
      await _db.upsertCachedSeason(
        CachedSeasonsCompanion.insert(
          id: season.id,
          version: season.version,
          body: jsonEncode(_seasonToJson(season)),
          fetchedAt: _now(),
        ),
      );
      return season;
    } on DioException catch (_) {
      // Network or 5xx failure — try the cache.
      final cached = await _db.findCachedSeason(id);
      if (cached == null) {
        rethrow;
      }
      final body = jsonDecode(cached.body) as Map<String, dynamic>;
      return Season.fromJson(body);
    }
  }

  // _seasonToJson re-encodes the typed Season so a cache hit returns a
  // byte-identical shape. We avoid wrapping the dio response body
  // directly because it may include non-canonical key ordering or extra
  // server-side metadata fields that would silently drift.
  Map<String, dynamic> _seasonToJson(Season s) {
    return <String, dynamic>{
      'id': s.id,
      'title': s.title,
      'locale': s.locale,
      'version': s.version,
      'description': s.description,
      'acts': <Map<String, dynamic>>[
        for (final a in s.acts)
          <String, dynamic>{
            'id': a.id,
            'name': a.name,
            'vignettes': <Map<String, dynamic>>[
              for (final v in a.vignettes) _vignetteToJson(v),
            ],
          },
      ],
    };
  }

  Map<String, dynamic> _vignetteToJson(Vignette v) {
    return <String, dynamic>{
      'id': v.id,
      'setting_beat': v.settingBeat,
      if (v.ambientAudio != null) 'ambient_audio': v.ambientAudio,
      if (v.ambientArt != null) 'ambient_art': v.ambientArt,
      'choices': <Map<String, dynamic>>[
        for (final c in v.choices)
          <String, dynamic>{
            'id': c.id,
            'label': c.label,
            'weights': <Map<String, dynamic>>[
              for (final w in c.weights)
                <String, dynamic>{
                  'dimension': w.dimension,
                  'delta': w.delta,
                  if (w.rationale.isNotEmpty) 'rationale': w.rationale,
                },
            ],
          },
      ],
      if (v.resolutionBeats.isNotEmpty) 'resolution_beats': v.resolutionBeats,
    };
  }
}
