// Secure persistence layer for the Kratos session token.
//
// The platform plugin is asynchronous, so initialization preloads the token
// before runApp. AuthController can then restore its first frame synchronously.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _kSessionTokenKey = 'echo.session_token';

abstract interface class SessionTokenStorage {
  /// Returns the stored session token, or null if none is saved.
  String? read();

  /// Persists [token] for the next cold start.
  Future<void> write(String token);

  /// Erases the stored token (called on sign-out / account deletion).
  Future<void> clear();
}

abstract interface class SecureValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureValueStore implements SecureValueStore {
  FlutterSecureValueStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class SecureSessionTokenStorage implements SessionTokenStorage {
  SecureSessionTokenStorage._(this._store, this._token);

  final SecureValueStore _store;
  String? _token;

  static Future<SecureSessionTokenStorage> create({
    SecureValueStore? store,
  }) async {
    final resolvedStore = store ?? FlutterSecureValueStore();
    final token = await resolvedStore.read(_kSessionTokenKey);
    return SecureSessionTokenStorage._(resolvedStore, token);
  }

  @override
  String? read() => _token;

  @override
  Future<void> write(String token) async {
    await _store.write(_kSessionTokenKey, token);
    _token = token;
  }

  @override
  Future<void> clear() async {
    await _store.delete(_kSessionTokenKey);
    _token = null;
  }
}

/// Production overrides this before `runApp`. The null default keeps isolated
/// widget tests deterministic without touching platform storage.
final Provider<SessionTokenStorage?> sessionTokenStorageProvider =
    Provider<SessionTokenStorage?>((Ref ref) => null);

/// Convenience factory. Call once in `main()` before `runApp` and pass
/// the result as a [ProviderScope] override.
///
/// ```dart
/// final storage = await SessionTokenStorage.init();
/// runApp(ProviderScope(overrides: [storage.providerOverride], child: ...));
/// ```
class SessionTokenStorageInit {
  const SessionTokenStorageInit(this.storage);

  final SessionTokenStorage storage;

  Override get providerOverride =>
      sessionTokenStorageProvider.overrideWithValue(storage);

  static Future<SessionTokenStorageInit> init({
    SecureValueStore? store,
  }) async {
    return SessionTokenStorageInit(
      await SecureSessionTokenStorage.create(store: store),
    );
  }
}
