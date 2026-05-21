// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $CachedSeasonsTable extends CachedSeasons
    with TableInfo<$CachedSeasonsTable, CachedSeasonRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedSeasonsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _versionMeta =
      const VerificationMeta('version');
  @override
  late final GeneratedColumn<int> version = GeneratedColumn<int>(
      'version', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
      'body', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _fetchedAtMeta =
      const VerificationMeta('fetchedAt');
  @override
  late final GeneratedColumn<DateTime> fetchedAt = GeneratedColumn<DateTime>(
      'fetched_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, version, body, fetchedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_seasons';
  @override
  VerificationContext validateIntegrity(Insertable<CachedSeasonRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('version')) {
      context.handle(_versionMeta,
          version.isAcceptableOrUnknown(data['version']!, _versionMeta));
    } else if (isInserting) {
      context.missing(_versionMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
          _bodyMeta, body.isAcceptableOrUnknown(data['body']!, _bodyMeta));
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('fetched_at')) {
      context.handle(_fetchedAtMeta,
          fetchedAt.isAcceptableOrUnknown(data['fetched_at']!, _fetchedAtMeta));
    } else if (isInserting) {
      context.missing(_fetchedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  CachedSeasonRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedSeasonRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      version: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}version'])!,
      body: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}body'])!,
      fetchedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}fetched_at'])!,
    );
  }

  @override
  $CachedSeasonsTable createAlias(String alias) {
    return $CachedSeasonsTable(attachedDatabase, alias);
  }
}

