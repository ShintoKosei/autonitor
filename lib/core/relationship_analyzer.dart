import 'dart:convert';
import 'dart:math';
import 'package:autonitor/models/twitter_user.dart';
import 'package:autonitor/services/x_client_transaction_service.dart';
import 'package:drift/drift.dart';
import 'network_data_fetcher.dart';
import '../services/database.dart';
import '../services/twitter_api_service.dart';
import '../repositories/account_repository.dart';
import '../models/sync_progress.dart';

const String kChangeTypeProfileUpdate = 'profile_update';

/// Returned by the status resolver when the lookup itself failed (network,
/// HTTP error, unexpected payload). It is deliberately distinct from any real
/// relationship verdict so callers can fall back to flag-based classification
/// instead of inventing a category.
const String kStatusLookupFailed = 'lookup_failed';

/// The account still exists and is reachable.
const String kStatusNormal = 'normal';

/// 单条状态查询的最大次数，防止长时间未同步后的积压把请求量放大。
const int _maxSingleStatusLookups = 80;

typedef LogCallback = void Function(String message);

String? classifyKeptRelationshipChange({
  required bool wasFollower,
  required bool wasFollowing,
  required bool isNowFollower,
  required bool isNowFollowing,
  required String oldStatus,
  required String oldKeptStatus,
  required String currentStatus,
}) {
  if (currentStatus == 'temporarily_restricted') {
    return 'temporarily_restricted';
  }

  final wasPreviouslyUnavailable =
      oldStatus == 'suspended' ||
      oldStatus == 'deactivated' ||
      oldStatus == 'temporarily_restricted' ||
      oldKeptStatus == 'suspended' ||
      oldKeptStatus == 'deactivated' ||
      oldKeptStatus == 'temporarily_restricted';
  if (wasPreviouslyUnavailable && currentStatus == 'normal') {
    return 'recovered';
  }

  final wasPreviouslyUnfollowed =
      oldStatus == 'normal_unfollowed' ||
      oldStatus == 'mutual_unfollowed' ||
      oldStatus == 'oneway_unfollowed' ||
      oldKeptStatus == 'normal_unfollowed' ||
      oldKeptStatus == 'mutual_unfollowed' ||
      oldKeptStatus == 'oneway_unfollowed';
  if (wasPreviouslyUnfollowed && !wasFollowing && isNowFollowing) {
    return 'recovered';
  }

  final becameMutual =
      isNowFollower &&
      isNowFollowing &&
      ((wasFollower && !wasFollowing) || (!wasFollower && wasFollowing));
  if (becameMutual) {
    return 'be_followed_back';
  }

  final relationshipChanged =
      wasFollower != isNowFollower || wasFollowing != isNowFollowing;
  if (relationshipChanged &&
      wasFollower &&
      wasFollowing &&
      isNowFollower != isNowFollowing) {
    return 'oneway_unfollowed';
  }

  return null;
}

/// Maps the resolved account state plus the previously stored flags onto a
/// removal report category.
///
/// The relationship direction (普通取关 / 互关双取) is fully derivable from the
/// old flags, so it is decided here instead of depending on a network lookup.
/// Only `suspended`, `deactivated` and `temporarily_restricted` require a
/// positive answer from the API.
String classifyRemovedRelationshipChange({
  required String? apiStatus,
  required bool wasFollower,
  required bool wasFollowing,
}) {
  if (apiStatus == 'suspended' ||
      apiStatus == 'deactivated' ||
      apiStatus == 'temporarily_restricted') {
    return apiStatus!;
  }

  if (wasFollower && wasFollowing) return 'mutual_unfollowed';
  if (wasFollower) return 'normal_unfollowed';
  if (wasFollowing) return 'normal_unfollowed';
  if (apiStatus == kStatusNormal) return 'normal_unfollowed';

  // No historical relationship and no verdict: report it as unknown rather
  // than inventing an unfollow.
  return 'other_reasons';
}

class RelationshipAnalysisResult {
  final Set<String> addedIds;
  final Set<String> removedIds;
  final Set<String> keptIds;
  final List<ChangeReportsCompanion> reports;
  final Map<String, String> categorizedRemovals;
  final Map<String, String> keptUserStatusUpdates;
  final List<FollowUsersHistoryCompanion> historyToInsert;

