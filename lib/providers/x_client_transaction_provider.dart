import 'package:autonitor/services/log_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/x_client_transaction_service.dart';

// 提供 XClientGenerator 实例
final xClientGeneratorProvider = Provider<XClientGenerator>((ref) {
  return XClientGenerator();
});

/// 抓取一次并缓存 bootstrap 服务。
///
/// 注意：FutureProvider 的失败结果会被 ProviderContainer 缓存到进程结束，
/// 以前每次同步都会在 0ms 内拿到同一个错误、根本不会重新请求网络。
/// 现在 [TransactionIdNotifier] 在失败时主动 invalidate，下一次同步才能真正重试。
final xctServiceProvider = FutureProvider<XClientTransactionService>((
  ref,
) async {
  final generator = ref.read(xClientGeneratorProvider);
  logger.i(
    "[xctServiceProvider] Fetching new XClientTransactionService instance...",
  );
  return await generator.fetchService();
});

class TransactionIdNotifier extends Notifier<AsyncValue<String?>> {
  XClientTransactionService? _service;
  DateTime? _lastFailureAt;
  bool _warnedUnavailable = false;

  /// 失败冷却：bootstrap 挂掉时不要给每个 GQL 请求都加一次网络往返。
  static const _retryCooldown = Duration(minutes: 10);

  @override
  AsyncValue<String?> build() {
    return const AsyncData(null);
  }

  /// 设置 bootstrap 抓取用的 Cookie。请在 [init] 之前调用。
  void updateCookie(String? cookie) {
    ref.read(xClientGeneratorProvider).updateCookieHeader(cookie);
  }

  /// 初始化，只执行一次。
  ///
  /// 失败不是致命问题：本应用用到的端点目前接受缺失的
  /// X-Client-Transaction-Id 头，请求会继续。
  Future<void> init({bool force = false}) async {
    if (_service != null) return; // 已经初始化，不重复

    final lastFailure = _lastFailureAt;
    if (!force &&
        lastFailure != null &&
        DateTime.now().difference(lastFailure) < _retryCooldown) {
      throw StateError(
        'X transaction ID unavailable; retry cooldown until '
        '${lastFailure.add(_retryCooldown)}.',
      );
    }

    state = const AsyncLoading();

    try {
      // --- MODIFICATION: Read from the new FutureProvider ---
      logger.i("[TransactionIdNotifier] init() awaiting xctServiceProvider...");
      _service = await ref.read(
        xctServiceProvider.future,
      ); // Awaits the cached service
      _lastFailureAt = null;
      _warnedUnavailable = false;
      logger.i("[TransactionIdNotifier] init() successfully got service.");

      state = const AsyncData(null);
    } catch (e, s) {
      _lastFailureAt = DateTime.now();
      // 丢掉缓存的失败结果，否则后续同步会永远复用它（曾经导致 0ms 秒失败）。
      ref.invalidate(xctServiceProvider);
      state = AsyncError("Failed to init XClient: $e", s);
      rethrow; // This rethrow is CRITICAL
    }
  }

  /// 按需生成 ID。X 的网页引导资源会变化，无法生成时允许请求继续。
  Future<String?> generate({
    required String method,
    required String url,
  }) async {
    if (_service == null) {
      try {
        await init();
      } catch (e, s) {
        // 每次请求都打一条 warning 会把日志刷爆（一次同步 40+ 条），只报一次。
        if (!_warnedUnavailable) {
          _warnedUnavailable = true;
          logger.w(
            'X transaction ID unavailable; continuing without it: $e',
            error: e,
            stackTrace: s,
          );
        }
        return null;
      }
    }

    try {
      // generateTransactionId from the service is synchronous.
      final id = _service!.generateTransactionId(method: method, url: url);
      state = AsyncData(id);

      logger.i('[XCT] Generated id: $id');
      return id; // The async keyword will wrap this in a Future.
    } catch (e, s) {
      logger.w(
        'Failed to generate transaction ID; continuing without it: $e',
        error: e,
        stackTrace: s,
      );
      return null;
    }
  }
}

// --- MODIFICATION: Changed to NotifierProvider (non-autoDispose) ---
final transactionIdProvider =
    NotifierProvider<TransactionIdNotifier, AsyncValue<String?>>(
      TransactionIdNotifier.new,
    );
