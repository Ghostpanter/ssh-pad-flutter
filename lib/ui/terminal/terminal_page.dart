import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../core/ime/ime_controller.dart';
import '../../core/session/session_manager.dart';
import '../../core/session/terminal_session.dart';
import '../../data/host_profile.dart';
import '../files/files_page.dart';
import '../widgets/session_status.dart';
import '../keyboard/app_escape_policy.dart';
import 'extra_keys.dart';
import 'hardware_keyboard_handler.dart';
import 'terminal_selection.dart';

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
  final Map<String, TerminalController> _termControllers = {};
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
    for (final c in _termControllers.values) {
      c.dispose();
    }
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

  TerminalController _controllerFor(String id) {
    return _termControllers.putIfAbsent(id, TerminalController.new);
  }

  Future<void> _pasteActive() async {
    final active = ref.read(sessionManagerProvider).active;
    if (active == null) return;
    await pasteClipboardToTerminal(active.terminal);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已粘贴到终端'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  Future<void> _copyActive() async {
    final active = ref.read(sessionManagerProvider).active;
    if (active == null) return;
    final controller = _termControllers[active.id];
    if (controller == null) return;
    final text = selectedTerminalText(active.terminal, controller);
    if (text == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('请先长按或拖选文字'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    await copyTerminalSelection(active.terminal, controller);
    controller.clearSelection();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已复制'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  static const double _chromeHeight = 38;

  String _phaseTooltip(TerminalSession? active) {
    if (active == null) return '未连接';
    final base = SessionStatusStyle.label(active.phase);
    if (active.phase == SessionPhase.connected) {
      return '$base · 保活中';
    }
    return base;
  }

  Widget _chromeAction({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 18, color: color),
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  /// Compact Termius/Termux-style chrome: tabs + actions on one ~38dp row.
  /// Status subtitle (已连接 · 保活中) moves into the status-dot tooltip.
  Widget _compactChrome(
    BuildContext context,
    SessionManager mgr,
    TerminalSession? active, {
    bool showBack = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF161B22) : scheme.surfaceContainerHighest;

    final actions = <Widget>[
      if (active != null) ...[
        _chromeAction(
          tooltip: '打开文件 (SFTP)',
          icon: Icons.folder_open_outlined,
          onPressed: _openFiles,
        ),
        _chromeAction(
          tooltip: '断开当前',
          icon: Icons.link_off,
          onPressed: _disconnectActive,
        ),
        _chromeAction(
          tooltip: '粘贴',
          icon: Icons.content_paste,
          onPressed: _pasteActive,
        ),
      ],
      _chromeAction(
        tooltip: _forceSoftIme || !_hwKeyboard ? '软键盘' : '唤起软键盘',
        icon: _useSoftIme ? Icons.keyboard_alt : Icons.keyboard_alt_outlined,
        color: _forceSoftIme ? scheme.primary : null,
        onPressed: _toggleSoftKeyboard,
      ),
      PopupMenuButton<String>(
        tooltip: '更多',
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: const Size(40, 36),
          padding: const EdgeInsets.all(6),
          visualDensity: VisualDensity.compact,
        ),
        icon: const Icon(Icons.more_vert, size: 18),
        onSelected: (v) async {
          if (v == 'all') await _disconnectAll();
          if (v == 'ime') await _clearImeComposition();
          if (v == 'files') await _openFiles();
          if (v == 'kbd') await _toggleSoftKeyboard();
          if (v == 'disconnect' && active != null) await _disconnectActive();
          if (v == 'copy') await _copyActive();
          if (v == 'paste') await _pasteActive();
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'copy', child: Text('复制选区')),
          const PopupMenuItem(value: 'paste', child: Text('粘贴')),
          const PopupMenuItem(value: 'files', child: Text('打开文件 (SFTP)')),
          PopupMenuItem(
            value: 'kbd',
            child: Text(_forceSoftIme ? '关闭软键盘强制' : '键盘（软键盘）'),
          ),
          if (active != null)
            const PopupMenuItem(value: 'disconnect', child: Text('断开当前')),
          const PopupMenuItem(value: 'ime', child: Text('清除输入法组字')),
          const PopupMenuItem(value: 'all', child: Text('断开全部会话')),
        ],
      ),
    ];

    final Widget leading;
    if (mgr.sessions.isNotEmpty) {
      leading = Expanded(
        child: _SessionTabBar(
          manager: mgr,
          height: _chromeHeight,
          embedded: true,
        ),
      );
    } else {
      leading = Expanded(
        child: Row(
          children: [
            if (active != null) ...[
              Tooltip(
                message: _phaseTooltip(active),
                child: StatusDot(phase: active.phase, size: 8),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                active?.title ?? '终端',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      height: 1.1,
                    ),
              ),
            ),
          ],
        ),
      );
    }

    return Material(
      color: bg,
      child: SafeArea(
        bottom: false,
        // Parent PadShell narrow layout already consumes top inset; nested
        // SafeArea then sees 0 and does not double-pad. Split mode relies on
        // this single top inset for the terminal pane.
        child: Container(
          height: _chromeHeight,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: scheme.outline.withValues(alpha: 0.45)),
            ),
          ),
          child: Row(
            children: [
              if (showBack)
                IconButton(
                  tooltip: '返回',
                  icon: const Icon(Icons.arrow_back, size: 18),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
                  onPressed: () => Navigator.of(context).maybePop(),
                )
              else
                const SizedBox(width: 6),
              leading,
              ...actions,
              const SizedBox(width: 2),
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
                  child: TerminalSelectionHost(
                    terminal: active.terminal,
                    controller: _controllerFor(active.id),
                    focusNode: _terminalFocus,
                    hardwareKeyboardOnly: !_useSoftIme,
                    onCopied: () {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已复制'),
                          behavior: SnackBarBehavior.floating,
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                    onPasted: () {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已粘贴到终端'),
                          behavior: SnackBarBehavior.floating,
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
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
          _compactChrome(context, mgr, active),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      body: Column(
        children: [
          _compactChrome(context, mgr, active, showBack: true),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _SessionTabBar extends StatelessWidget {
  const _SessionTabBar({
    required this.manager,
    this.height = 36,
    this.embedded = false,
  });

  final SessionManager manager;
  final double height;

  /// When true, render as an inline strip (no own background / bottom border);
  /// parent chrome owns the bar styling.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final list = ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(
        horizontal: embedded ? 0 : 6,
        vertical: embedded ? 4 : 4,
      ),
      itemCount: manager.sessions.length,
      itemBuilder: (context, i) {
        final s = manager.sessions[i];
        final selected = s.id == manager.activeId;
        final phaseTip = SessionStatusStyle.label(s.phase) +
            (s.phase == SessionPhase.connected ? ' · 保活中' : '');
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
                    Tooltip(
                      message: phaseTip,
                      child: StatusDot(phase: s.phase, size: 6),
                    ),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: manager.sessions.length == 1 ? 180 : 120,
                      ),
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
    );

    if (embedded) {
      return SizedBox(height: height, child: list);
    }

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF0D1117) : scheme.surfaceContainerHigh,
        border: Border(
          bottom: BorderSide(color: scheme.outline.withValues(alpha: 0.45)),
        ),
      ),
      child: list,
    );
  }
}