  RelationshipAnalysisResult({
    required this.addedIds,
    required this.removedIds,
    required this.keptIds,
    required this.reports,
    required this.categorizedRemovals,
    required this.keptUserStatusUpdates,
    required this.historyToInsert,
  });
}

class RelationshipAnalyzer {
  final TwitterApiService _apiServiceGql;
  final AccountRepository _accountRepository;
  final String _ownerId;
  final String _ownerCookie;
  final LogCallback _log;
  final Future<void> Function() _checkPauseCallback;
  final XClientTransactionService? _xctService;
  final String _apiRequestMode;
  final String? _cffiUrl;
  final String? _cffiApiKey;
  final SyncProgressCallback? _onProgress;
  final Future<void> Function(DateTime resetAt)? _waitForRateLimit;

  RelationshipAnalyzer({
    required TwitterApiService apiServiceGql,
    required AccountRepository accountRepository,
    required String ownerId,
    required String ownerCookie,
    required LogCallback log,
    required Future<void> Function() checkPauseCallback,
    XClientTransactionService? xctService,
    required String apiRequestMode,
    String? cffiUrl,
    String? cffiApiKey,
    SyncProgressCallback? onProgress,
    Future<void> Function(DateTime resetAt)? waitForRateLimit,
  }) : _apiServiceGql = apiServiceGql,
       _accountRepository = accountRepository,
       _ownerId = ownerId,
       _ownerCookie = ownerCookie,
       _log = log,
       _checkPauseCallback = checkPauseCallback,
       _xctService = xctService,
       _apiRequestMode = apiRequestMode,
       _cffiUrl = cffiUrl,
       _cffiApiKey = cffiApiKey,
       _onProgress = onProgress,
       _waitForRateLimit = waitForRateLimit;

  Future<RelationshipAnalysisResult> analyze({
    required Map<String, FollowUser> oldRelationsMap,
    required NetworkFetchResult networkData,
  }) async {
    await _checkPauseCallback();

    final Set<String> newIds = networkData.uniqueUsers.keys.toSet();
    final Set<String> oldIds = oldRelationsMap.keys.toSet();
    final Set<String> addedIds = newIds.difference(oldIds);
    final Set<String> rawRemovedIds = oldIds.difference(newIds);
    final Set<String> keptIds = newIds.intersection(oldIds);
    final Set<String> realRemovedIds = {};

    var processedCount = 0;
    _onProgress?.call(
      SyncProgress(
        stage: SyncStage.analyzingChanges,
        step: SyncStep.checkingRemovedRelations,
        completedItems: 0,
        totalItems: rawRemovedIds.length,
      ),
    );
    for (final id in rawRemovedIds) {
      if (processedCount % 50 == 0) await _checkPauseCallback();
      final oldUser = oldRelationsMap[id];
      bool skip =
          (oldUser != null && !oldUser.isFollower && !oldUser.isFollowing);

      if (!skip && oldUser?.latestRawJson != null) {
        try {
          final Map<String, dynamic> jsonMap = jsonDecode(
            oldUser!.latestRawJson!,
          );
          final String? status = jsonMap['status'] as String?;
          if (status == 'suspended' || status == 'deactivated') skip = true;
        } catch (e) {
          _log("Error parsing JSON for user $id: $e");
          throw FormatException('Invalid stored JSON for user $id: $e');
        }
      }
      if (!skip) realRemovedIds.add(id);
      processedCount++;
      if (processedCount == rawRemovedIds.length || processedCount % 50 == 0) {
        _onProgress?.call(
          SyncProgress(
            stage: SyncStage.analyzingChanges,
            step: SyncStep.checkingRemovedRelations,
            completedItems: processedCount,
            totalItems: rawRemovedIds.length,
          ),
        );
      }
    }

    _log(
      "Differences: ${addedIds.length} added, ${realRemovedIds.length} removed, ${keptIds.length} kept.",
    );

    return _processRemovalsAndGenerateReports(
      oldRelationsMap,
      networkData,
      addedIds,
      realRemovedIds,
      keptIds,
      [],
    );
  }