class CachedSeasonRow extends DataClass implements Insertable<CachedSeasonRow> {
  final String id;
  final int version;
  final String body;
  final DateTime fetchedAt;
  const CachedSeasonRow(
      {required this.id,
      required this.version,
      required this.body,
      required this.fetchedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['version'] = Variable<int>(version);
    map['body'] = Variable<String>(body);
    map['fetched_at'] = Variable<DateTime>(fetchedAt);
    return map;
  }

  CachedSeasonsCompanion toCompanion(bool nullToAbsent) {
    return CachedSeasonsCompanion(
      id: Value(id),
      version: Value(version),
      body: Value(body),
      fetchedAt: Value(fetchedAt),
    );
  }

  factory CachedSeasonRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedSeasonRow(
      id: serializer.fromJson<String>(json['id']),
      version: serializer.fromJson<int>(json['version']),
      body: serializer.fromJson<String>(json['body']),
      fetchedAt: serializer.fromJson<DateTime>(json['fetchedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'version': serializer.toJson<int>(version),
      'body': serializer.toJson<String>(body),
      'fetchedAt': serializer.toJson<DateTime>(fetchedAt),
    };
  }

  CachedSeasonRow copyWith(
          {String? id, int? version, String? body, DateTime? fetchedAt}) =>
      CachedSeasonRow(
        id: id ?? this.id,
        version: version ?? this.version,
        body: body ?? this.body,
        fetchedAt: fetchedAt ?? this.fetchedAt,
      );
  CachedSeasonRow copyWithCompanion(CachedSeasonsCompanion data) {
    return CachedSeasonRow(
      id: data.id.present ? data.id.value : this.id,
      version: data.version.present ? data.version.value : this.version,
      body: data.body.present ? data.body.value : this.body,
      fetchedAt: data.fetchedAt.present ? data.fetchedAt.value : this.fetchedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedSeasonRow(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('body: $body, ')
          ..write('fetchedAt: $fetchedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, version, body, fetchedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedSeasonRow &&
          other.id == this.id &&
          other.version == this.version &&
          other.body == this.body &&
          other.fetchedAt == this.fetchedAt);
}

class CachedSeasonsCompanion extends UpdateCompanion<CachedSeasonRow> {
  final Value<String> id;
  final Value<int> version;
  final Value<String> body;
  final Value<DateTime> fetchedAt;
  final Value<int> rowid;
  const CachedSeasonsCompanion({
    this.id = const Value.absent(),
    this.version = const Value.absent(),
    this.body = const Value.absent(),
    this.fetchedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedSeasonsCompanion.insert({
    required String id,
    required int version,
    required String body,
    required DateTime fetchedAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        version = Value(version),
        body = Value(body),
        fetchedAt = Value(fetchedAt);
  static Insertable<CachedSeasonRow> custom({
    Expression<String>? id,
    Expression<int>? version,
    Expression<String>? body,
    Expression<DateTime>? fetchedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (version != null) 'version': version,
      if (body != null) 'body': body,
      if (fetchedAt != null) 'fetched_at': fetchedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedSeasonsCompanion copyWith(
      {Value<String>? id,
      Value<int>? version,
      Value<String>? body,
      Value<DateTime>? fetchedAt,
      Value<int>? rowid}) {
    return CachedSeasonsCompanion(
      id: id ?? this.id,
      version: version ?? this.version,
      body: body ?? this.body,
      fetchedAt: fetchedAt ?? this.fetchedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (version.present) {
      map['version'] = Variable<int>(version.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (fetchedAt.present) {
      map['fetched_at'] = Variable<DateTime>(fetchedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedSeasonsCompanion(')
          ..write('id: $id, ')
          ..write('version: $version, ')
          ..write('body: $body, ')
          ..write('fetchedAt: $fetchedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PendingChoiceEventsTable extends PendingChoiceEvents
    with TableInfo<$PendingChoiceEventsTable, PendingChoiceEventRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PendingChoiceEventsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _localIdMeta =
      const VerificationMeta('localId');
  @override
  late final GeneratedColumn<String> localId = GeneratedColumn<String>(
      'local_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _localPlaythroughIdMeta =
      const VerificationMeta('localPlaythroughId');
  @override
  late final GeneratedColumn<String> localPlaythroughId =
      GeneratedColumn<String>('local_playthrough_id', aliasedName, false,
          type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _seasonIdMeta =
      const VerificationMeta('seasonId');
  @override
  late final GeneratedColumn<String> seasonId = GeneratedColumn<String>(
      'season_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _vignetteIdMeta =
      const VerificationMeta('vignetteId');
  @override
  late final GeneratedColumn<String> vignetteId = GeneratedColumn<String>(
      'vignette_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _choiceIdMeta =
      const VerificationMeta('choiceId');
  @override
  late final GeneratedColumn<String> choiceId = GeneratedColumn<String>(
      'choice_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _committedAtMeta =
      const VerificationMeta('committedAt');
  @override
  late final GeneratedColumn<DateTime> committedAt = GeneratedColumn<DateTime>(
      'committed_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _deliberationMsMeta =
      const VerificationMeta('deliberationMs');
  @override
  late final GeneratedColumn<int> deliberationMs = GeneratedColumn<int>(
      'deliberation_ms', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [
        localId,
        localPlaythroughId,
        seasonId,
        vignetteId,
        choiceId,
        committedAt,
        deliberationMs,
        createdAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'pending_choice_events';
  @override
  VerificationContext validateIntegrity(
      Insertable<PendingChoiceEventRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('local_id')) {
      context.handle(_localIdMeta,
          localId.isAcceptableOrUnknown(data['local_id']!, _localIdMeta));
    } else if (isInserting) {
      context.missing(_localIdMeta);
    }
    if (data.containsKey('local_playthrough_id')) {
      context.handle(
          _localPlaythroughIdMeta,
          localPlaythroughId.isAcceptableOrUnknown(
              data['local_playthrough_id']!, _localPlaythroughIdMeta));
    } else if (isInserting) {
      context.missing(_localPlaythroughIdMeta);
    }
    if (data.containsKey('season_id')) {
      context.handle(_seasonIdMeta,
          seasonId.isAcceptableOrUnknown(data['season_id']!, _seasonIdMeta));
    } else if (isInserting) {
      context.missing(_seasonIdMeta);
    }
    if (data.containsKey('vignette_id')) {
      context.handle(
          _vignetteIdMeta,
          vignetteId.isAcceptableOrUnknown(
              data['vignette_id']!, _vignetteIdMeta));
    } else if (isInserting) {
      context.missing(_vignetteIdMeta);
    }
    if (data.containsKey('choice_id')) {
      context.handle(_choiceIdMeta,
          choiceId.isAcceptableOrUnknown(data['choice_id']!, _choiceIdMeta));
    } else if (isInserting) {
      context.missing(_choiceIdMeta);
    }
    if (data.containsKey('committed_at')) {
      context.handle(
          _committedAtMeta,
          committedAt.isAcceptableOrUnknown(
              data['committed_at']!, _committedAtMeta));
    } else if (isInserting) {
      context.missing(_committedAtMeta);
    }
    if (data.containsKey('deliberation_ms')) {
      context.handle(
          _deliberationMsMeta,
          deliberationMs.isAcceptableOrUnknown(
              data['deliberation_ms']!, _deliberationMsMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {localId};
  @override
  PendingChoiceEventRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PendingChoiceEventRow(
      localId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}local_id'])!,
      localPlaythroughId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}local_playthrough_id'])!,
      seasonId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}season_id'])!,
      vignetteId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}vignette_id'])!,
      choiceId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}choice_id'])!,
      committedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}committed_at'])!,
      deliberationMs: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}deliberation_ms']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $PendingChoiceEventsTable createAlias(String alias) {
    return $PendingChoiceEventsTable(attachedDatabase, alias);
  }
}

class PendingChoiceEventRow extends DataClass
    implements Insertable<PendingChoiceEventRow> {
  final String localId;
  final String localPlaythroughId;
  final String seasonId;
  final String vignetteId;
  final String choiceId;

  /// Time the player committed the choice, on the device. Used by the
  /// sync to send `client_timestamp` to the server.
  final DateTime committedAt;

  /// Milliseconds between vignette presentation and the player's tap.
  /// Null if the renderer wasn't able to measure (eg restored from a
  /// crash).
  final int? deliberationMs;
  final DateTime createdAt;
  const PendingChoiceEventRow(
      {required this.localId,
      required this.localPlaythroughId,
      required this.seasonId,
      required this.vignetteId,
      required this.choiceId,
      required this.committedAt,
      this.deliberationMs,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['local_id'] = Variable<String>(localId);
    map['local_playthrough_id'] = Variable<String>(localPlaythroughId);
    map['season_id'] = Variable<String>(seasonId);
    map['vignette_id'] = Variable<String>(vignetteId);
    map['choice_id'] = Variable<String>(choiceId);
    map['committed_at'] = Variable<DateTime>(committedAt);
    if (!nullToAbsent || deliberationMs != null) {
      map['deliberation_ms'] = Variable<int>(deliberationMs);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  PendingChoiceEventsCompanion toCompanion(bool nullToAbsent) {
    return PendingChoiceEventsCompanion(
      localId: Value(localId),
      localPlaythroughId: Value(localPlaythroughId),
      seasonId: Value(seasonId),
      vignetteId: Value(vignetteId),
      choiceId: Value(choiceId),
      committedAt: Value(committedAt),
      deliberationMs: deliberationMs == null && nullToAbsent
          ? const Value.absent()
          : Value(deliberationMs),
      createdAt: Value(createdAt),
    );
  }

  factory PendingChoiceEventRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PendingChoiceEventRow(
      localId: serializer.fromJson<String>(json['localId']),
      localPlaythroughId:
          serializer.fromJson<String>(json['localPlaythroughId']),
      seasonId: serializer.fromJson<String>(json['seasonId']),
      vignetteId: serializer.fromJson<String>(json['vignetteId']),
      choiceId: serializer.fromJson<String>(json['choiceId']),
      committedAt: serializer.fromJson<DateTime>(json['committedAt']),
      deliberationMs: serializer.fromJson<int?>(json['deliberationMs']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'localId': serializer.toJson<String>(localId),
      'localPlaythroughId': serializer.toJson<String>(localPlaythroughId),
      'seasonId': serializer.toJson<String>(seasonId),
      'vignetteId': serializer.toJson<String>(vignetteId),
      'choiceId': serializer.toJson<String>(choiceId),
      'committedAt': serializer.toJson<DateTime>(committedAt),
      'deliberationMs': serializer.toJson<int?>(deliberationMs),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  PendingChoiceEventRow copyWith(
          {String? localId,
          String? localPlaythroughId,
          String? seasonId,
          String? vignetteId,
          String? choiceId,
          DateTime? committedAt,
          Value<int?> deliberationMs = const Value.absent(),
          DateTime? createdAt}) =>
      PendingChoiceEventRow(
        localId: localId ?? this.localId,
        localPlaythroughId: localPlaythroughId ?? this.localPlaythroughId,
        seasonId: seasonId ?? this.seasonId,
        vignetteId: vignetteId ?? this.vignetteId,
        choiceId: choiceId ?? this.choiceId,
        committedAt: committedAt ?? this.committedAt,
        deliberationMs:
            deliberationMs.present ? deliberationMs.value : this.deliberationMs,
        createdAt: createdAt ?? this.createdAt,
      );
  PendingChoiceEventRow copyWithCompanion(PendingChoiceEventsCompanion data) {
    return PendingChoiceEventRow(
      localId: data.localId.present ? data.localId.value : this.localId,
      localPlaythroughId: data.localPlaythroughId.present
          ? data.localPlaythroughId.value
          : this.localPlaythroughId,
      seasonId: data.seasonId.present ? data.seasonId.value : this.seasonId,
      vignetteId:
          data.vignetteId.present ? data.vignetteId.value : this.vignetteId,
      choiceId: data.choiceId.present ? data.choiceId.value : this.choiceId,
      committedAt:
          data.committedAt.present ? data.committedAt.value : this.committedAt,
      deliberationMs: data.deliberationMs.present
          ? data.deliberationMs.value
          : this.deliberationMs,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PendingChoiceEventRow(')
          ..write('localId: $localId, ')
          ..write('localPlaythroughId: $localPlaythroughId, ')
          ..write('seasonId: $seasonId, ')
          ..write('vignetteId: $vignetteId, ')
          ..write('choiceId: $choiceId, ')
          ..write('committedAt: $committedAt, ')
          ..write('deliberationMs: $deliberationMs, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(localId, localPlaythroughId, seasonId,
      vignetteId, choiceId, committedAt, deliberationMs, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PendingChoiceEventRow &&
          other.localId == this.localId &&
          other.localPlaythroughId == this.localPlaythroughId &&
          other.seasonId == this.seasonId &&
          other.vignetteId == this.vignetteId &&
          other.choiceId == this.choiceId &&
          other.committedAt == this.committedAt &&
          other.deliberationMs == this.deliberationMs &&
          other.createdAt == this.createdAt);
}

class PendingChoiceEventsCompanion
    extends UpdateCompanion<PendingChoiceEventRow> {
  final Value<String> localId;
  final Value<String> localPlaythroughId;
  final Value<String> seasonId;
  final Value<String> vignetteId;
  final Value<String> choiceId;
  final Value<DateTime> committedAt;
  final Value<int?> deliberationMs;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const PendingChoiceEventsCompanion({
    this.localId = const Value.absent(),
    this.localPlaythroughId = const Value.absent(),
    this.seasonId = const Value.absent(),
    this.vignetteId = const Value.absent(),
    this.choiceId = const Value.absent(),
    this.committedAt = const Value.absent(),
    this.deliberationMs = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PendingChoiceEventsCompanion.insert({
    required String localId,
    required String localPlaythroughId,
    required String seasonId,
    required String vignetteId,
    required String choiceId,
    required DateTime committedAt,
    this.deliberationMs = const Value.absent(),
    required DateTime createdAt,
    this.rowid = const Value.absent(),
  })  : localId = Value(localId),
        localPlaythroughId = Value(localPlaythroughId),
        seasonId = Value(seasonId),
        vignetteId = Value(vignetteId),
        choiceId = Value(choiceId),
        committedAt = Value(committedAt),
        createdAt = Value(createdAt);
  static Insertable<PendingChoiceEventRow> custom({
    Expression<String>? localId,
    Expression<String>? localPlaythroughId,
    Expression<String>? seasonId,
    Expression<String>? vignetteId,
    Expression<String>? choiceId,
    Expression<DateTime>? committedAt,
    Expression<int>? deliberationMs,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (localId != null) 'local_id': localId,
      if (localPlaythroughId != null)
        'local_playthrough_id': localPlaythroughId,
      if (seasonId != null) 'season_id': seasonId,
      if (vignetteId != null) 'vignette_id': vignetteId,
      if (choiceId != null) 'choice_id': choiceId,
      if (committedAt != null) 'committed_at': committedAt,
      if (deliberationMs != null) 'deliberation_ms': deliberationMs,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PendingChoiceEventsCompanion copyWith(
      {Value<String>? localId,
      Value<String>? localPlaythroughId,
      Value<String>? seasonId,
      Value<String>? vignetteId,
      Value<String>? choiceId,
      Value<DateTime>? committedAt,
      Value<int?>? deliberationMs,
      Value<DateTime>? createdAt,
      Value<int>? rowid}) {
    return PendingChoiceEventsCompanion(
      localId: localId ?? this.localId,
      localPlaythroughId: localPlaythroughId ?? this.localPlaythroughId,
      seasonId: seasonId ?? this.seasonId,
      vignetteId: vignetteId ?? this.vignetteId,
      choiceId: choiceId ?? this.choiceId,
      committedAt: committedAt ?? this.committedAt,
      deliberationMs: deliberationMs ?? this.deliberationMs,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (localId.present) {
      map['local_id'] = Variable<String>(localId.value);
    }
    if (localPlaythroughId.present) {
      map['local_playthrough_id'] = Variable<String>(localPlaythroughId.value);
    }
    if (seasonId.present) {
      map['season_id'] = Variable<String>(seasonId.value);
    }
    if (vignetteId.present) {
      map['vignette_id'] = Variable<String>(vignetteId.value);
    }
    if (choiceId.present) {
      map['choice_id'] = Variable<String>(choiceId.value);
    }
    if (committedAt.present) {
      map['committed_at'] = Variable<DateTime>(committedAt.value);
    }
    if (deliberationMs.present) {
      map['deliberation_ms'] = Variable<int>(deliberationMs.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PendingChoiceEventsCompanion(')
          ..write('localId: $localId, ')
          ..write('localPlaythroughId: $localPlaythroughId, ')
          ..write('seasonId: $seasonId, ')
          ..write('vignetteId: $vignetteId, ')
          ..write('choiceId: $choiceId, ')
          ..write('committedAt: $committedAt, ')
          ..write('deliberationMs: $deliberationMs, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalPlaythroughsTable extends LocalPlaythroughs
    with TableInfo<$LocalPlaythroughsTable, LocalPlaythroughRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalPlaythroughsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _localIdMeta =
      const VerificationMeta('localId');
  @override
  late final GeneratedColumn<String> localId = GeneratedColumn<String>(
      'local_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _seasonIdMeta =
      const VerificationMeta('seasonId');
  @override
  late final GeneratedColumn<String> seasonId = GeneratedColumn<String>(
      'season_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _remoteIdMeta =
      const VerificationMeta('remoteId');
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
      'remote_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _startedAtMeta =
      const VerificationMeta('startedAt');
  @override
  late final GeneratedColumn<DateTime> startedAt = GeneratedColumn<DateTime>(
      'started_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [localId, seasonId, remoteId, startedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_playthroughs';
  @override
  VerificationContext validateIntegrity(
      Insertable<LocalPlaythroughRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('local_id')) {
      context.handle(_localIdMeta,
          localId.isAcceptableOrUnknown(data['local_id']!, _localIdMeta));
    } else if (isInserting) {
      context.missing(_localIdMeta);
    }
    if (data.containsKey('season_id')) {
      context.handle(_seasonIdMeta,
          seasonId.isAcceptableOrUnknown(data['season_id']!, _seasonIdMeta));
    } else if (isInserting) {
      context.missing(_seasonIdMeta);
    }
    if (data.containsKey('remote_id')) {
      context.handle(_remoteIdMeta,
          remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta));
    }
    if (data.containsKey('started_at')) {
      context.handle(_startedAtMeta,
          startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta));
    } else if (isInserting) {
      context.missing(_startedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {localId};
  @override
  LocalPlaythroughRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalPlaythroughRow(
      localId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}local_id'])!,
      seasonId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}season_id'])!,
      remoteId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}remote_id']),
      startedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}started_at'])!,
    );
  }

  @override
  $LocalPlaythroughsTable createAlias(String alias) {
    return $LocalPlaythroughsTable(attachedDatabase, alias);
  }
}

class LocalPlaythroughRow extends DataClass
    implements Insertable<LocalPlaythroughRow> {
  final String localId;
  final String seasonId;
  final String? remoteId;
  final DateTime startedAt;
  const LocalPlaythroughRow(
      {required this.localId,
      required this.seasonId,
      this.remoteId,
      required this.startedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['local_id'] = Variable<String>(localId);
    map['season_id'] = Variable<String>(seasonId);
    if (!nullToAbsent || remoteId != null) {
      map['remote_id'] = Variable<String>(remoteId);
    }
    map['started_at'] = Variable<DateTime>(startedAt);
    return map;
  }

  LocalPlaythroughsCompanion toCompanion(bool nullToAbsent) {
    return LocalPlaythroughsCompanion(
      localId: Value(localId),
      seasonId: Value(seasonId),
      remoteId: remoteId == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteId),
      startedAt: Value(startedAt),
    );
  }

  factory LocalPlaythroughRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalPlaythroughRow(
      localId: serializer.fromJson<String>(json['localId']),
      seasonId: serializer.fromJson<String>(json['seasonId']),
      remoteId: serializer.fromJson<String?>(json['remoteId']),
      startedAt: serializer.fromJson<DateTime>(json['startedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'localId': serializer.toJson<String>(localId),
      'seasonId': serializer.toJson<String>(seasonId),
      'remoteId': serializer.toJson<String?>(remoteId),
      'startedAt': serializer.toJson<DateTime>(startedAt),
    };
  }

  LocalPlaythroughRow copyWith(
          {String? localId,
          String? seasonId,
          Value<String?> remoteId = const Value.absent(),
          DateTime? startedAt}) =>
      LocalPlaythroughRow(
        localId: localId ?? this.localId,
        seasonId: seasonId ?? this.seasonId,
        remoteId: remoteId.present ? remoteId.value : this.remoteId,
        startedAt: startedAt ?? this.startedAt,
      );
  LocalPlaythroughRow copyWithCompanion(LocalPlaythroughsCompanion data) {
    return LocalPlaythroughRow(
      localId: data.localId.present ? data.localId.value : this.localId,
      seasonId: data.seasonId.present ? data.seasonId.value : this.seasonId,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalPlaythroughRow(')
          ..write('localId: $localId, ')
          ..write('seasonId: $seasonId, ')
          ..write('remoteId: $remoteId, ')
          ..write('startedAt: $startedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(localId, seasonId, remoteId, startedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalPlaythroughRow &&
          other.localId == this.localId &&
          other.seasonId == this.seasonId &&
          other.remoteId == this.remoteId &&
          other.startedAt == this.startedAt);
}

class LocalPlaythroughsCompanion extends UpdateCompanion<LocalPlaythroughRow> {
  final Value<String> localId;
  final Value<String> seasonId;
  final Value<String?> remoteId;
  final Value<DateTime> startedAt;
  final Value<int> rowid;
  const LocalPlaythroughsCompanion({
    this.localId = const Value.absent(),
    this.seasonId = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalPlaythroughsCompanion.insert({
    required String localId,
    required String seasonId,
    this.remoteId = const Value.absent(),
    required DateTime startedAt,
    this.rowid = const Value.absent(),
  })  : localId = Value(localId),
        seasonId = Value(seasonId),
        startedAt = Value(startedAt);
  static Insertable<LocalPlaythroughRow> custom({
    Expression<String>? localId,
    Expression<String>? seasonId,
    Expression<String>? remoteId,
    Expression<DateTime>? startedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (localId != null) 'local_id': localId,
      if (seasonId != null) 'season_id': seasonId,
      if (remoteId != null) 'remote_id': remoteId,
      if (startedAt != null) 'started_at': startedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalPlaythroughsCompanion copyWith(
      {Value<String>? localId,
      Value<String>? seasonId,
      Value<String?>? remoteId,
      Value<DateTime>? startedAt,
      Value<int>? rowid}) {
    return LocalPlaythroughsCompanion(
      localId: localId ?? this.localId,
      seasonId: seasonId ?? this.seasonId,
      remoteId: remoteId ?? this.remoteId,
      startedAt: startedAt ?? this.startedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (localId.present) {
      map['local_id'] = Variable<String>(localId.value);
    }
    if (seasonId.present) {
      map['season_id'] = Variable<String>(seasonId.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<DateTime>(startedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalPlaythroughsCompanion(')
          ..write('localId: $localId, ')
          ..write('seasonId: $seasonId, ')
          ..write('remoteId: $remoteId, ')
          ..write('startedAt: $startedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$EchoDatabase extends GeneratedDatabase {
  _$EchoDatabase(QueryExecutor e) : super(e);
  $EchoDatabaseManager get managers => $EchoDatabaseManager(this);
  late final $CachedSeasonsTable cachedSeasons = $CachedSeasonsTable(this);
  late final $PendingChoiceEventsTable pendingChoiceEvents =
      $PendingChoiceEventsTable(this);
  late final $LocalPlaythroughsTable localPlaythroughs =
      $LocalPlaythroughsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities =>
      [cachedSeasons, pendingChoiceEvents, localPlaythroughs];
}

typedef $$CachedSeasonsTableCreateCompanionBuilder = CachedSeasonsCompanion
    Function({
  required String id,
  required int version,
  required String body,
  required DateTime fetchedAt,
  Value<int> rowid,
});
typedef $$CachedSeasonsTableUpdateCompanionBuilder = CachedSeasonsCompanion
    Function({
  Value<String> id,
  Value<int> version,
  Value<String> body,
  Value<DateTime> fetchedAt,
  Value<int> rowid,
});

class $$CachedSeasonsTableFilterComposer
    extends Composer<_$EchoDatabase, $CachedSeasonsTable> {
  $$CachedSeasonsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get version => $composableBuilder(
      column: $table.version, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get body => $composableBuilder(
      column: $table.body, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get fetchedAt => $composableBuilder(
      column: $table.fetchedAt, builder: (column) => ColumnFilters(column));
}

class $$CachedSeasonsTableOrderingComposer
    extends Composer<_$EchoDatabase, $CachedSeasonsTable> {
  $$CachedSeasonsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get version => $composableBuilder(
      column: $table.version, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get body => $composableBuilder(
      column: $table.body, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get fetchedAt => $composableBuilder(
      column: $table.fetchedAt, builder: (column) => ColumnOrderings(column));
}

class $$CachedSeasonsTableAnnotationComposer
    extends Composer<_$EchoDatabase, $CachedSeasonsTable> {
  $$CachedSeasonsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get version =>
      $composableBuilder(column: $table.version, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<DateTime> get fetchedAt =>
      $composableBuilder(column: $table.fetchedAt, builder: (column) => column);
}

class $$CachedSeasonsTableTableManager extends RootTableManager<
    _$EchoDatabase,
    $CachedSeasonsTable,
    CachedSeasonRow,
    $$CachedSeasonsTableFilterComposer,
    $$CachedSeasonsTableOrderingComposer,
    $$CachedSeasonsTableAnnotationComposer,
    $$CachedSeasonsTableCreateCompanionBuilder,
    $$CachedSeasonsTableUpdateCompanionBuilder,
    (
      CachedSeasonRow,
      BaseReferences<_$EchoDatabase, $CachedSeasonsTable, CachedSeasonRow>
    ),
    CachedSeasonRow,
    PrefetchHooks Function()> {
  $$CachedSeasonsTableTableManager(_$EchoDatabase db, $CachedSeasonsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedSeasonsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CachedSeasonsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CachedSeasonsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<int> version = const Value.absent(),
            Value<String> body = const Value.absent(),
            Value<DateTime> fetchedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              CachedSeasonsCompanion(
            id: id,
            version: version,
            body: body,
            fetchedAt: fetchedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required int version,
            required String body,
            required DateTime fetchedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              CachedSeasonsCompanion.insert(
            id: id,
            version: version,
            body: body,
            fetchedAt: fetchedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$CachedSeasonsTableProcessedTableManager = ProcessedTableManager<
    _$EchoDatabase,
    $CachedSeasonsTable,
    CachedSeasonRow,
    $$CachedSeasonsTableFilterComposer,
    $$CachedSeasonsTableOrderingComposer,
    $$CachedSeasonsTableAnnotationComposer,
    $$CachedSeasonsTableCreateCompanionBuilder,
    $$CachedSeasonsTableUpdateCompanionBuilder,
    (
      CachedSeasonRow,
      BaseReferences<_$EchoDatabase, $CachedSeasonsTable, CachedSeasonRow>
    ),
    CachedSeasonRow,
    PrefetchHooks Function()>;
typedef $$PendingChoiceEventsTableCreateCompanionBuilder
    = PendingChoiceEventsCompanion Function({
  required String localId,
  required String localPlaythroughId,
  required String seasonId,
  required String vignetteId,
  required String choiceId,
  required DateTime committedAt,
  Value<int?> deliberationMs,
  required DateTime createdAt,
  Value<int> rowid,
});
typedef $$PendingChoiceEventsTableUpdateCompanionBuilder
    = PendingChoiceEventsCompanion Function({
  Value<String> localId,
  Value<String> localPlaythroughId,
  Value<String> seasonId,
  Value<String> vignetteId,
  Value<String> choiceId,
  Value<DateTime> committedAt,
  Value<int?> deliberationMs,
  Value<DateTime> createdAt,
  Value<int> rowid,
});

class $$PendingChoiceEventsTableFilterComposer
    extends Composer<_$EchoDatabase, $PendingChoiceEventsTable> {
  $$PendingChoiceEventsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get localId => $composableBuilder(
      column: $table.localId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get localPlaythroughId => $composableBuilder(
      column: $table.localPlaythroughId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get seasonId => $composableBuilder(
      column: $table.seasonId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get vignetteId => $composableBuilder(
      column: $table.vignetteId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get choiceId => $composableBuilder(
      column: $table.choiceId, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get committedAt => $composableBuilder(
      column: $table.committedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get deliberationMs => $composableBuilder(
      column: $table.deliberationMs,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));
}

class $$PendingChoiceEventsTableOrderingComposer
    extends Composer<_$EchoDatabase, $PendingChoiceEventsTable> {
  $$PendingChoiceEventsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get localId => $composableBuilder(
      column: $table.localId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get localPlaythroughId => $composableBuilder(
      column: $table.localPlaythroughId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get seasonId => $composableBuilder(
      column: $table.seasonId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get vignetteId => $composableBuilder(
      column: $table.vignetteId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get choiceId => $composableBuilder(
      column: $table.choiceId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get committedAt => $composableBuilder(
      column: $table.committedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get deliberationMs => $composableBuilder(
      column: $table.deliberationMs,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));
}

class $$PendingChoiceEventsTableAnnotationComposer
    extends Composer<_$EchoDatabase, $PendingChoiceEventsTable> {
  $$PendingChoiceEventsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get localId =>
      $composableBuilder(column: $table.localId, builder: (column) => column);

  GeneratedColumn<String> get localPlaythroughId => $composableBuilder(
      column: $table.localPlaythroughId, builder: (column) => column);

  GeneratedColumn<String> get seasonId =>
      $composableBuilder(column: $table.seasonId, builder: (column) => column);

  GeneratedColumn<String> get vignetteId => $composableBuilder(
      column: $table.vignetteId, builder: (column) => column);

  GeneratedColumn<String> get choiceId =>
      $composableBuilder(column: $table.choiceId, builder: (column) => column);

  GeneratedColumn<DateTime> get committedAt => $composableBuilder(
      column: $table.committedAt, builder: (column) => column);

  GeneratedColumn<int> get deliberationMs => $composableBuilder(
      column: $table.deliberationMs, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$PendingChoiceEventsTableTableManager extends RootTableManager<
    _$EchoDatabase,
    $PendingChoiceEventsTable,
    PendingChoiceEventRow,
    $$PendingChoiceEventsTableFilterComposer,
    $$PendingChoiceEventsTableOrderingComposer,
    $$PendingChoiceEventsTableAnnotationComposer,
    $$PendingChoiceEventsTableCreateCompanionBuilder,
    $$PendingChoiceEventsTableUpdateCompanionBuilder,
    (
      PendingChoiceEventRow,
      BaseReferences<_$EchoDatabase, $PendingChoiceEventsTable,
          PendingChoiceEventRow>
    ),
    PendingChoiceEventRow,
    PrefetchHooks Function()> {
  $$PendingChoiceEventsTableTableManager(
      _$EchoDatabase db, $PendingChoiceEventsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PendingChoiceEventsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PendingChoiceEventsTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PendingChoiceEventsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> localId = const Value.absent(),
            Value<String> localPlaythroughId = const Value.absent(),
            Value<String> seasonId = const Value.absent(),
            Value<String> vignetteId = const Value.absent(),
            Value<String> choiceId = const Value.absent(),
            Value<DateTime> committedAt = const Value.absent(),
            Value<int?> deliberationMs = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              PendingChoiceEventsCompanion(
            localId: localId,
            localPlaythroughId: localPlaythroughId,
            seasonId: seasonId,
            vignetteId: vignetteId,
            choiceId: choiceId,
            committedAt: committedAt,
            deliberationMs: deliberationMs,
            createdAt: createdAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String localId,
            required String localPlaythroughId,
            required String seasonId,
            required String vignetteId,
            required String choiceId,
            required DateTime committedAt,
            Value<int?> deliberationMs = const Value.absent(),
            required DateTime createdAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              PendingChoiceEventsCompanion.insert(
            localId: localId,
            localPlaythroughId: localPlaythroughId,
            seasonId: seasonId,
            vignetteId: vignetteId,
            choiceId: choiceId,
            committedAt: committedAt,
            deliberationMs: deliberationMs,
            createdAt: createdAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PendingChoiceEventsTableProcessedTableManager = ProcessedTableManager<
    _$EchoDatabase,
    $PendingChoiceEventsTable,
    PendingChoiceEventRow,
    $$PendingChoiceEventsTableFilterComposer,
    $$PendingChoiceEventsTableOrderingComposer,
    $$PendingChoiceEventsTableAnnotationComposer,
    $$PendingChoiceEventsTableCreateCompanionBuilder,
    $$PendingChoiceEventsTableUpdateCompanionBuilder,
    (
      PendingChoiceEventRow,
      BaseReferences<_$EchoDatabase, $PendingChoiceEventsTable,
          PendingChoiceEventRow>
    ),
    PendingChoiceEventRow,
    PrefetchHooks Function()>;
typedef $$LocalPlaythroughsTableCreateCompanionBuilder
    = LocalPlaythroughsCompanion Function({
  required String localId,
  required String seasonId,
  Value<String?> remoteId,
  required DateTime startedAt,
  Value<int> rowid,
});
typedef $$LocalPlaythroughsTableUpdateCompanionBuilder
    = LocalPlaythroughsCompanion Function({
  Value<String> localId,
  Value<String> seasonId,
  Value<String?> remoteId,
  Value<DateTime> startedAt,
  Value<int> rowid,
});

class $$LocalPlaythroughsTableFilterComposer
    extends Composer<_$EchoDatabase, $LocalPlaythroughsTable> {
  $$LocalPlaythroughsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get localId => $composableBuilder(
      column: $table.localId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get seasonId => $composableBuilder(
      column: $table.seasonId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get remoteId => $composableBuilder(
      column: $table.remoteId, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get startedAt => $composableBuilder(
      column: $table.startedAt, builder: (column) => ColumnFilters(column));
}

class $$LocalPlaythroughsTableOrderingComposer
    extends Composer<_$EchoDatabase, $LocalPlaythroughsTable> {
  $$LocalPlaythroughsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get localId => $composableBuilder(
      column: $table.localId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get seasonId => $composableBuilder(
      column: $table.seasonId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get remoteId => $composableBuilder(
      column: $table.remoteId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get startedAt => $composableBuilder(
      column: $table.startedAt, builder: (column) => ColumnOrderings(column));
}

class $$LocalPlaythroughsTableAnnotationComposer
    extends Composer<_$EchoDatabase, $LocalPlaythroughsTable> {
  $$LocalPlaythroughsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get localId =>
      $composableBuilder(column: $table.localId, builder: (column) => column);

  GeneratedColumn<String> get seasonId =>
      $composableBuilder(column: $table.seasonId, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<DateTime> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);
}

class $$LocalPlaythroughsTableTableManager extends RootTableManager<
    _$EchoDatabase,
    $LocalPlaythroughsTable,
    LocalPlaythroughRow,
    $$LocalPlaythroughsTableFilterComposer,
    $$LocalPlaythroughsTableOrderingComposer,
    $$LocalPlaythroughsTableAnnotationComposer,
    $$LocalPlaythroughsTableCreateCompanionBuilder,
    $$LocalPlaythroughsTableUpdateCompanionBuilder,
    (
      LocalPlaythroughRow,
      BaseReferences<_$EchoDatabase, $LocalPlaythroughsTable,
          LocalPlaythroughRow>
    ),
    LocalPlaythroughRow,
    PrefetchHooks Function()> {
  $$LocalPlaythroughsTableTableManager(
      _$EchoDatabase db, $LocalPlaythroughsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalPlaythroughsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalPlaythroughsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalPlaythroughsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> localId = const Value.absent(),
            Value<String> seasonId = const Value.absent(),
            Value<String?> remoteId = const Value.absent(),
            Value<DateTime> startedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalPlaythroughsCompanion(
            localId: localId,
            seasonId: seasonId,
            remoteId: remoteId,
            startedAt: startedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String localId,
            required String seasonId,
            Value<String?> remoteId = const Value.absent(),
            required DateTime startedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalPlaythroughsCompanion.insert(
            localId: localId,
            seasonId: seasonId,
            remoteId: remoteId,
            startedAt: startedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalPlaythroughsTableProcessedTableManager = ProcessedTableManager<
    _$EchoDatabase,
    $LocalPlaythroughsTable,
    LocalPlaythroughRow,
    $$LocalPlaythroughsTableFilterComposer,
    $$LocalPlaythroughsTableOrderingComposer,
    $$LocalPlaythroughsTableAnnotationComposer,
    $$LocalPlaythroughsTableCreateCompanionBuilder,
    $$LocalPlaythroughsTableUpdateCompanionBuilder,
    (
      LocalPlaythroughRow,
      BaseReferences<_$EchoDatabase, $LocalPlaythroughsTable,
          LocalPlaythroughRow>
    ),
    LocalPlaythroughRow,
    PrefetchHooks Function()>;

class $EchoDatabaseManager {
  final _$EchoDatabase _db;
  $EchoDatabaseManager(this._db);
  $$CachedSeasonsTableTableManager get cachedSeasons =>
      $$CachedSeasonsTableTableManager(_db, _db.cachedSeasons);
  $$PendingChoiceEventsTableTableManager get pendingChoiceEvents =>
      $$PendingChoiceEventsTableTableManager(_db, _db.pendingChoiceEvents);
  $$LocalPlaythroughsTableTableManager get localPlaythroughs =>
      $$LocalPlaythroughsTableTableManager(_db, _db.localPlaythroughs);
}
