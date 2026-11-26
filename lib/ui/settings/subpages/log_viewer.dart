part of '../settings_page.dart';

class LogViewerPage extends ConsumerWidget {
  const LogViewerPage({super.key});

  /// 与备份导出复用同一个原生通道：先写临时文件，再由 Android 流式写入用户
  /// 选定的 URI。大文件不必经平台通道整体传输。
  static const MethodChannel _fileChannel = MethodChannel(
    'app.autonitor/backup_file',
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final logs = ref.watch(logHistoryProvider);
    final logText = logs.join('\n');

    return Scaffold(
      appBar: AppBar(title: Text(l10n.view_log)),
      body: Column(
        children: [
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
              ),
              child: logs.isEmpty
                  ? Center(
                      child: Icon(
                        Icons.article_outlined,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    )
                  : Scrollbar(
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: logs.length,
                        separatorBuilder: (context, index) => Divider(
                          height: 1,
                          color: colorScheme.outlineVariant,
                        ),
                        itemBuilder: (context, index) => Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 9,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 34,
                                child: Text(
                                  '${index + 1}',
                                  textAlign: TextAlign.right,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: SelectableText(
                                  logs[index],
                                  style: TextStyle(
                                    fontSize: 11,
                                    height: 1.35,
                                    fontFamily: 'monospace',
                                    color: colorScheme.onSurface,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Wrap(
              spacing: 4,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.save_alt),
                  label: Text(l10n.export_log),
                  onPressed: () => _exportLogs(context, logs),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.copy),
                  label: Text(l10n.copy),
                  onPressed: () => _copyLogs(context, logText),
                ),
                TextButton(
                  child: Text(l10n.clear),
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    ref.read(logHistoryNotifierProvider.notifier).clearLog();
                    await LogFileService.instance.clear();
                    navigator.pop();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 复制当前可见的日志。
  ///
  /// 剪贴板通过 Binder 传递，几 MB 的文本会直接失败，所以这里只复制界面里的
  /// 那部分；需要完整记录时用导出。
  Future<void> _copyLogs(BuildContext context, String logText) async {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await Clipboard.setData(ClipboardData(text: logText));
      _showToast(messenger, l10n.copied_to_clipboard, colorScheme);
    } catch (error) {
      _showToast(
        messenger,
        l10n.log_export_failed('$error'),
        colorScheme,
        isError: true,
      );
    }
    navigator.pop();
  }

  Future<void> _exportLogs(BuildContext context, List<String> buffer) async {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final messenger = ScaffoldMessenger.of(context);

    String text;
    try {
      text = await LogFileService.instance.readAll();
    } catch (_) {
      text = '';
    }
    // 文件不可用（例如刚清空过）时退回界面缓冲，至少能导出看到的内容。
    if (text.trim().isEmpty) text = buffer.join('\n');
    if (text.trim().isEmpty) {
      _showToast(messenger, l10n.log_export_empty, colorScheme);
      return;
    }

    final fileName = 'autonitor_log_${_timestampForFileName()}.log';
    try {
      final saved = await _saveLogFile(fileName, text);
      if (saved == null) return; // 用户取消了系统文件选择器
      _showToast(messenger, l10n.log_exported, colorScheme);
    } catch (error) {
      _showToast(
        messenger,
        l10n.log_export_failed('$error'),
        colorScheme,
        isError: true,
      );
    }
  }

  Future<String?> _saveLogFile(String fileName, String text) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    if (!Platform.isAndroid) {
      return FilePicker.platform.saveFile(
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['log'],
        bytes: bytes,
      );
    }

    // Android 上先落到临时文件，再让原生侧按 URI 流式复制，
    // 避免把整份日志塞进平台通道。
    final tempDirectory = await Directory.systemTemp.createTemp(
      'autonitor_log_export_',
    );
    final sourceFile = File(p.join(tempDirectory.path, fileName));
    try {
      await sourceFile.writeAsBytes(bytes, flush: true);
      return await _fileChannel.invokeMethod<String>('savePreparedFile', {
        'sourcePath': sourceFile.path,
        'fileName': fileName,
        'mimeType': 'text/plain',
      });
    } finally {
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    }
  }

  String _timestampForFileName() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}'
        '_${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  void _showToast(
    ScaffoldMessengerState messenger,
    String message,
    ColorScheme colorScheme, {
    bool isError = false,
  }) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(
            color: isError
                ? colorScheme.onErrorContainer
                : colorScheme.onPrimaryContainer,
          ),
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: isError
            ? colorScheme.errorContainer
            : colorScheme.primaryContainer,
      ),
    );
  }
}