  Future<T> _retryAfterRateLimit<T>(Future<T> Function() request) async {
    while (true) {
      try {
        return await request();
      } on GraphQlRateLimitException catch (error) {
        final resetAt = error.resetAt;
        if (resetAt == null || _waitForRateLimit == null) rethrow;
        _log('GQL rate limited. Waiting until $resetAt before retrying.');
        await _waitForRateLimit(resetAt);
      }
    }
  }

  /// Classifies a single `user_results.result` node.
  ///
  /// Returns one of [kStatusNormal], `suspended`, `deactivated`,
  /// `temporarily_restricted` or [kStatusLookupFailed].
  ///
  /// The important contract is that a *failed lookup* must never be reported as
  /// a relationship verdict. Older versions returned `other_reasons` for any
  /// unexpected payload, which silently turned every unfollow into "other
  /// reasons" as soon as X changed the shape of this response.
  String _classifyGqlUserResult(
    dynamic result, {
    bool missingMeansUnavailable = false,
  }) {
    if (result == null || (result is Map && result.isEmpty)) {
      // An aligned response without a node for the requested id is positive
      // evidence that the account is no longer retrievable.
      return missingMeansUnavailable ? 'deactivated' : kStatusLookupFailed;
    }
    if (result is! Map) {
      return kStatusLookupFailed;
    }

    final String? typename = result['__typename']?.toString();
    final String lowerMsg = (result['message']?.toString() ?? '').toLowerCase();
    final String lowerReason = (result['reason']?.toString() ?? '')
        .toLowerCase();

    // `__typename` is not guaranteed: some operations stopped requesting it.
    // Fall back to the presence of user fields instead of discarding the node.
    final bool looksLikeUser =
        result['rest_id'] != null ||
        result['legacy'] is Map ||
        result['core'] is Map;

    if (typename == 'User' || (typename == null && looksLikeUser)) {
      final legacy = result['legacy'];
      final interstitial = legacy is Map
          ? legacy['profile_interstitial_type']?.toString()
          : null;
      return (interstitial != null && interstitial.isNotEmpty)
          ? 'temporarily_restricted'
          : kStatusNormal;
    }

    if (typename == 'UserUnavailable') {
      if (lowerMsg.contains('suspend') || lowerReason.contains('suspend')) {
        return 'suspended';
      }
      if (lowerMsg.contains('deactivat') ||
          lowerReason.contains('deactivat') ||
          lowerReason.contains('offboard')) {
        return 'deactivated';
      }
      return 'suspended'; // 默认回退逻辑
    }

    return kStatusLookupFailed;
  }

  String _describeError(Object error) {
    final text = error.toString();
    return text.length > 400 ? '${text.substring(0, 400)}…' : text;
  }

  /// Resolves the current state of [ids] (users that disappeared from the
  /// fetched follower/following sets).
  ///
  /// Strategy, in order:
  ///  1. `UsersByRestIds` (batch). Ids are unambiguous, so this is preferred —
  ///     but X has been rejecting this operation since 2026-09.
  ///  2. `UsersByScreenNames` (batch, using the stored screen name). This is the
  ///     same operation the profile-enrichment stage uses every sync.
  ///  3. `UserByRestId` one user at a time. A different operation from the batch
  ///     one, and still working (the owner-profile refresh uses it).
  ///
  /// Anything still unresolved is reported as [kStatusLookupFailed]; callers
  /// must treat that as "unknown" and never as a relationship verdict.
  Future<Map<String, String>> _categorizeRemovals(
    Set<String> ids, {
    Map<String, FollowUser>? oldRelationsMap,
  }) async {
    final Map<String, String> results = {};
    if (ids.isEmpty) return results;

    final Set<String> unresolved = {...ids};

    await _lookupStatusesByRestIds(unresolved, results);
    unresolved.removeWhere(results.containsKey);

    if (unresolved.isNotEmpty) {
      await _lookupStatusesByScreenNames(unresolved, results, oldRelationsMap);
      unresolved.removeWhere(results.containsKey);
    }

    // 逐条兜底：`UserByRestId` 与批量接口是两套 operation，批量那套被 X 改动
    // 之后单条仍然可用（账号资料刷新每次同步都在用它）。
    if (unresolved.isNotEmpty) {
      await _lookupStatusesBySingleRestId(unresolved, results);
      unresolved.removeWhere(results.containsKey);
    }

    if (unresolved.isNotEmpty) {
      _log(
        'Status lookup failed for ${unresolved.length} of ${ids.length} users; '
        'falling back to relationship flags for those users.',
      );
      for (final id in unresolved) {
        results[id] = kStatusLookupFailed;
      }
    }
    return results;
  }

