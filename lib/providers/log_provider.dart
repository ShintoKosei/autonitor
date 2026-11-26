import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/log_file_service.dart';

// --- 1. The Notifier to hold the log history ---
class LogHistoryNotifier extends StateNotifier<List<String>> {
  /// 界面最多回看的行数。完整日志另存于 [LogFileService]，不受此限制。
  static const _maxLogLines = 2000;
  LogHistoryNotifier() : super([]);

  void addLog(String logEntry) {
    // 先落盘：即使这条日志随后被环形缓冲挤出，导出时依然完整。
    LogFileService.instance.add(logEntry);
    Future(() {
      if (!mounted) return;

      final newState = [...state, logEntry];
      if (newState.length > _maxLogLines) {
        state = newState.sublist(newState.length - _maxLogLines);
      } else {
        state = newState;
      }
    });
  }

  void clearLog() {
    state = [];
  }
}

// --- 2. MODIFICATION: Create a global instance ---
// (修改：创建一个全局实例)
final globalLogHistoryNotifier = LogHistoryNotifier();
// --- END MODIFICATION ---

// --- 3. The Provider for the Notifier ---
final logHistoryNotifierProvider =
    StateNotifierProvider<LogHistoryNotifier, List<String>>((ref) {
      // (Provide the global instance)
      // (提供这个全局实例)
      return globalLogHistoryNotifier;
    });

// --- 4. A simple Provider for just the List<String> ---
final logHistoryProvider = Provider<List<String>>((ref) {
  return ref.watch(logHistoryNotifierProvider);
});
