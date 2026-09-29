import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/session/file_backend.dart';
import '../../core/session/file_browser_session.dart';
import '../../core/session/session_backend.dart';
import '../../core/session/session_log.dart';
import '../../core/session/session_manager.dart';
import '../../data/host_profile.dart';
import '../pad/pad_breakpoints.dart';
import 'local_fs_listing.dart';

/// Dual-pane local + remote file browser (SFTP / FTP).
///
/// Wide (≥600dp): left local, right remote. Narrow: remote-only with
/// upload picker still available (toggle local sheet).
class FilesPage extends ConsumerStatefulWidget {
  const FilesPage({super.key, this.sessionId, this.embedded = false});

  final String? sessionId;
  final bool embedded;

  @override
  ConsumerState<FilesPage> createState() => _FilesPageState();
}

typedef _LocalEntry = LocalFsEntry;

class _FilesPageState extends ConsumerState<FilesPage> {
  List<RemoteFileEntry> _remote = [];
  List<_LocalEntry> _local = [];
  bool _loadingRemote = true;
  bool _loadingLocal = true;
  String? _remoteError;
  String? _localError;
  bool _busy = false;
  String _localPath = '';
  bool _showLocalNarrow = false;

  FileBrowserSession? get _session {
    final mgr = ref.read(sessionManagerProvider);
    final id = widget.sessionId ?? mgr.activeFileId;
    if (id == null) return mgr.activeFile;
    for (final s in mgr.files) {
      if (s.id == id) return s;
    }
    return mgr.activeFile;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initLocalRoot();
      await Future.wait([_reloadRemote(), _reloadLocal()]);
    });
  }

  Future<void> _initLocalRoot() async {
    try {
      Directory? base;
      try {
        base = await getDownloadsDirectory();
      } catch (_) {}
      base ??= await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/SSHPad');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      if (mounted) setState(() => _localPath = dir.path);
    } catch (e) {
      if (mounted) {
        setState(() {
          _localError = e.toString();
          _loadingLocal = false;
        });
      }
    }
  }

  Future<void> _reloadRemote() async {
    final session = _session;
    if (session == null) {
      setState(() {
        _loadingRemote = false;
        _remoteError = '无文件会话';
      });
      return;
    }
    if (session.phase == SessionPhase.connecting) {
      setState(() {
        _loadingRemote = true;
        _remoteError = null;
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (session.phase == SessionPhase.error) {
      setState(() {
        _loadingRemote = false;
        _remoteError = session.errorMessage ?? '连接失败';
      });
      return;
    }
    setState(() {
      _loadingRemote = true;
      _remoteError = null;
    });
    try {
      final list = await session.backend.list();
      if (!mounted) return;
      setState(() {
        _remote = list;
        _loadingRemote = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _remoteError = e.toString();
        _loadingRemote = false;
      });
      sessionLog.add('Remote list failed: $e', level: SessionLogLevel.error);
    }
  }

  Future<void> _reloadLocal() async {
    if (_localPath.isEmpty) return;
    setState(() {
      _loadingLocal = true;
      _localError = null;
    });
    try {
      final entries = await listLocalDirectory(_localPath);
      if (!mounted) return;
      setState(() {
        _local = entries;
        _loadingLocal = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _localError = e.toString();
        _loadingLocal = false;
      });
    }
  }

  Future<void> _pickLocalFolder() async {
    if (Platform.isAndroid) {
      final ok = await _ensureLocalStorageAccess();
      if (!ok && mounted) {
        _snack('若本地文件不显示，请使用应用 SSHPad 目录，或系统选取上传');
      }
    }
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return;
    setState(() => _localPath = path);
    await _reloadLocal();
    if (!mounted) return;
    // After listing: if we only see directories and zero files under a
    // non-app path, remind about scoped storage (API 33+).
    final files = _local.where((e) => !e.isDirectory).length;
    final dirs = _local.where((e) => e.isDirectory).length;
    if (Platform.isAndroid &&
        files == 0 &&
        dirs > 0 &&
        !_localPath.contains('${Platform.pathSeparator}SSHPad')) {
      _snack('当前文件夹可能受系统权限限制：请用应用内 SSHPad 目录，或点上传用系统选取器');
    }
  }

  /// Best-effort READ_EXTERNAL_STORAGE on API ≤32. On 33+ returns true
  /// (scoped storage; app SSHPad dir / SAF picker remain the reliable paths).
  Future<bool> _ensureLocalStorageAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      const ch = MethodChannel('com.sshtab.ssh_pad_flutter/storage');
      final v = await ch.invokeMethod<bool>('requestReadStorage');
      return v ?? true;
    } on MissingPluginException {
      return true;
    } catch (_) {
      return true;
    }
  }

  Future<void> _mkdirRemote() async {
    final name = await _prompt('新建远程文件夹', '名称');
    if (name == null || name.isEmpty) return;
    await _run(() => _session!.backend.mkdir(name));
  }

  Future<void> _uploadPicked() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;
    final f = result.files.single;
    final bytes = f.bytes;
    if (bytes == null) {
      _snack('无法读取所选文件');
      return;
    }
    await _run(() async {
      await _session!.backend.upload(f.name, bytes);
      sessionLog.add('Uploaded ${f.name}');
    });
  }

  Future<void> _uploadLocal(_LocalEntry entry) async {
    if (entry.isDirectory) {
      _snack('暂不支持上传整个目录');
      return;
    }
    await _run(() async {
      final bytes = await File(entry.path).readAsBytes();
      await _session!.backend.upload(entry.name, bytes);
      sessionLog.add('Uploaded ${entry.name} → remote');
    });
  }

  Future<void> _downloadToLocal(RemoteFileEntry entry) async {
    if (entry.isDirectory) {
      _snack('暂不支持下载整个目录');
      return;
    }
    await _run(() async {
      final bytes = await _session!.backend.download(entry.name);
      final out = File('$_localPath/${entry.name}');
      await out.writeAsBytes(bytes, flush: true);
      sessionLog.add('Downloaded ${entry.name} → ${out.path}');
      if (mounted) _snack('已保存到 ${out.path}');
      await _reloadLocal();
    });
  }

  Future<void> _deleteRemote(RemoteFileEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除'),
        content: Text('确定删除远程 ${entry.name}？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => _session!.backend.delete(entry));
  }

  Future<void> _openRemoteDir(RemoteFileEntry entry) async {
    await _run(() => _session!.backend.changeDirectory(entry.name));
  }

  Future<void> _goUpRemote() async {
    await _run(() => _session!.backend.changeDirectory('..'));
  }

  Future<void> _openLocalDir(_LocalEntry entry) async {
    setState(() => _localPath = entry.path);
    await _reloadLocal();
  }

  Future<void> _goUpLocal() async {
    final parent = Directory(_localPath).parent.path;
    if (parent.isEmpty || parent == _localPath) return;
    setState(() => _localPath = parent);
    await _reloadLocal();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || _session == null) return;
    setState(() => _busy = true);
    try {
      await action();
      await _reloadRemote();
    } catch (e) {
      sessionLog.add('File op failed: $e', level: SessionLogLevel.error);
      if (mounted) _snack('操作失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _prompt(String title, String label) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          decoration: InputDecoration(labelText: label),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _close() async {
    final s = _session;
    if (s != null) {
      await ref.read(sessionManagerProvider).closeFile(s.id);
    }
    if (mounted && !widget.embedded) {
      Navigator.of(context).maybePop();
    }
  }

  String _formatSize(int? size) {
    if (size == null) return '';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(1)} KB';
    }
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Widget _pathBar(String path, {IconData icon = Icons.folder_outlined}) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: scheme.outline.withValues(alpha: 0.4)),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          children: [
            Icon(icon, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                path.isEmpty ? '/' : path,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11.5,
                  color: scheme.onSurface,
                  height: 1.2,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _paneHeader({
    required IconData icon,
    required String title,
    required List<Widget> actions,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: scheme.outline.withValues(alpha: 0.4)),
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 10),
            Icon(icon, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }

  Widget _localPane() {
    return Column(
      children: [
        _paneHeader(
          icon: Icons.phone_android,
          title: '本地',
          actions: [
            IconButton(
              tooltip: '上级',
              visualDensity: VisualDensity.compact,
              onPressed: _busy ? null : _goUpLocal,
              icon: const Icon(Icons.arrow_upward, size: 18),
            ),
            IconButton(
              tooltip: '刷新',
              visualDensity: VisualDensity.compact,
              onPressed: _busy ? null : _reloadLocal,
              icon: const Icon(Icons.refresh, size: 18),
            ),
            IconButton(
              tooltip: '选择文件夹',
              visualDensity: VisualDensity.compact,
              onPressed: _busy ? null : _pickLocalFolder,
              icon: const Icon(Icons.folder_open, size: 18),
            ),
          ],
        ),
        _pathBar(_localPath, icon: Icons.sd_storage_outlined),
        if (_loadingLocal) const LinearProgressIndicator(minHeight: 2),
        if (_localError != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              _localError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: _local.isEmpty && !_loadingLocal
              ? const Center(child: Text('空目录'))
              : ListView.separated(
                  itemCount: _local.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final e = _local[i];
                    final scheme = Theme.of(context).colorScheme;
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: Icon(
                        e.isDirectory
                            ? Icons.folder
                            : Icons.insert_drive_file_outlined,
                        size: 20,
                        color: e.isDirectory
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                      title: Text(
                        e.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text(
                        e.isDirectory ? '目录' : _formatSize(e.size),
                        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                      onTap: e.isDirectory ? () => _openLocalDir(e) : null,
                      trailing: e.isDirectory
                          ? Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant)
                          : IconButton(
                              tooltip: '上传到远程',
                              visualDensity: VisualDensity.compact,
                              onPressed: _busy ? null : () => _uploadLocal(e),
                              icon: Icon(Icons.upload, size: 18, color: scheme.primary),
                            ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _remotePane({required List<Widget> actions}) {
    final session = _session;
    final cleartext = session?.profile.protocol == HostProtocol.ftp &&
        session?.profile.ftpSecure == FtpSecureMode.none;

    return Column(
      children: [
        if (cleartext)
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: const SizedBox(
              width: double.infinity,
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Text(
                  '警告：明文 FTP。生产环境请使用 FTPS / FTPES / SFTP。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
          ),
        _paneHeader(
          icon: Icons.cloud_outlined,
          title: session?.keepAliveTitle ?? '远程',
          actions: actions,
        ),
        _pathBar(session?.backend.currentPath ?? '', icon: Icons.cloud_queue_outlined),
        if (_busy || _loadingRemote) const LinearProgressIndicator(minHeight: 2),
        if (_remoteError != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _remoteError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: _remote.isEmpty && !_loadingRemote
              ? const Center(child: Text('空目录'))
              : ListView.separated(
                  itemCount: _remote.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final e = _remote[i];
                    final scheme = Theme.of(context).colorScheme;
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: Icon(
                        e.isDirectory
                            ? Icons.folder
                            : Icons.insert_drive_file_outlined,
                        size: 20,
                        color: e.isDirectory
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                      title: Text(
                        e.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text(
                        e.isDirectory ? '目录' : _formatSize(e.size),
                        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                      onTap: e.isDirectory ? () => _openRemoteDir(e) : null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!e.isDirectory)
                            IconButton(
                              tooltip: '下载到本地',
                              visualDensity: VisualDensity.compact,
                              onPressed: _busy ? null : () => _downloadToLocal(e),
                              icon: Icon(Icons.download, size: 18, color: scheme.primary),
                            ),
                          PopupMenuButton<String>(
                            tooltip: '更多',
                            padding: EdgeInsets.zero,
                            onSelected: (v) {
                              if (v == 'download' && !e.isDirectory) {
                                _downloadToLocal(e);
                              } else if (v == 'delete') {
                                _deleteRemote(e);
                              }
                            },
                            itemBuilder: (_) => [
                              if (!e.isDirectory)
                                const PopupMenuItem(
                                  value: 'download',
                                  child: Text('下载到本地栏'),
                                ),
                              const PopupMenuItem(
                                value: 'delete',
                                child: Text('删除'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(sessionManagerProvider);
    final wide = MediaQuery.sizeOf(context).width >= PadBreakpoints.split;

    final remoteActions = <Widget>[
      if (!wide)
        IconButton(
          tooltip: _showLocalNarrow ? '隐藏本地' : '显示本地',
          visualDensity: VisualDensity.compact,
          onPressed: () => setState(() => _showLocalNarrow = !_showLocalNarrow),
          icon: Icon(
            _showLocalNarrow ? Icons.phone_android : Icons.phone_android_outlined,
            size: 18,
          ),
        ),
      IconButton(
        tooltip: '上级目录',
        visualDensity: VisualDensity.compact,
        onPressed: _busy ? null : _goUpRemote,
        icon: const Icon(Icons.arrow_upward, size: 18),
      ),
      IconButton(
        tooltip: '刷新',
        visualDensity: VisualDensity.compact,
        onPressed: _busy ? null : _reloadRemote,
        icon: const Icon(Icons.refresh, size: 18),
      ),
      IconButton(
        tooltip: '新建文件夹',
        visualDensity: VisualDensity.compact,
        onPressed: _busy ? null : _mkdirRemote,
        icon: const Icon(Icons.create_new_folder_outlined, size: 18),
      ),
      IconButton(
        tooltip: '上传（选取文件）',
        visualDensity: VisualDensity.compact,
        onPressed: _busy ? null : _uploadPicked,
        icon: const Icon(Icons.upload_file, size: 18),
      ),
      IconButton(
        tooltip: '断开',
        visualDensity: VisualDensity.compact,
        onPressed: _close,
        icon: const Icon(Icons.link_off, size: 18),
      ),
    ];

    final scheme = Theme.of(context).colorScheme;
    final body = wide
        ? Row(
            children: [
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(color: scheme.outline.withValues(alpha: 0.35)),
                    ),
                  ),
                  child: _localPane(),
                ),
              ),
              Expanded(child: _remotePane(actions: remoteActions)),
            ],
          )
        : Column(
            children: [
              if (_showLocalNarrow)
                SizedBox(
                  height: MediaQuery.sizeOf(context).height * 0.35,
                  child: _localPane(),
                ),
              if (_showLocalNarrow) const Divider(height: 1),
              Expanded(child: _remotePane(actions: remoteActions)),
            ],
          );

    if (widget.embedded) {
      return Column(
        children: [
          Material(
            color: scheme.surfaceContainerHighest,
            child: SafeArea(
              bottom: false,
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: scheme.outline.withValues(alpha: 0.45)),
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Icon(Icons.folder_open, size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _session?.keepAliveTitle ?? '文件',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      wide ? '双栏' : '远程',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_session?.keepAliveTitle ?? '文件'),
      ),
      body: body,
    );
  }
}

/// Helper to open a file session then push [FilesPage].
Future<void> openFileBrowser(
  BuildContext context,
  WidgetRef ref,
  HostProfile profile,
) async {
  final mgr = ref.read(sessionManagerProvider);
  final nav = Navigator.of(context);
  final future = mgr.openFiles(profile);
  await nav.push(
    MaterialPageRoute(
      settings: const RouteSettings(name: '/files'),
      builder: (_) => const FilesPage(),
    ),
  );
  await future;
}