  Future<void> _lookupStatusesByRestIds(
    Set<String> ids,
    Map<String, String> results,
  ) async {
    final String queryId = _accountRepository.getCurrentQueryId(
      'UsersByRestIds',
    );
    final featureSwitches = _accountRepository.getFeatureSwitches(
      'UsersByRestIds',
    );
    final fieldToggles = _accountRepository.getFieldToggles('UsersByRestIds');
    final List<String> idList = ids.toList();
    const int batchSize = 100;

    for (int start = 0; start < idList.length; start += batchSize) {
      await _checkPauseCallback();
      final int end = min(start + batchSize, idList.length);
      final List<String> chunk = idList.sublist(start, end);
      try {
        final transactionId = _xctService?.generateTransactionId(
          method: "GET",
          url: 'https://api.x.com/graphql/$queryId/UsersByRestIds',
        );
        final Map<String, dynamic> gqlJson = await _retryAfterRateLimit(
          () => _apiServiceGql.getUsersByRestIds(
            chunk,
            _ownerCookie,
            queryId,
            transactionId,
            extraFeatureSwitches: featureSwitches,
            extraFieldToggles: fieldToggles,
            apiRequestMode: _apiRequestMode,
            cffiUrl: _cffiUrl,
            cffiApiKey: _cffiApiKey,
          ),
        );

        final dynamic usersData = gqlJson['data']?['users'];
        if (usersData is! List) {
          _log(
            'UsersByRestIds returned no data.users for ${chunk.length} ids '
            '(top-level keys: ${gqlJson.keys.join(", ")}). '
            'Retrying these users by screen name.',
          );
          continue;
        }

        // Positional alignment is only meaningful when the server returned one
        // node per requested id.
        final bool aligned = usersData.length == chunk.length;
        final Map<String, dynamic> byRestId = {};
        for (final entry in usersData) {
          final dynamic result = entry is Map ? entry['result'] : null;
          if (result is Map) {
            final restId = result['rest_id']?.toString();
            if (restId != null && restId.isNotEmpty) byRestId[restId] = result;
          }
        }

        for (int i = 0; i < chunk.length; i++) {
          final String currentId = chunk[i];
          dynamic result = byRestId[currentId];
          if (result == null && aligned) {
            final entry = usersData[i];
            result = entry is Map ? entry['result'] : null;
          }
          final status = _classifyGqlUserResult(
            result,
            missingMeansUnavailable: aligned,
          );
          if (status != kStatusLookupFailed) results[currentId] = status;
        }
      } catch (e) {
        _log(
          'UsersByRestIds failed for batch $start..${end - 1}: '
          '${_describeError(e)}',
        );
      }
    }
  }

