import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/host_profile.dart';
import '../../data/host_store.dart';
import '../keepalive/keepalive_controller.dart';
import '../ssh/ssh_connection_hub.dart';
import '../telnet/telnet_terminal_session.dart';
import 'file_browser_session.dart';
import 'session_log.dart';
import 'ssh_terminal_session.dart';
import 'terminal_session.dart';

/// Multi-session hub: SSH/Telnet terminals + SFTP/FTP browsers; syncs FGS.
///
/// SSH hosts share one [SSHClient] via [SshConnectionHub]: extra terminal
/// tabs open shell channels; Files opens `client.sftp()` on the same client.
class SessionManager extends ChangeNotifier {
  SessionManager(
    this._keepalive, {
    this._hostStore,
  }) : sshHub = SshConnectionHub();

  final KeepAliveController _keepalive;
  final HostStore? _hostStore;

  /// Shared SSH transports keyed by host profile id.
  final SshConnectionHub sshHub;

  final List<TerminalSession> _terminals = [];
  final List<FileBrowserSession> _files = [];
  String? _activeTerminalId;
  String? _activeFileId;
  bool _disposed = false;

  List<TerminalSession> get terminals => List.unmodifiable(_terminals);
  List<FileBrowserSession> get files => List.unmodifiable(_files);

  /// Back-compat alias used by terminal UI.
  List<TerminalSession> get sessions => terminals;

  String? get activeId => _activeTerminalId;
  String? get activeFileId => _activeFileId;

  TerminalSession? get active {
    if (_terminals.isEmpty) return null;
    final id = _activeTerminalId;
    if (id == null) return _terminals.last;
    for (final s in _terminals) {
      if (s.id == id) return s;
    }
    return _terminals.last;
  }

  FileBrowserSession? get activeFile {
    if (_files.isEmpty) return null;
    final id = _activeFileId;
    if (id == null) return _files.last;
    for (final s in _files) {
      if (s.id == id) return s;
    }
    return _files.last;
  }

  /// Reload password/key from secure storage every connect attempt.
  Future<HostProfile> _withFreshSecrets(HostProfile profile) async {
    final store = _hostStore;
    if (store == null) return profile;
    try {
      return await store.withSecrets(profile);
    } catch (e, st) {
      debugPrint('withSecrets failed: $e\n$st');
      sessionLog.add(
        'Secret reload failed: $e',
        level: SessionLogLevel.warn,
      );
      return profile;
    }
  }

  Future<TerminalSession> openTerminal(HostProfile profile) async {
    if (!profile.protocol.isTerminal) {
      throw UnsupportedError(
        '${profile.protocol.label} is not a terminal protocol',
      );
    }
    final hydrated = await _withFreshSecrets(profile);
    final id =
        '${hydrated.id}_${DateTime.now().millisecondsSinceEpoch}_${_terminals.length}';
    final TerminalSession session = hydrated.protocol == HostProtocol.telnet
        ? TelnetTerminalSession(id: id, profile: hydrated)
        : SshTerminalSession(id: id, profile: hydrated, hub: sshHub);

    _attach(session);

    try {
      await session.connect();
    } catch (_) {
      // Keep listed with error phase so user can dismiss.
    }
    _syncKeepAlive();
    notifyListeners();
    return session;
  }

  /// Back-compat for M1 call sites.
  Future<TerminalSession> open(HostProfile profile) => openTerminal(profile);

  Future<FileBrowserSession> openFiles(HostProfile profile) async {
    // Opening Files from an SSH terminal flips protocol to SFTP but keeps id.
    final asFile = profile.protocol.isFile
        ? profile
        : profile.protocol == HostProtocol.ssh
            ? profile.asSftp()
            : profile;
    if (!asFile.protocol.isFile) {
      throw UnsupportedError(
        '${profile.protocol.label} is not a file protocol',
      );
    }

    // Reuse an existing file session for this host.
    for (final f in _files) {
      if (f.profile.id == asFile.id &&
          (f.phase == SessionPhase.connected ||
              f.phase == SessionPhase.connecting)) {
        _activeFileId = f.id;
        notifyListeners();
        return f;
      }
    }

    final hydrated = await _withFreshSecrets(asFile);
    final id =
        'file_${hydrated.id}_${DateTime.now().millisecondsSinceEpoch}_${_files.length}';
    final session = FileBrowserSession(
      id: id,
      profile: hydrated,
      backend: FileBrowserSession.backendFor(
        hydrated,
        sshHub: hydrated.protocol == HostProtocol.sftp ? sshHub : null,
      ),
    );
    session.onChanged = () {
      if (!_disposed) {
        notifyListeners();
        _syncKeepAlive();
      }
    };
    _files.add(session);
    _activeFileId = id;
    notifyListeners();
    _syncKeepAlive();

    try {
      await session.connect();
    } catch (_) {}
    _syncKeepAlive();
    notifyListeners();
    return session;
  }

  final Set<String> _reconnecting = {};

  /// True while a manual reconnect for terminal [id] is in flight.
  bool isReconnecting(String id) => _reconnecting.contains(id);

  /// Whether terminal [s] can be manually reconnected right now.
  bool canReconnect(TerminalSession s) =>
      !_reconnecting.contains(s.id) &&
      (s.phase == SessionPhase.disconnected || s.phase == SessionPhase.error);

  /// Register an externally-built session (tests / restore).
  @visibleForTesting
  void addTerminalForTest(TerminalSession session) => _attach(session);

