import 'package:drift/drift.dart';

import '../database.dart';
import '../log_service.dart';

/// 清除由"历史状态回填"制造出来的「其它原因」报告行。
///
/// 背景：`_backfillStatusReports` 会把 `follow_users` 里遗留的
/// `status = 'unknown_error' / 'unknown_gql_response'` 映射成
/// `change_type = 'other_reasons'` 写进 `change_reports`。
///
/// 但 `unknown_error` 表示"查询失败、状态未知"，不是一种关系结论。
/// 回填把它当成结论，会让看板上的「其它原因」凭空涨到几百条
/// （实测一份数据库：362 条 unknown 状态被回填成 291 条其它原因）。
///
/// 这个迁移只删除可以证明是回填产物的行：报告类型为 `other_reasons`，
/// 且对应用户在 `follow_users` 里的状态仍然是 `unknown_*` / `other_reasons`。
/// 原始状态依旧保存在 `follow_users.latest_raw_json.status`，不会丢数据。
class PurgeBackfilledUnknownReports {
  static Future<void> execute(AppDatabase db) async {
    const Set<String> unknownStatuses = {
      'unknown_error',
      'unknown_gql_response',
      'other_reasons',
    };
    final statusList = unknownStatuses.map((s) => "'$s'").join(', ');

    final before = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM change_reports WHERE change_type = ?',
          variables: [Variable.withString('other_reasons')],
          readsFrom: {db.changeReports},
        )
        .getSingle();
    final beforeCount = before.read<int>('c');

    await db.customStatement(
      '''
DELETE FROM change_reports
WHERE change_type = 'other_reasons'
  AND user_id IN (
        SELECT f.user_id
        FROM (
               SELECT user_id,
                      json_extract(latest_raw_json, '\$.status') AS status
               FROM follow_users
             ) AS f
        WHERE f.status IN ($statusList)
      )
''',
    );

    final after = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM change_reports WHERE change_type = ?',
          variables: [Variable.withString('other_reasons')],
          readsFrom: {db.changeReports},
        )
        .getSingle();
    final afterCount = after.read<int>('c');

    logger.i(
      'PurgeBackfilledUnknownReports: removed ${beforeCount - afterCount} of '
      '$beforeCount other_reasons rows (remaining: $afterCount).',
    );
  }
}