  /// 逐条查询单个用户的当前状态。
  ///
  /// 批量接口 `UsersByRestIds` 被 X 改动后一直失败，而单条 `UserByRestId` 仍然
  /// 可用，因此这里作为最后的精确兜底。数量有上限，避免一次积压几百人时把
  /// 请求量放大到触发限流。
  Future<void> _lookupStatusesBySingleRestId(
    Set<String> ids,
    Map<String, String> results,
  ) async {
    final String queryId = _accountRepository.getCurrentQueryId('UserByRestId');
    final featureSwitches = _accountRepository.getFeatureSwitches(
      'UserByRestId',
    );
    final fieldToggles = _accountRepository.getFieldToggles('UserByRestId');
    var processed = 0;

    for (final id in ids) {
      if (processed >= _maxSingleStatusLookups) {
        _log(
          'Status lookup stopped after $_maxSingleStatusLookups single-user '
          'requests; ${ids.length - processed} users fall back to their '
          'relationship flags.',
        );
        break;
      }
      await _checkPauseCallback();
      processed++;
      try {
        final transactionId = _xctService?.generateTransactionId(
          method: "GET",
          url: 'https://api.x.com/graphql/$queryId/UserByRestId',
        );
        final Map<String, dynamic> gqlJson = await _retryAfterRateLimit(
          () => _apiServiceGql.getUserByRestId(
            id,
            _ownerCookie,
            queryId,
            transactionId: transactionId,
            extraFeatureSwitches: featureSwitches,
            extraFieldToggles: fieldToggles,
            apiRequestMode: _apiRequestMode,
            cffiUrl: _cffiUrl,
            cffiApiKey: _cffiApiKey,
          ),
        );
        final dynamic userNode = gqlJson['data']?['user'];
        if (userNode == null || (userNode is Map && userNode.isEmpty)) {
          results[id] = 'deactivated';
          continue;
        }
        final status = _classifyGqlUserResult(
          userNode is Map ? userNode['result'] : null,
          missingMeansUnavailable: true,
        );
        if (status != kStatusLookupFailed) results[id] = status;
      } catch (e) {
        _log('UserByRestId failed for $id: ${_describeError(e)}');
      }
    }
  }

  Future<void> _lookupStatusesByScreenNames(
    Set<String> ids,
    Map<String, String> results,
    Map<String, FollowUser>? oldRelationsMap,
  ) async {
    final Map<String, String> idByName = {};
    for (final id in ids) {
      final String? name = oldRelationsMap?[id]?.screenName
          ?.trim()
          .toLowerCase();
      if (name != null && name.isNotEmpty) idByName.putIfAbsent(name, () => id);
    }
    if (idByName.isEmpty) return;

    final String queryId = _accountRepository.getCurrentQueryId(
      'UsersByScreenNames',
    );
    final featureSwitches = _accountRepository.getFeatureSwitches(
      'UsersByScreenNames',
    );
    final fieldToggles = _accountRepository.getFieldToggles(
      'UsersByScreenNames',
    );
    final List<String> names = idByName.keys.toList();
    const int batchSize = 100;

    for (int start = 0; start < names.length; start += batchSize) {
      await _checkPauseCallback();
      final int end = min(start + batchSize, names.length);
      final List<String> chunk = names.sublist(start, end);
      try {
        final transactionId = _xctService?.generateTransactionId(
          method: "GET",
          url: 'https://api.x.com/graphql/$queryId/UsersByScreenNames',
        );
        final Map<String, dynamic> gqlJson = await _retryAfterRateLimit(
          () => _apiServiceGql.getUsersByScreenNames(
            chunk,
            _ownerCookie,
            queryId,
            transactionId,
            extraFeatureSwitches: featureSwitches,
            extraFieldToggles: fieldToggles,
            apiRequestMode: _apiRequestMode,
            cffiUrl: _cffiUrl,
            cffiApiKey: _cffiApiKey,
          ),
        );

        final dynamic usersData = gqlJson['data']?['users'];
        if (usersData is! List) {
          _log(
            'UsersByScreenNames returned no data.users for ${chunk.length} '
            'names; leaving them unresolved.',
          );
          continue;
        }

        final bool aligned = usersData.length == chunk.length;
        for (int i = 0; i < usersData.length; i++) {
          final entry = usersData[i];
          final dynamic result = entry is Map ? entry['result'] : null;
          String? id;
          String? name;
          if (result is Map) {
            final restId = result['rest_id']?.toString();
            if (restId != null && restId.isNotEmpty && ids.contains(restId)) {
              id = restId;
            }
            final legacy = result['legacy'];
            final core = result['core'];
            name =
                (legacy is Map ? legacy['screen_name']?.toString() : null) ??
                (core is Map ? core['screen_name']?.toString() : null);
          }
          id ??= idByName[name?.trim().toLowerCase()];
          if (id == null && aligned) {
            id = idByName[chunk[i]];
          }
          if (id == null) continue;
          final status = _classifyGqlUserResult(result);
          if (status != kStatusLookupFailed) results[id] = status;
        }
      } catch (e) {
        _log(
          'UsersByScreenNames failed for batch $start..${end - 1}: '
          '${_describeError(e)}',
        );
      }
    }
  }

