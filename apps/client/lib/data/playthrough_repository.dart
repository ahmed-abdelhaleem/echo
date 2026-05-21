// Local-playthrough repository.
//
// "Playthrough" here is the client-side row that holds a stable local id
// for the session. The server-assigned id arrives later, once the sync
// has called POST /playthroughs; until then we use the local id to key
// pending choice events.

import 'package:drift/drift.dart' show Value;
import 'package:echo_client/data/local/database.dart';
import 'package:uuid/uuid.dart';

class PlaythroughRepository {
  PlaythroughRepository({
    required EchoDatabase db,
    Uuid uuid = const Uuid(),
    DateTime Function() now = _defaultNow,
  })  : _db = db,
        _uuid = uuid,
        _now = now;

  final EchoDatabase _db;
  final Uuid _uuid;
  final DateTime Function() _now;

  static DateTime _defaultNow() => DateTime.now();

  /// Opens a new local playthrough for [seasonId]. Returns the
  /// client-generated id.
  Future<String> startLocalPlaythrough({required String seasonId}) async {
    final localId = _uuid.v4();
    await _db.insertLocalPlaythrough(
      LocalPlaythroughsCompanion.insert(
        localId: localId,
        seasonId: seasonId,
        remoteId: const Value<String?>(null),
        startedAt: _now(),
      ),
    );
    return localId;
  }

  Future<LocalPlaythroughRow?> findById(String localId) {
    return _db.findLocalPlaythrough(localId);
  }
}
