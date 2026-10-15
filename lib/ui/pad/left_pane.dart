import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/session/session_manager.dart';
import '../../core/session/session_backend.dart';
import '../../data/host_profile.dart';
import '../../data/host_store.dart';
import '../theme.dart';
import '../host_editor.dart';
import '../placeholders.dart';
import '../widgets/session_status.dart';
import '../widgets/host_resource_strip.dart';
import '../../core/status/host_status_monitor.dart';
import '../../core/status/host_resource_stats.dart';
import 'pad_breakpoints.dart';

enum PadSection { hosts, terminal, files, settings }

/// Left / host list pane: denser ServerBox-like node cards + live sessions.
class LeftPane extends ConsumerWidget {
  const LeftPane({
    super.key,
    required this.section,
    required this.onSection,
    required this.onConnectHost,
    this.compactHeader = false,
  });

  final PadSection section;
  final ValueChanged<PadSection> onSection;
  final Future<void> Function(HostProfile host) onConnectHost;
  final bool compactHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosts = ref.watch(hostListProvider);
    final mgr = ref.watch(sessionManagerProvider);
    final statusMonitor = ref.watch(hostStatusMonitorProvider);
    final themeMode = ref.watch(themeModeProvider);
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            themeMode: themeMode,
            onToggleTheme: () {
              final next = themeMode == ThemeMode.dark
                  ? ThemeMode.light
                  : ThemeMode.dark;
              ref.read(themeModeProvider.notifier).state = next;
            },
            onSettings: () => onSection(PadSection.settings),
            compact: compactHeader,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: _SegButton(
                    label: '终端',
                    icon: Icons.terminal,
                    selected: section == PadSection.terminal,
                    onTap: () => onSection(PadSection.terminal),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: _SegButton(
                    label: '文件',
                    icon: Icons.folder_outlined,
                    selected: section == PadSection.files,
                    enabled: mgr.files.isNotEmpty ||
                        mgr.active?.profile.protocol == HostProtocol.ssh,
                    onTap: () => onSection(PadSection.files),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: _SegButton(
                    label: '主机',
                    icon: Icons.dns_outlined,
                    selected: section == PadSection.hosts,
                    onTap: () => onSection(PadSection.hosts),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
              children: [
                SectionHeading(
                  '节点',
                  trailing: Text(
                    '${hosts.length}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ),
                if (hosts.isEmpty && mgr.sessions.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '还没有保存的主机\n点下方「新建主机」开始',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                for (final h in hosts) ...[
                  _HostCard(
                    host: h,
                    sessionPhase: _phaseForHost(mgr, h),
                    selected: _isSelected(mgr, h),
                    resourceStats: _statsForHost(mgr, h, statusMonitor),
                    onTap: () => onConnectHost(h),
                    onEdit: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => HostEditorPage(existing: h),
                        ),
                      );
                    },
                    onDelete: () =>
                        ref.read(hostListProvider.notifier).delete(h.id),
                    onCloseSession: () async {
                      await mgr.disconnectHost(h.id);
                    },
                  ),
                  const SizedBox(height: 4),
                ],
                if (mgr.sessions.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SectionHeading(
                    '终端会话',
                    trailing: Text(
                      '${mgr.sessions.length}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                  for (final s in mgr.sessions) ...[
                    _SessionCard(
                      title: s.keepAliveTitle,
                      phase: s.phase,
                      selected: s.id == mgr.activeId,
                      onSelect: () {
                        mgr.setActive(s.id);
                        onSection(PadSection.terminal);
                      },
                      onClose: () => mgr.close(s.id),
                      onReconnect: mgr.canReconnect(s)
                          ? () {
                              mgr.setActive(s.id);
                              mgr.reconnect(s.id);
                            }
                          : null,
                      reconnecting: mgr.isReconnecting(s.id),
                    ),
                    const SizedBox(height: 4),
                  ],
                ],
                if (mgr.files.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SectionHeading(
                    '文件会话',
                    trailing: Text(
                      '${mgr.files.length}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                  for (final f in mgr.files) ...[
                    _SessionCard(
                      title: f.keepAliveTitle,
                      phase: f.phase,
                      selected: f.id == mgr.activeFileId,
                      onSelect: () {
                        mgr.setActiveFile(f.id);
                        onSection(PadSection.files);
                      },
                      onClose: () => mgr.closeFile(f.id),
                    ),
                    const SizedBox(height: 4),
                  ],
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(PadBreakpoints.minTap),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const HostEditorPage(),
                    ),
                  );
                },
                icon: const Icon(Icons.add, size: 20),
                label: const Text('新建主机'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static SessionPhase? _phaseForHost(SessionManager mgr, HostProfile h) {
    for (final s in mgr.sessions) {
      if (s.profile.id == h.id) return s.phase;
    }
    for (final s in mgr.files) {
      if (s.profile.id == h.id) return s.phase;
    }
    return null;
  }


  static bool _isSelected(SessionManager mgr, HostProfile h) {
    final a = mgr.active;
    if (a != null && a.profile.id == h.id) return true;
    final f = mgr.activeFile;
    if (f != null && f.profile.id == h.id) return true;
    return false;
  }

  static HostResourceStats? _statsForHost(
    SessionManager mgr,
    HostProfile h,
    HostStatusMonitor monitor,
  ) {
    final isSshFamily =
        h.protocol == HostProtocol.ssh || h.protocol == HostProtocol.sftp;
    if (!isSshFamily) return null;
    if (!mgr.sshHub.isConnected(h.id)) return null;
    final phase = _phaseForHost(mgr, h);
    if (!SessionStatusStyle.isLive(phase)) return null;
    return monitor.statsOf(h.id);
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.themeMode,
    required this.onToggleTheme,
    required this.onSettings,
    required this.compact,
  });

  final ThemeMode themeMode;
  final VoidCallback onToggleTheme;
  final VoidCallback onSettings;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final guard = topInset > 0 ? 0.0 : PadBreakpoints.statusBarFloor;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(top: guard),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: PadBreakpoints.minTap,
          child: Row(
            children: [
              const SizedBox(width: 12),
              Icon(Icons.terminal, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  compact ? 'Pad' : 'SSH Pad',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: '切换主题',
                constraints: const BoxConstraints(
                  minWidth: PadBreakpoints.minTap,
                  minHeight: PadBreakpoints.minTap,
                ),
                icon: Icon(
                  themeMode == ThemeMode.dark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                  size: 20,
                ),
                onPressed: onToggleTheme,
              ),
              IconButton(
                tooltip: '保活设置',
                constraints: const BoxConstraints(
                  minWidth: PadBreakpoints.minTap,
                  minHeight: PadBreakpoints.minTap,
                ),
                icon: const Icon(Icons.shield_outlined, size: 20),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const KeepAliveSettingsPage(),
                    ),
                  );
                },
              ),
              IconButton(
                tooltip: '设置',
                constraints: const BoxConstraints(
                  minWidth: PadBreakpoints.minTap,
                  minHeight: PadBreakpoints.minTap,
                ),
                icon: const Icon(Icons.settings_outlined, size: 20),
                onPressed: onSettings,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SegButton extends StatelessWidget {
  const _SegButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = !enabled
        ? scheme.surfaceContainerHighest.withValues(alpha: 0.35)
        : selected
            ? scheme.primary.withValues(alpha: 0.16)
            : scheme.surface;
    final fg = !enabled
        ? scheme.onSurface.withValues(alpha: 0.35)
        : selected
            ? scheme.primary
            : scheme.onSurfaceVariant;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: fg),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: fg,
                  height: 1.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({
    required this.host,
    required this.sessionPhase,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    required this.onCloseSession,
    this.resourceStats,
  });

  final HostProfile host;
  final SessionPhase? sessionPhase;
  final bool selected;
  final HostResourceStats? resourceStats;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onCloseSession;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final live = SessionStatusStyle.isLive(sessionPhase);
    final title = host.name.isEmpty ? host.host : host.name;
    final border = selected
        ? Border.all(color: scheme.primary.withValues(alpha: 0.55))
        : Border.all(color: scheme.outline.withValues(alpha: 0.55));

    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.10)
          : scheme.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        onLongPress: onEdit,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: border,
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StatusAccentBar(phase: sessionPhase),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 7, 2, 7),
                    child: Row(
                      children: [
                        StatusDot(phase: sessionPhase, size: 7),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      title,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        height: 1.2,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  ProtocolBadge(label: host.protocol.label),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${host.host}:${host.port}'
                                '${host.username.isEmpty ? '' : ' · ${host.username}'}',
                                style: TextStyle(
                                  fontSize: 11,
                                  height: 1.15,
                                  color: scheme.onSurfaceVariant,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (sessionPhase != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  SessionStatusStyle.label(sessionPhase),
                                  style: TextStyle(
                                    fontSize: 10,
                                    height: 1.1,
                                    color: SessionStatusStyle.color(sessionPhase),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                              if (resourceStats != null && resourceStats!.ready)
                                HostResourceStrip(stats: resourceStats!)
                              else if (live &&
                                  (host.protocol == HostProtocol.ssh ||
                                      host.protocol == HostProtocol.sftp))
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    'CPU — · MEM — · NET —',
                                    style: TextStyle(
                                      fontSize: 10,
                                      height: 1.1,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (live)
                          IconButton(
                            tooltip: '断开',
                            icon: const Icon(Icons.link_off, size: 18),
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 40,
                            ),
                            onPressed: onCloseSession,
                          )
                        else
                          IconButton(
                            tooltip: '连接',
                            icon: Icon(
                              Icons.play_arrow_rounded,
                              size: 22,
                              color: scheme.primary,
                            ),
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 40,
                            ),
                            onPressed: onTap,
                          ),
                        PopupMenuButton<String>(
                          tooltip: '更多',
                          padding: EdgeInsets.zero,
                          icon: const Icon(Icons.more_vert, size: 18),
                          constraints: const BoxConstraints(
                            minWidth: 40,
                            minHeight: 40,
                          ),
                          onSelected: (v) {
                            if (v == 'edit') onEdit();
                            if (v == 'delete') onDelete();
                            if (v == 'connect') onTap();
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'connect', child: Text('连接')),
                            PopupMenuItem(value: 'edit', child: Text('编辑')),
                            PopupMenuItem(value: 'delete', child: Text('删除')),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.title,
    required this.phase,
    required this.selected,
    required this.onSelect,
    required this.onClose,
    this.onReconnect,
    this.reconnecting = false,
  });

  final VoidCallback? onReconnect;
  final bool reconnecting;
  final String title;
  final SessionPhase phase;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.10)
          : scheme.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onSelect,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.55)
                  : scheme.outline.withValues(alpha: 0.45),
            ),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                StatusAccentBar(phase: phase),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 6, 2, 6),
                    child: Row(
                      children: [
                        StatusDot(phase: phase, size: 7),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                title,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  height: 1.2,
                                ),
                              ),
                              Text(
                                reconnecting
                                    ? '重连中'
                                    : SessionStatusStyle.label(phase),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: SessionStatusStyle.color(phase),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (onReconnect != null)
                          IconButton(
                            tooltip: '重连',
                            icon: const Icon(Icons.refresh, size: 16),
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 40,
                            ),
                            onPressed: onReconnect,
                          ),
                        IconButton(
                          tooltip: '关闭',
                          icon: const Icon(Icons.close, size: 16),
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 40,
                            minHeight: 40,
                          ),
                          onPressed: onClose,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
