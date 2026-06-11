import 'package:echo_client/services/session_token_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemorySecureValueStore implements SecureValueStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  test('secure storage preloads, writes, and clears the token', () async {
    final store = _MemorySecureValueStore();
    final storage = await SecureSessionTokenStorage.create(store: store);

    expect(storage.read(), isNull);

    await storage.write('tok-saved');
    expect(storage.read(), 'tok-saved');

    final restored = await SecureSessionTokenStorage.create(store: store);
    expect(restored.read(), 'tok-saved');

    await storage.clear();
    expect(storage.read(), isNull);
    expect(
      (await SecureSessionTokenStorage.create(store: store)).read(),
      isNull,
    );
  });
}