  String _resolveRemovalCategory(
    String? apiStatus,
    FollowUser? oldRelation,
  ) => classifyRemovedRelationshipChange(
    apiStatus: apiStatus,
    wasFollower: oldRelation?.isFollower ?? false,
    wasFollowing: oldRelation?.isFollowing ?? false,
  );

  Future<RelationshipAnalysisResult> _processRemovalsAndGenerateReports(
    Map<String, FollowUser> oldRelationsMap,
    NetworkFetchResult networkData,
    Set<String> addedIds,
    Set<String> removedIds,
    Set<String> keptIds,
    List<FollowUsersHistoryCompanion> historyToInsert,
  ) async {
    final List<ChangeReportsCompanion> reportCompanions = [];
    final now = DateTime.now();

    final removalStatuses = await _categorizeRemovals(
      removedIds,
      oldRelationsMap: oldRelationsMap,
    );
    final Map<String, String> categorizedRemovals = {
      for (final id in removedIds)
        id: _resolveRemovalCategory(removalStatuses[id], oldRelationsMap[id]),
    };

    final Set<String> potentialRestrictedIds = {};
    var loopCounter = 0;
    final comparisonTotal = keptIds.length * 2;
    _onProgress?.call(
      SyncProgress(
        stage: SyncStage.analyzingChanges,
        step: SyncStep.comparingProfiles,
        completedItems: 0,
        totalItems: comparisonTotal,
      ),
    );
    for (final keptId in keptIds) {
      if (loopCounter % 100 == 0) await _checkPauseCallback();

      final oldRel = oldRelationsMap[keptId];
      final newUser = networkData.uniqueUsers[keptId]!;
      final wasFollower = oldRel?.isFollower ?? false;
      final isNowFollower = networkData.followerIds.contains(keptId);

      if (oldRel?.latestRawJson != null) {
        try {
          final oldUser = TwitterUser.fromJson(
            jsonDecode(oldRel!.latestRawJson!),
          );
          final Map<String, Map<String, String?>> diffs = {};

          // 修复：处理 null 与空字符串的等价性比较
          void check(String f, String? o, String? n) {
            final oldTrimmed = o?.trim() ?? '';
            final newTrimmed = n?.trim() ?? '';
            if (oldTrimmed != newTrimmed) {
              diffs[f] = {'old': o?.trim(), 'new': n?.trim()};
            }
          }

          check('name', oldUser.name, newUser.name);
          check('screen_name', oldUser.screenName, newUser.screenName);
          check('bio', oldUser.bio, newUser.bio);
          check('location', oldUser.location, newUser.location);
          check('link', oldUser.link, newUser.link);

          if ((oldUser.avatarUrl ?? '') != (newUser.avatarUrl ?? '')) {
            diffs['avatar'] = {
              'old': oldUser.avatarUrl,
              'new': newUser.avatarUrl,
            };
          }
          if ((oldUser.bannerUrl ?? '') != (newUser.bannerUrl ?? '')) {
            diffs['banner'] = {
              'old': oldUser.bannerUrl,
              'new': newUser.bannerUrl,
            };
          }

          if (diffs.isNotEmpty) {
            reportCompanions.add(
              ChangeReportsCompanion(
                ownerId: Value(_ownerId),
                userId: Value(keptId),
                changeType: Value(kChangeTypeProfileUpdate),
                timestamp: Value(now),
                userSnapshotJson: Value(
                  jsonEncode({'diff': diffs, 'user': newUser.toJson()}),
                ),
              ),
            );
          }
        } catch (e) {
          _log("Profile compare error $keptId: $e");
          throw FormatException('Invalid stored JSON for user $keptId: $e');
        }
      }

      if (wasFollower &&
          !isNowFollower &&
          newUser.followingCount == 0 &&
          newUser.followersCount > 0) {
        potentialRestrictedIds.add(keptId);
      }
      loopCounter++;
      if (loopCounter == keptIds.length || loopCounter % 100 == 0) {
        _onProgress?.call(
          SyncProgress(
            stage: SyncStage.analyzingChanges,
            step: SyncStep.comparingProfiles,
            completedItems: loopCounter,
            totalItems: comparisonTotal,
          ),
        );
      }
    }

    final restrictedChecks = await _categorizeRemovals(
      potentialRestrictedIds,
      oldRelationsMap: oldRelationsMap,
    );

    for (final id in addedIds) {
      reportCompanions.add(
        ChangeReportsCompanion(
          ownerId: Value(_ownerId),
          userId: Value(id),
          changeType: Value('new_followers_following'),
          timestamp: Value(now),
          userSnapshotJson: Value(
            jsonEncode(networkData.uniqueUsers[id]!.toJson()),
          ),
        ),
      );
    }

    categorizedRemovals.forEach((uid, cat) {
      reportCompanions.add(
        ChangeReportsCompanion(
          ownerId: Value(_ownerId),
          userId: Value(uid),
          changeType: Value(cat),
          timestamp: Value(now),
          userSnapshotJson: const Value(null),
        ),
      );
    });

    final Map<String, String> keptStatusUpdates = {};
    var statusLoopCounter = 0;
    for (final keptId in keptIds) {
      final oldRel = oldRelationsMap[keptId];
      final wasFollower = oldRel?.isFollower ?? false;
      final wasFollowing = oldRel?.isFollowing ?? false;
      final isNowFollower = networkData.followerIds.contains(keptId);
      final isNowFollowing = networkData.followingIds.contains(keptId);

      String oldStatus = 'normal';
      String oldKeptStatus = 'normal';
      if (oldRel?.latestRawJson != null) {
        try {
          final Map<String, dynamic> j = jsonDecode(oldRel!.latestRawJson!);
          oldStatus = j['status'] ?? 'normal';
          oldKeptStatus = j['kept_ids_status'] ?? 'normal';
        } catch (e) {
          _log('Error parsing JSON for user $keptId: $e');
          throw FormatException('Invalid stored JSON for user $keptId: $e');
        }
      }
      // A kept user is present in the freshly fetched lists, so "normal" is the
      // correct default. Users that were explicitly re-checked keep the verdict
      // of that lookup; an inconclusive lookup stays unknown and therefore can
      // never be reported as a recovery.
      final String currentStatus = restrictedChecks[keptId] ?? kStatusNormal;
      final changeType = classifyKeptRelationshipChange(
        wasFollower: wasFollower,
        wasFollowing: wasFollowing,
        isNowFollower: isNowFollower,
        isNowFollowing: isNowFollowing,
        oldStatus: oldStatus,
        oldKeptStatus: oldKeptStatus,
        currentStatus: currentStatus,
      );

      if (changeType != null) {
        reportCompanions.add(
          ChangeReportsCompanion(
            ownerId: Value(_ownerId),
            userId: Value(keptId),
            changeType: Value(changeType),
            timestamp: Value(now),
            userSnapshotJson: const Value(null),
          ),
        );
        if (changeType != 'be_followed_back' &&
            changeType != 'new_followers_following') {
          keptStatusUpdates[keptId] = changeType;
        }
      }
      statusLoopCounter++;
      if (statusLoopCounter == keptIds.length || statusLoopCounter % 100 == 0) {
        _onProgress?.call(
          SyncProgress(
            stage: SyncStage.analyzingChanges,
            step: SyncStep.comparingProfiles,
            completedItems: keptIds.length + statusLoopCounter,
            totalItems: comparisonTotal,
          ),
        );
      }
    }

    return RelationshipAnalysisResult(
      addedIds: addedIds,
      removedIds: removedIds,
      keptIds: keptIds,
      reports: reportCompanions,
      categorizedRemovals: categorizedRemovals,
      keptUserStatusUpdates: keptStatusUpdates,
      historyToInsert: historyToInsert,
    );
  }
}
