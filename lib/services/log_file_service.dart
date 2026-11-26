import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 把日志持久化到磁盘，供"导出日志"使用。
///
/// 内存里的日志历史是固定长度的环形缓冲，长时间同步会覆盖掉早期的行；这里
/// 把每一条都追加进文件，导出时就能拿到完整记录。
///
/// 设计要点：
///  * 不用 Timer：避免 widget 测试结束时报 "A Timer is still pending"。
///  * 单条写队列串行刷盘，写入期间的日志会自动合并成一次 append。
///  * IO 连续失败后停用该 sink，绝不影响正常业务流程。
class LogFileService {
  LogFileService._();

  static final LogFileService instance = LogFileService._();

  /// 单个日志文件的上限，超过后在下次打开时轮转成 `.1`。
  static const int _maxBytes = 4 * 1024 * 1024;

  final List<String> _queue = [];
  Future<void>? _drainFuture;
  RandomAccessFile? _handle;
  File? _file;
  bool _disabled = false;
  int _openFailures = 0;

  /// 连续失败多少次后彻底停用。留一点容错，避免启动早期插件尚未就绪时
  /// 永久关掉日志。
  static const int _maxOpenFailures = 3;

  /// 日志文件的绝对路径，未初始化或已停用时为 null。
  String? get filePath => _file?.path;

  /// 追加一行日志（同步入队，落盘异步完成）。
  void add(String line) {
    if (_disabled) return;
    _queue.add(line);
    _drainFuture ??= _drain().whenComplete(() => _drainFuture = null);
  }

  /// 等待队列全部落盘。
  Future<void> flush() async {
    var pending = _drainFuture;
    while (pending != null) {
      await pending;
      pending = _drainFuture;
    }
  }

  /// 读取完整日志内容；文件尚不存在时返回空串。
  Future<String> readAll() async {
    await flush();
    final file = _file;
    if (file == null) return '';
    try {
      if (!await file.exists()) return '';
      return await file.readAsString();
    } catch (_) {
      return '';
    }
  }

  /// 清空队列和日志文件。
  Future<void> clear() async {
    // 先等正在进行的写入结束，否则关闭句柄会让那次写入抛错并停用 sink。
    await flush();
    _queue.clear();
    final handle = _handle;
    _handle = null;
    try {
      await handle?.close();
    } catch (_) {
      // 关闭失败不影响后续重建。
    }
    final file = _file;
    _file = null;
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删除失败时保留文件，下次写入会继续追加。
    }
  }

  Future<void> _drain() async {
    try {
      while (_queue.isNotEmpty) {
        // 取出当前全部待写行；写盘期间新到的日志留到下一轮，自然合并。
        final chunk = '${_queue.join('\n')}\n';
        _queue.clear();
        final handle = await _openHandle();
        if (handle == null) return;
        await handle.writeString(chunk);
      }
    } catch (_) {
      _disabled = true;
      _queue.clear();
    }
  }

  Future<RandomAccessFile?> _openHandle() async {
    final existing = _handle;
    if (existing != null) return existing;
    if (_disabled) return null;
    try {
      final supportDirectory = await getApplicationSupportDirectory();
      final logDirectory = Directory(p.join(supportDirectory.path, 'logs'));
      if (!await logDirectory.exists()) {
        await logDirectory.create(recursive: true);
      }
      var file = File(p.join(logDirectory.path, 'autonitor.log'));

      // 启动后第一次写入时做一次轮转，保留上一份文件用于对比。
      if (await file.exists() && await file.length() > _maxBytes) {
        final previous = File(p.join(logDirectory.path, 'autonitor.log.1'));
        if (await previous.exists()) await previous.delete();
        await file.rename(previous.path);
        file = File(p.join(logDirectory.path, 'autonitor.log'));
      }

      _file = file;
      _handle = await file.open(mode: FileMode.append);
      _openFailures = 0;
      return _handle;
    } catch (_) {
      // path_provider 在单元测试里不可用，连续失败后静默停用即可。
      _openFailures++;
      if (_openFailures >= _maxOpenFailures) _disabled = true;
      return null;
    }
  }
}