  void _attach(TerminalSession session) {
    session.onChanged = () {
      if (!_disposed) {
        notifyListeners();
        _syncKeepAlive();
      }
    };
    _terminals.add(session);
    _activeTerminalId = session.id;
    notifyListeners();
    _syncKeepAlive();
  }

  /// User "断开": tear down the transport for this tab but keep the tab so it
  /// can be reconnected later. Closing the tab (x) still uses [close].
  Future<void> disconnectSession(String id) async {
    final s = _find(id);
    if (s == null) return;
    await s.disconnect();
    notifyListeners();
    await _syncKeepAlive();
  }

  /// Manual reconnect: same tab, same profile, same terminal buffer.
  /// Returns true on success. Never runs automatically.
  Future<bool> reconnect(String id) async {
    final s = _find(id);
    if (s == null || !canReconnect(s)) return false;
    _reconnecting.add(id);
    notifyListeners();
    try {
      // Drop any stale channel / hub ref first (idempotent).
      await s.disconnect(silent: true);
      await s.connect();
      if (_find(id) == null) return false; // closed meanwhile
      s.terminal.write('\r\n--- 已重新连接 ---\r\n');
      // Re-attach file browsers of this host that dropped with the transport.
      for (final f in List<FileBrowserSession>.from(_files)) {
        if (f.profile.id == s.profile.id &&
            (f.phase == SessionPhase.disconnected ||
                f.phase == SessionPhase.error)) {
          try {
            await f.disconnect();
            await f.connect();
          } catch (e) {
            sessionLog.add('File session reconnect failed: $e',
                level: SessionLogLevel.warn);
          }
        }
      }
      return true;
    } catch (e) {
      sessionLog.add('Reconnect failed: $e', level: SessionLogLevel.warn);
      return false;
    } finally {
      _reconnecting.remove(id);
      if (!_disposed) {
        notifyListeners();
        await _syncKeepAlive();
      }
    }
  }

  TerminalSession? _find(String id) {
    for (final s in _terminals) {
      if (s.id == id) return s;
    }
    return null;
  }

  void setActive(String id) {
    if (_terminals.any((s) => s.id == id)) {
      _activeTerminalId = id;
      notifyListeners();
    }
  }

  void setActiveFile(String id) {
    if (_files.any((s) => s.id == id)) {
      _activeFileId = id;
      notifyListeners();
    }
  }

  Future<void> close(String id) async {
    final i = _terminals.indexWhere((s) => s.id == id);
    if (i < 0) return;
    final s = _terminals.removeAt(i);
    await s.disconnect();
    s.dispose();
    if (_activeTerminalId == id) {
      _activeTerminalId = _terminals.isEmpty ? null : _terminals.last.id;
    }
    notifyListeners();
    await _syncKeepAlive();
  }

  Future<void> closeFile(String id) async {
    final i = _files.indexWhere((s) => s.id == id);
    if (i < 0) return;
    final s = _files.removeAt(i);
    await s.disconnect();
    s.dispose();
    if (_activeFileId == id) {
      _activeFileId = _files.isEmpty ? null : _files.last.id;
    }
    notifyListeners();
    await _syncKeepAlive();
  }

  /// Disconnect every terminal + file session for [hostId], then tear down
  /// the shared SSH transport.
  Future<void> disconnectHost(String hostId) async {
    final termIds = _terminals
        .where((s) => s.profile.id == hostId)
        .map((s) => s.id)
        .toList();
    final fileIds = _files
        .where((s) => s.profile.id == hostId)
        .map((s) => s.id)
        .toList();
    for (final id in termIds) {
      await close(id);
    }
    for (final id in fileIds) {
      await closeFile(id);
    }
    await sshHub.disconnect(hostId);
    notifyListeners();
    await _syncKeepAlive();
  }

  Future<void> closeAll() async {
    final terms = List<TerminalSession>.from(_terminals);
    final files = List<FileBrowserSession>.from(_files);
    _terminals.clear();
    _files.clear();
    _activeTerminalId = null;
    _activeFileId = null;
    notifyListeners();
    for (final s in terms) {
      await s.disconnect();
      s.dispose();
    }
    for (final s in files) {
      await s.disconnect();
      s.dispose();
    }
    await sshHub.disconnectAll();
    await _syncKeepAlive();
  }

  Future<void> _syncKeepAlive() async {
    final titles = <String>[
      ..._terminals
          .where((s) =>
              s.phase == SessionPhase.connected ||
              s.phase == SessionPhase.connecting)
          .map((s) => s.keepAliveTitle),
      ..._files
          .where((s) =>
              s.phase == SessionPhase.connected ||
              s.phase == SessionPhase.connecting)
          .map((s) => s.keepAliveTitle),
    ];
    await _keepalive.updateSessions(titles);
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _terminals) {
      s.dispose();
    }
    for (final s in _files) {
      s.dispose();
    }
    _terminals.clear();
    _files.clear();
    // Fire-and-forget; dispose cannot await.
    sshHub.disconnectAll();
    super.dispose();
  }
}

final sessionManagerProvider = ChangeNotifierProvider<SessionManager>((ref) {
  final keepalive = ref.watch(keepAliveControllerProvider);
  final hostStore = ref.watch(hostStoreProvider);
  final mgr = SessionManager(keepalive, hostStore: hostStore);
  keepalive.onStopRequested = () {
    mgr.closeAll();
  };
  ref.onDispose(() {
    keepalive.onStopRequested = null;
    mgr.dispose();
  });
  return mgr;
});
