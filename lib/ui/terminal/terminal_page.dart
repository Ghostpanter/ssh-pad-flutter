import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../core/ime/ime_controller.dart';
import '../../core/session/session_manager.dart';
import '../../core/session/terminal_session.dart';
import '../../data/host_profile.dart';
import '../files/files_page.dart';
import '../pad/pad_breakpoints.dart';
import '../widgets/session_status.dart';
import '../keyboard/app_escape_policy.dart';
import 'extra_keys.dart';
import 'hardware_keyboard_handler.dart';

/// Soft IME style: visible-password reduces suggestions / smart punctuation.
const kTerminalKeyboardType = TextInputType.visiblePassword;

/// Multi-tab SSH/Telnet terminal workspace. Sessions live in [SessionManager].
///
/// Use [embedded] when hosted inside [PadShell] (no outer Scaffold / back).
class TerminalPage extends ConsumerStatefulWidget {
  const TerminalPage({
    super.key,
    this.embedded = false,
    this.onOpenFiles,
  });

  final bool embedded;

  /// When embedded, PadShell may prefer switching pane instead of pushing.
  final VoidCallback? onOpenFiles;

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage>
    with WidgetsBindingObserver {
  final _terminalFocus = FocusNode();
  ActiveTerminalKeyboard? _keyboard;
  bool _handlerRegistered = false;
  bool _hwKeyboard = false;
  /// User override: force soft IME even when HW keyboard is (mis)detected.
  bool _forceSoftIme = false;
  Size? _lastViewSize;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKey);
    _handlerRegistered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshHwKeyboard());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_handlerRegistered) {
      HardwareKeyboard.instance.removeHandler(_onKey);
    }
    AppEscapePolicy.setTerminalSink(null);
    _terminalFocus.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    final kb = _keyboard;
    if (kb == null) return false;
    return kb.handle(event);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _clearImeComposition();
      _refreshHwKeyboard();
    }
  }

  @override
  void didChangeMetrics() {
    final view = View.of(context);
    final size = view.physicalSize;
    if (_lastViewSize != size) {
      _lastViewSize = size;
      if (mounted) {
        setState(() {});
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _nudgeTerminalResize();
        });
      }
    }
    _refreshHwKeyboard();
  }

  void _nudgeTerminalResize() {
    final active = ref.read(sessionManagerProvider).active;
    if (active == null) return;
    final t = active.terminal;
    final w = t.viewWidth;
    final h = t.viewHeight;
    if (w > 0 && h > 0) {
      t.resize(w, h);
    }
  }

  Future<void> _refreshHwKeyboard() async {
    final ime = ref.read(imeControllerProvider);
    final hw = await ime.hasHardwareKeyboard();
    if (mounted && hw != _hwKeyboard) {
      setState(() => _hwKeyboard = hw);
    }
  }


  /// Soft IME should attach when no real HW kb, or user forced it on.
  bool get _useSoftIme => !_hwKeyboard || _forceSoftIme;

  /// ExtraKeys hide only when HW kb present AND user has not forced soft IME.
  bool get _hideExtraKeys => _hwKeyboard && !_forceSoftIme;

  Future<void> _toggleSoftKeyboard() async {
    setState(() => _forceSoftIme = !_forceSoftIme);
    if (_forceSoftIme) {
      await _summonSoftIme();
    }
  }

  Future<void> _summonSoftIme() async {
    if (!_terminalFocus.canRequestFocus) return;
    _terminalFocus.requestFocus();
    // Give Flutter a frame to attach TextInput before asking IMM.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    await ref.read(imeControllerProvider).showSoftInput();
    if (mounted && !_terminalFocus.hasFocus) {
      _terminalFocus.requestFocus();
    }
  }

  Future<void> _clearImeComposition() async {
    if (!_terminalFocus.canRequestFocus) return;
    _terminalFocus.unfocus();
    await ref.read(imeControllerProvider).restartInput();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _terminalFocus.requestFocus();
    });
  }

  Future<void> _openFiles() async {
    if (widget.onOpenFiles != null) {
      widget.onOpenFiles!();
      return;
    }
    final active = ref.read(sessionManagerProvider).active;
    if (active == null) return;
    if (active.profile.protocol != HostProtocol.ssh &&
        active.profile.protocol != HostProtocol.sftp) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('仅 SSH/SFTP 会话可打开文件')),
      );
      return;
    }
    await openFileBrowser(context, ref, active.profile.asSftp());
  }

  Future<void> _disconnectActive() async {
    final mgr = ref.read(sessionManagerProvider);
    final active = mgr.active;
    if (active == null) return;
    await mgr.close(active.id);
    if (mounted && mgr.sessions.isEmpty && !widget.embedded) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _disconnectAll() async {
    await ref.read(sessionManagerProvider).closeAll();
    if (mounted && !widget.embedded) {
      Navigator.of(context).maybePop();
    }
  }

  void _syncEscapeSink(TerminalSession? active, SessionManager mgr) {
    if (active == null) {
      AppEscapePolicy.setTerminalSink(null);
      return;
    }
    final sessionId = active.id;
    AppEscapePolicy.setTerminalSink(
      TerminalEscapeSink(
        terminal: active.terminal,
        isActive: () => mounted && mgr.active?.id == sessionId,
        hasTerminalFocus: () => _terminalFocus.hasFocus,
      ),
    );
  }

  Widget _toolbar(BuildContext context, TerminalSession? active) {

    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: dark ? const Color(0xFF161B22) : scheme.surfaceContainerHighest,
      child: SafeArea(
        bottom: false,
        child: Container(
          height: PadBreakpoints.minTap,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: scheme.outline.withValues(alpha: 0.55)),
            ),
          ),
          child: Row(
            children: [
              const SizedBox(width: 10),
              if (active != null) ...[
                StatusDot(phase: active.phase, size: 8),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      active?.title ?? '终端',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (active != null)
                      Text(
                        SessionStatusStyle.label(active.phase) +
                            (active.phase == SessionPhase.connected
                                ? ' · 保活中'
                                : ''),
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.1,
                          color: SessionStatusStyle.color(active.phase),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              if (active != null) ...[
                IconButton(
                  tooltip: '打开文件 (SFTP)',
                  icon: const Icon(Icons.folder_open_outlined, size: 20),
                  constraints: const BoxConstraints(
                    minWidth: PadBreakpoints.minTap,
                    minHeight: PadBreakpoints.minTap,
                  ),
                  onPressed: _openFiles,
                ),
                IconButton(
                  tooltip: '断开当前',
                  icon: const Icon(Icons.link_off, size: 20),
                  constraints: const BoxConstraints(
                    minWidth: PadBreakpoints.minTap,
                    minHeight: PadBreakpoints.minTap,
                  ),
                  onPressed: _disconnectActive,
                ),
              ],
              IconButton(
                tooltip: _forceSoftIme || !_hwKeyboard ? '软键盘' : '唤起软键盘',
                icon: Icon(
                  _useSoftIme ? Icons.keyboard_alt : Icons.keyboard_alt_outlined,
                  size: 20,
                  color: _forceSoftIme
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                constraints: const BoxConstraints(
                  minWidth: PadBreakpoints.minTap,
                  minHeight: PadBreakpoints.minTap,
                ),
                onPressed: _toggleSoftKeyboard,
              ),
              PopupMenuButton<String>(
                tooltip: '更多',
                onSelected: (v) async {
                  if (v == 'all') await _disconnectAll();
                  if (v == 'ime') await _clearImeComposition();
                  if (v == 'files') await _openFiles();
                  if (v == 'kbd') await _toggleSoftKeyboard();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'files', child: Text('打开文件 (SFTP)')),
                  PopupMenuItem(
                    value: 'kbd',
                    child: Text(_forceSoftIme ? '关闭软键盘强制' : '键盘（软键盘）'),
                  ),
                  const PopupMenuItem(value: 'ime', child: Text('清除输入法组字')),
                  const PopupMenuItem(value: 'all', child: Text('断开全部会话')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mgr = ref.watch(sessionManagerProvider);
    final active = mgr.active;

    _keyboard = active == null
        ? null
        : ActiveTerminalKeyboard(
            terminal: active.terminal,
            session: active,
            isActive: () => mounted && mgr.active?.id == active.id,
          );

    // Keep Esc→PTY sink in sync (side-effect registration; AppEscapePolicy is
    // the single sender so TerminalView never also emits 0x1b for Esc).
    _syncEscapeSink(active, mgr);

    final body = active == null
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.terminal,
                  size: 40,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 12),
                Text(
                  '选择左侧主机连接',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'SSH / TELNET 会话会出现在这里',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          )
        : Column(
            children: [
              Expanded(
                child: ColoredBox(
                  color: const Color(0xFF0D1117),
                  child: TerminalView(
                    active.terminal,
                    focusNode: _terminalFocus,
                    autofocus: true,
                    backgroundOpacity: 1,
                    padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                    keyboardType: kTerminalKeyboardType,
                    deleteDetection: true,
                    hardwareKeyboardOnly: !_useSoftIme,
                  ),
                ),
              ),
              ExtraKeysBar(
                terminal: active.terminal,
                session: active,
                hideForHardwareKeyboard: _hideExtraKeys,
                onToggleSoftKeyboard: _toggleSoftKeyboard,
                softKeyboardForced: _forceSoftIme,
              ),
            ],
          );

    if (widget.embedded) {
      return Column(
        children: [
          _toolbar(context, active),
          if (mgr.sessions.isNotEmpty)
            _SessionTabBar(manager: mgr),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(active?.title ?? '终端'),
        actions: [
          if (active != null)
            IconButton(
              tooltip: '断开当前',
              icon: const Icon(Icons.link_off),
              onPressed: _disconnectActive,
            ),
          IconButton(
            tooltip: _forceSoftIme || !_hwKeyboard ? '软键盘' : '唤起软键盘',
            icon: Icon(
              _useSoftIme ? Icons.keyboard_alt : Icons.keyboard_alt_outlined,
              color: _forceSoftIme
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            onPressed: _toggleSoftKeyboard,
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'all') await _disconnectAll();
              if (v == 'ime') await _clearImeComposition();
              if (v == 'files') await _openFiles();
              if (v == 'kbd') await _toggleSoftKeyboard();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'files', child: Text('打开文件 (SFTP)')),
              PopupMenuItem(
                value: 'kbd',
                child: Text(_forceSoftIme ? '关闭软键盘强制' : '键盘（软键盘）'),
              ),
              const PopupMenuItem(value: 'ime', child: Text('清除输入法组字')),
              const PopupMenuItem(value: 'all', child: Text('断开全部会话')),
            ],
          ),
        ],
        bottom: mgr.sessions.isNotEmpty
            ? PreferredSize(
                preferredSize: const Size.fromHeight(36),
                child: _SessionTabBar(manager: mgr),
              )
            : null,
      ),
      body: body,
    );
  }
}

class _SessionTabBar extends StatelessWidget {
  const _SessionTabBar({required this.manager});

  final SessionManager manager;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF0D1117) : scheme.surfaceContainerHigh,
        border: Border(
          bottom: BorderSide(color: scheme.outline.withValues(alpha: 0.45)),
        ),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        itemCount: manager.sessions.length,
        itemBuilder: (context, i) {
          final s = manager.sessions[i];
          final selected = s.id == manager.activeId;
          return Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Material(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.16)
                  : (dark ? const Color(0xFF21262D) : scheme.surface),
              borderRadius: BorderRadius.circular(6),
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => manager.setActive(s.id),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: selected
                          ? scheme.primary.withValues(alpha: 0.55)
                          : scheme.outline.withValues(alpha: 0.4),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StatusDot(phase: s.phase, size: 6),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 140),
                        child: Text(
                          s.title,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight:
                                selected ? FontWeight.w700 : FontWeight.w500,
                            color: selected
                                ? scheme.primary
                                : scheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      InkWell(
                        onTap: () async {
                          await manager.close(s.id);
                          if (context.mounted &&
                              manager.sessions.isEmpty &&
                              Navigator.of(context).canPop()) {
                            Navigator.of(context).maybePop();
                          }
                        },
                        borderRadius: BorderRadius.circular(10),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.close, size: 14),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
