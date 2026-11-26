import 'dart:convert';
import 'dart:io';
import 'package:autonitor/services/migrations/introduce_runid.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

part 'database.g.dart';

/// 关系状态类报告：描述某个用户当前处于什么关系状态，跨同步累计保留。
///
/// 每个用户在同一时刻只会命中其中一条，写入时按 (owner_id, user_id) 覆盖，
/// 因此看板上的数字等于"当前处于该状态的用户数"。
const Set<String> kCumulativeChangeTypes = {
  'normal_unfollowed',
  'mutual_unfollowed',
  'oneway_unfollowed',
  'temporarily_restricted',
  'suspended',
  'deactivated',
  'recovered',
  'other_reasons',
};

/// 事件类报告：描述"本次同步发生了什么"，每次同步整体替换。
const Set<String> kTransientChangeTypes = {
  'profile_update',
  'new_followers_following',
  'be_followed_back',
};

//数据库表定义
@DataClassName('LoggedAccount')
class LoggedAccounts extends Table {
  TextColumn get id => text()();
  TextColumn get name => text().nullable()();
  TextColumn get screenName => text().nullable()();
  TextColumn get bio => text().nullable()();
  TextColumn get location => text().nullable()();
  TextColumn get link => text().nullable()();
  TextColumn get joinTime => text().nullable()();
  BoolColumn get isVerified =>
      boolean().nullable().withDefault(const Constant(false))();
  BoolColumn get isProtected =>
      boolean().nullable().withDefault(const Constant(false))();
  IntColumn get followersCount => integer().withDefault(const Constant(0))();
  IntColumn get followingCount => integer().withDefault(const Constant(0))();
  IntColumn get statusesCount => integer().withDefault(const Constant(0))();
  IntColumn get mediaCount => integer().withDefault(const Constant(0))();
  IntColumn get favouritesCount => integer().withDefault(const Constant(0))();
  IntColumn get listedCount => integer().withDefault(const Constant(0))();
  TextColumn get latestRawJson => text().named('latest_raw_json').nullable()();
  TextColumn get avatarUrl => text().nullable()();
  TextColumn get bannerUrl => text().nullable()();
  TextColumn get avatarLocalPath =>
      text().named('avatar_local_path').nullable()();
  TextColumn get bannerLocalPath =>
      text().named('banner_local_path').nullable()();
  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('AccountProfileHistoryEntry')
class AccountProfileHistory extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get ownerId => text()
      .named('owner_id')
      .references(LoggedAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get reverseDiffJson => text().named('reverse_diff_json')();
  DateTimeColumn get timestamp => dateTime()();
}

@DataClassName('FollowUser')
class FollowUsers extends Table {
  TextColumn get ownerId => text()
      .named('owner_id')
      .references(LoggedAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get userId => text().named('user_id')();
  TextColumn get latestRawJson => text().named('latest_raw_json').nullable()();
  TextColumn get name => text().nullable()();
  TextColumn get screenName => text().nullable()();
  TextColumn get avatarUrl => text().nullable()();
  TextColumn get bannerUrl => text().nullable()();
  TextColumn get bio => text().nullable()();
  TextColumn get avatarLocalPath =>
      text().named('avatar_local_path').nullable()();
  TextColumn get bannerLocalPath =>
      text().named('banner_local_path').nullable()();
  TextColumn get runId => text().named('run_id').nullable()();
  BoolColumn get isFollower => boolean().withDefault(const Constant(false))();
  BoolColumn get isFollowing => boolean().withDefault(const Constant(false))();

  // Sort columns (Added in v2)
  IntColumn get followerSort => integer().nullable()();
  IntColumn get followingSort => integer().nullable()();

  @override
  Set<Column> get primaryKey => {ownerId, userId};
}

@DataClassName('FollowUserHistoryEntry')
class FollowUsersHistory extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get ownerId => text().named('owner_id')();
  TextColumn get userId => text().named('user_id')();
  TextColumn get reverseDiffJson => text().named('reverse_diff_json')();
  TextColumn get runId => text().named('run_id').nullable()();
  DateTimeColumn get timestamp => dateTime()();
  @override
  List<String> get customConstraints => [
    'FOREIGN KEY(owner_id, user_id) REFERENCES follow_users(owner_id, user_id) ON DELETE CASCADE',
  ];
}

@DataClassName('ChangeReportEntry')
class ChangeReports extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get ownerId => text()
      .named('owner_id')
      .references(LoggedAccounts, #id, onDelete: KeyAction.cascade)();
  TextColumn get userId => text().named('user_id')();
  TextColumn get changeType => text().named('change_type')();
  DateTimeColumn get timestamp => dateTime()();
  TextColumn get userSnapshotJson =>
      text().named('user_snapshot_json').nullable()();
}

@DataClassName('MediaHistoryEntry')
class MediaHistory extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get mediaType => text().named('media_type')();
  TextColumn get localFilePath => text().named('local_file_path')();
  TextColumn get remoteUrl => text().named('remote_url')();
  BoolColumn get isHighQuality =>
      boolean().named('is_high_quality').withDefault(const Constant(false))();
}

@DataClassName('SyncLogsEntry')
class SyncLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get runId => text().named('run_id')();
  DateTimeColumn get timestamp => dateTime().named('timestamp')();
  IntColumn get status => integer().named('status')();
  TextColumn get ownerId =>
      text().named('owner_id').withDefault(const Constant(''))();
}

@DriftDatabase(
  tables: [
    LoggedAccounts,
    AccountProfileHistory,
    FollowUsers,
    FollowUsersHistory,
    ChangeReports,
    MediaHistory,
    SyncLogs,
  ],
)
// 主class
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());
  // 数据库迁移
  @override
  // [Upgraded] Upgrade to version 3 to include indices
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (Migrator m, int from, int to) async {
      if (from < 2) {
        await m.addColumn(followUsers, followUsers.followerSort);
        await m.addColumn(followUsers, followUsers.followingSort);
      }
      if (from < 3) {
        // [Performance Fix] Create indices for sorting columns
        // This makes ORDER BY + LIMIT/OFFSET extremely fast
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_follower_sort ON follow_users (owner_id, is_follower, follower_sort)',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_following_sort ON follow_users (owner_id, is_following, following_sort)',
        );
      }
      if (from < 4) {
        // [New Migration] Add run_id columns
        await customStatement(
          'ALTER TABLE follow_users ADD COLUMN run_id TEXT',
        );
      }
      if (from < 5) {
        await MigrateToV5.execute(this);
      }
    },
  );
  // 快捷方法

  Future<List<TypedResult>> getFollowHistoryWithLogs(
    String ownerId,
    String userId,
  ) {
    return (select(followUsersHistory).join([
            leftOuterJoin(
              syncLogs,
              syncLogs.runId.equalsExp(followUsersHistory.runId),
            ),
          ])
          ..where(
            followUsersHistory.ownerId.equals(ownerId) &
                followUsersHistory.userId.equals(userId),
          )
          ..orderBy([
            OrderingTerm.desc(syncLogs.timestamp),
          ])) // Order by master run time
        .get();
  }

  Future<List<FollowUser>> getNetworkRelationships(String ownerId) async {
    return (select(
      followUsers,
    )..where((tbl) => tbl.ownerId.equals(ownerId))).get();
  }

  Future<void> batchUpsertNetworkRelationships(
    List<FollowUsersCompanion> companions,
  ) async {
    await batch((batch) {
      for (final companion in companions) {
        batch.insert(
          followUsers,
          companion,
          mode: InsertMode.insertOrReplace,
          onConflict: DoUpdate(
            (old) => FollowUsersCompanion(
              name: companion.name,
              screenName: companion.screenName,
              avatarUrl: companion.avatarUrl,
              bannerUrl: companion.bannerUrl,
              bio: companion.bio,
              latestRawJson: companion.latestRawJson,
              isFollower: companion.isFollower,
              isFollowing: companion.isFollowing,
              followerSort: companion.followerSort,
              followingSort: companion.followingSort,
              avatarLocalPath: companion.avatarLocalPath,
              bannerLocalPath: companion.bannerLocalPath,
            ),
          ),
        );
      }
    });
  }

  Future<void> deleteNetworkRelationships(
    String ownerId,
    List<String> userIdsToRemove,
  ) async {
    await (delete(followUsers)..where(
          (tbl) =>
              tbl.ownerId.equals(ownerId) & tbl.userId.isIn(userIdsToRemove),
        ))
        .go();
  }

  Future<void> batchInsertFollowUsersHistory(
    List<FollowUsersHistoryCompanion> historyCompanions,
  ) async {
    await batch((batch) {
      batch.insertAll(followUsersHistory, historyCompanions);
    });
  }

  Future<void> replaceChangeReport(
    String ownerId,
    List<ChangeReportsCompanion> reportCompanions,
  ) async {
    // 状态类：描述某个关系用户当前处于什么状态，跨同步累计保留。
    // 事件类：描述"本次同步发生了什么"，每次同步整体替换。
    final cumulative = reportCompanions
        .where((c) => kCumulativeChangeTypes.contains(c.changeType.value))
        .toList();
    final transient = reportCompanions
        .where((c) => !kCumulativeChangeTypes.contains(c.changeType.value))
        .toList();
    final touchedUserIds = cumulative
        .map((c) => c.userId.value)
        .toSet()
        .toList();

    await transaction(() async {
      // 1) 事件类整体替换。
      await (delete(changeReports)..where(
            (tbl) =>
                tbl.ownerId.equals(ownerId) &
                tbl.changeType.isIn(kTransientChangeTypes.toList()),
          ))
          .go();

      // 2) 状态类只替换本次涉及的这些用户，其他用户的历史状态保留。
      if (touchedUserIds.isNotEmpty) {
        await (delete(changeReports)..where(
              (tbl) =>
                  tbl.ownerId.equals(ownerId) &
                  tbl.changeType.isIn(kCumulativeChangeTypes.toList()) &
                  tbl.userId.isIn(touchedUserIds),
            ))
            .go();
      }

      if (transient.isNotEmpty || cumulative.isNotEmpty) {
        await batch((batch) {
          batch.insertAll(changeReports, [...transient, ...cumulative]);
        });
      }

      // 3) 回填：升级前只写进 follow_users.status、没进过报告表的历史状态。
      await _backfillStatusReports(ownerId);
    });
  }

  /// 把 `follow_users.status` 中已有的关系状态补成报告行，每个用户最多一条。
  ///
  /// 旧版本每次同步都会清空 change_reports，导致历史状态（取关/冻结/注销…）
  /// 只剩在看板之外的用户表里。该回填让累计视图在升级后立刻反映真实情况。
  Future<void> _backfillStatusReports(String ownerId) async {
    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await customStatement(
      '''
INSERT INTO change_reports (owner_id, user_id, change_type, timestamp, user_snapshot_json)
SELECT f.owner_id,
       f.user_id,
       CASE
         WHEN f.status IN ('unknown_error', 'unknown_gql_response') THEN 'other_reasons'
         ELSE f.status
       END,
       ?,
       NULL
FROM follow_users f
WHERE f.owner_id = ?
  AND f.status IS NOT NULL
  AND (
        f.status IN ('normal_unfollowed', 'mutual_unfollowed', 'oneway_unfollowed',
                     'temporarily_restricted', 'suspended', 'deactivated', 'recovered')
     OR f.status IN ('unknown_error', 'unknown_gql_response', 'other_reasons')
      )
  AND NOT EXISTS (
        SELECT 1 FROM change_reports c
        WHERE c.owner_id = f.owner_id
          AND c.user_id = f.user_id
          AND c.change_type IN (${kCumulativeChangeTypes.map((t) => "'$t'").join(', ')})
      )
''',
      [nowSeconds, ownerId],
    );
  }

  Future<int> insertMediaHistory(MediaHistoryCompanion companion) {
    return into(mediaHistory).insert(companion);
  }

  Future<void> updateFollowUserLocalPath({
    required String ownerId,
    required String userId,
    String? avatarPath,
    String? bannerPath,
  }) {
    final companion = FollowUsersCompanion(
      avatarLocalPath: avatarPath == null
          ? const Value.absent()
          : Value(avatarPath),
      bannerLocalPath: bannerPath == null
          ? const Value.absent()
          : Value(bannerPath),
      bannerUrl: const Value.absent(),
    );

    return (update(followUsers)..where(
          (tbl) => tbl.ownerId.equals(ownerId) & tbl.userId.equals(userId),
        ))
        .write(companion);
  }

  Future<void> updateLoggedAccountLocalPath({
    required String accountId,
    String? avatarPath,
    String? bannerPath,
  }) {
    final companion = LoggedAccountsCompanion(
      avatarLocalPath: avatarPath == null
          ? const Value.absent()
          : Value(avatarPath),
      bannerLocalPath: bannerPath == null
          ? const Value.absent()
          : Value(bannerPath),
    );

    return (update(
      loggedAccounts,
    )..where((tbl) => tbl.id.equals(accountId))).write(companion);
  }

  // 获取指定账号的所有同步记录
  Stream<List<SyncLogsEntry>> watchSyncLogs(String ownerId) {
    return (select(syncLogs)
          ..where((tbl) => tbl.ownerId.equals(ownerId))
          ..orderBy([(t) => OrderingTerm.desc(t.timestamp)]))
        .watch();
  }

  // 核心回档事务
  Future<void> rollbackToRun({
    required String ownerId,
    required String targetRunId,
  }) async {
    await transaction(() async {
      // 1. 获取目标 RunID 的元数据（用于确定时间界限）
      final targetLog = await (select(
        syncLogs,
      )..where((tbl) => tbl.runId.equals(targetRunId))).getSingle();
      final targetTime = targetLog.timestamp;

      // 2. 获取所有在目标时间点之后的历史记录，并按时间倒序排列
      // 必须倒序（从新到旧）应用 Diff，才能正确回溯状态
      final futureHistory =
          await (select(followUsersHistory)
                ..where(
                  (tbl) =>
                      tbl.ownerId.equals(ownerId) &
                      tbl.timestamp.isBiggerThanValue(targetTime),
                )
                ..orderBy([(t) => OrderingTerm.desc(t.timestamp)]))
              .get();

      // 3. 应用反向 Diff 覆盖 follow_users 表
      for (final history in futureHistory) {
        final Map<String, dynamic> diffData = jsonDecode(
          history.reverseDiffJson,
        );

        // 修正路径字段：由于 Drift 默认 JSON Key 可能与列名不同，
        // 这里手动确保 avatar_local_path 和 banner_local_path 被正确映射
        final companion = FollowUsersCompanion(
          latestRawJson: diffData.containsKey('latest_raw_json')
              ? Value(diffData['latest_raw_json'] as String?)
              : const Value.absent(),
          name: diffData.containsKey('name')
              ? Value(diffData['name'] as String?)
              : const Value.absent(),
          screenName: diffData.containsKey('screen_name')
              ? Value(diffData['screen_name'] as String?)
              : const Value.absent(),
          avatarUrl: diffData.containsKey('avatar_url')
              ? Value(diffData['avatar_url'] as String?)
              : const Value.absent(),
          bannerUrl: diffData.containsKey('banner_url')
              ? Value(diffData['banner_url'] as String?)
              : const Value.absent(),
          bio: diffData.containsKey('bio')
              ? Value(diffData['bio'] as String?)
              : const Value.absent(),
          avatarLocalPath: diffData.containsKey('avatar_local_path')
              ? Value(diffData['avatar_local_path'] as String?)
              : const Value.absent(),
          bannerLocalPath: diffData.containsKey('banner_local_path')
              ? Value(diffData['banner_local_path'] as String?)
              : const Value.absent(),
          isFollower: diffData.containsKey('is_follower')
              ? Value(diffData['is_follower'] as bool)
              : const Value.absent(),
          isFollowing: diffData.containsKey('is_following')
              ? Value(diffData['is_following'] as bool)
              : const Value.absent(),
          followerSort: diffData.containsKey('follower_sort')
              ? Value(diffData['follower_sort'] as int?)
              : const Value.absent(),
          followingSort: diffData.containsKey('following_sort')
              ? Value(diffData['following_sort'] as int?)
              : const Value.absent(),
        );

        await (update(followUsers)..where(
              (tbl) =>
                  tbl.ownerId.equals(ownerId) &
                  tbl.userId.equals(history.userId),
            ))
            .write(companion);
      }

      // 4. 删除“未来”的用户
      // 逻辑：如果在应用完所有反向 Diff 后，某个用户的 runId 仍然属于“未来”的 RunID，
      // 或者该用户是在 targetTime 之后才第一次出现的，则将其删除。
      // 这里通过时间戳比对删除所有在目标时间后新增且没有更早历史记录的用户。
      await (delete(followUsers)..where((tbl) {
            return tbl.ownerId.equals(ownerId) &
                tbl.runId.isNotInQuery(
                  selectOnly(syncLogs)
                    ..addColumns([syncLogs.runId])
                    ..where(
                      syncLogs.timestamp.isSmallerOrEqualValue(targetTime),
                    ),
                );
          }))
          .go();

      // 5. 清理“未来”的辅助数据
      // 删除目标时间点之后的同步日志
      await (delete(syncLogs)..where(
            (tbl) =>
                tbl.ownerId.equals(ownerId) &
                tbl.timestamp.isBiggerThanValue(targetTime),
          ))
          .go();

      // 删除目标时间点之后的变更报告
      await (delete(changeReports)..where(
            (tbl) =>
                tbl.ownerId.equals(ownerId) &
                tbl.timestamp.isBiggerThanValue(targetTime),
          ))
          .go();

      // 删除已经回档过的历史记录
      await (delete(followUsersHistory)..where(
            (tbl) =>
                tbl.ownerId.equals(ownerId) &
                tbl.timestamp.isBiggerThanValue(targetTime),
          ))
          .go();
    });
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationSupportDirectory();
    await Directory(dbFolder.path).create(recursive: true);
    final file = File(p.join(dbFolder.path, 'autonitor_data.db'));
    return NativeDatabase(file);
  });
}
