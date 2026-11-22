import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../../data/host_profile.dart';
import '../session/session_log.dart';
import 'jump_chain.dart';
import 'port_forward_runner.dart';
import 'ssh_connector.dart';

/// One authenticated [SSHClient] per host profile id.
///
/// Terminal tabs open additional shell channels; Files uses [SSHClient.sftp]
/// on the **same** client. Disconnecting the host tears down the transport
/// and every channel attached to it.
class SshConnectionHub {
  final Map<String, _HubEntry> _entries = {};
  final PortForwardRunner portForwards = PortForwardRunner();

  /// Loads another saved host (with secrets) when this profile uses a jump.
  Future<HostProfile?> Function(String id)? resolveHost;

  /// Stable key: [HostProfile.id] (shared across SSH ↔ SFTP protocol flip).
  String keyFor(HostProfile profile) => profile.id;

  bool isConnected(String hostId) {
    final e = _entries[hostId];
    return e != null && !e.client.isClosed;
  }

  SSHClient? clientOf(String hostId) {
    final e = _entries[hostId];
    if (e == null || e.client.isClosed) return null;
    return e.client;
  }

  /// Ensure a live [SSHClient] for [profile]. Reuses an existing connection
  /// when present; otherwise TCP+auth via [SshConnector], through a jump
  /// chain when [HostProfile.jumpHostId] is set.
  Future<SSHClient> ensureClient(HostProfile profile) async {
    final key = keyFor(profile);
    final existing = _entries[key];
    if (existing != null && !existing.client.isClosed) {
      sessionLog.add(
        'Reusing SSH connection ${profile.host}:${profile.port} '
        '(shells=${existing.shellRefs} sftp=${existing.sftpRefs})',
      );
      return existing.client;
    }
    if (existing != null) {
      _entries.remove(key);
    }

    final chain = await _chainFor(profile);
    SSHClient? via;
    String? viaId;
    final opened = <String>[];
    try {
      for (final hop in chain) {
        final live = _entries[hop.id];
        if (live != null && !live.client.isClosed) {
          via = live.client;
          viaId = hop.id;
          continue;
        }
        if (live != null) _entries.remove(hop.id);

        final client = await SshConnector.connect(hop, via: via);
        final entry = _HubEntry(
          client: client,
          profile: hop,
          viaHostId: viaId,
        );
        if (viaId != null) retainTunnel(viaId);
        _entries[hop.id] = entry;
        opened.add(hop.id);
        final hopId = hop.id;
        unawaited(
          client.done.then((_) {
            if (!identical(_entries[hopId], entry)) return;
            _entries.remove(hopId);
            unawaited(portForwards.stop(hopId));
            final parent = entry.viaHostId;
            if (parent != null) unawaited(releaseTunnel(parent));
            sessionLog.add(
              'SSH connection closed ${hop.host}:${hop.port}',
            );
          }),
        );
        if (hop.forwards.isNotEmpty) {
          await portForwards.sync(hop, client);
        }
        via = client;
        viaId = hop.id;
      }
    } catch (e) {
      for (final id in opened.reversed) {
        final entry = _entries[id];
        if (entry != null && entry.shellRefs == 0 && entry.sftpRefs == 0) {
          await disconnect(id);
        }
      }
      rethrow;
    }
    return via!;
  }

  Future<List<HostProfile>> _chainFor(HostProfile target) async {
    final byId = <String, HostProfile>{target.id: target};
    var cursor = target;
    while (true) {
      final nextId = cursor.jumpHostId?.trim() ?? '';
      if (nextId.isEmpty) break;
      if (byId.containsKey(nextId)) break;
      final resolver = resolveHost;
      final hop = resolver == null ? null : await resolver(nextId);
      if (hop == null) {
        throw JumpChainError('找不到跳板主机');
      }
      byId[hop.id] = hop;
      cursor = hop;
    }
    return resolveJumpChain(target, byId);
  }

  void retainShell(String hostId) {
    final e = _entries[hostId];
    if (e == null) return;
    e.shellRefs++;
  }

  void retainSftp(String hostId) {
    final e = _entries[hostId];
    if (e == null) return;
    e.sftpRefs++;
  }

  void retainTunnel(String hostId) {
    final e = _entries[hostId];
    if (e == null) return;
    e.tunnelRefs++;
  }

  /// Drop one shell ref. Closes the transport only when no shells/SFTP remain.
  Future<void> releaseShell(String hostId) async {
    final e = _entries[hostId];
    if (e == null) return;
    if (e.shellRefs > 0) e.shellRefs--;
    await _maybeClose(hostId);
  }

  /// Drop one SFTP ref. Does **not** close the transport while shells remain.
  Future<void> releaseSftp(String hostId) async {
    final e = _entries[hostId];
    if (e == null) return;
    if (e.sftpRefs > 0) e.sftpRefs--;
    await _maybeClose(hostId);
  }

  Future<void> releaseTunnel(String hostId) async {
    final e = _entries[hostId];
    if (e == null) return;
    if (e.tunnelRefs > 0) e.tunnelRefs--;
    await _maybeClose(hostId);
  }

  /// Force-close this host's SSHClient (all shells + SFTP die with it).
  Future<void> disconnect(String hostId) async {
    final e = _entries.remove(hostId);
    if (e == null) return;
    e.shellRefs = 0;
    e.sftpRefs = 0;
    e.tunnelRefs = 0;
    await portForwards.stop(hostId);
    try {
      e.client.close();
    } catch (err) {
      debugPrint('SshConnectionHub.disconnect: $err');
    }
    final parent = e.viaHostId;
    if (parent != null) await releaseTunnel(parent);
  }

  Future<void> disconnectAll() async {
    final keys = List<String>.from(_entries.keys);
    for (final k in keys) {
      await disconnect(k);
    }
  }

  Future<void> _maybeClose(String hostId) async {
    final e = _entries[hostId];
    if (e == null) return;
    if (e.shellRefs > 0 || e.sftpRefs > 0 || e.tunnelRefs > 0) return;
    await disconnect(hostId);
  }
}

class _HubEntry {
  _HubEntry({required this.client, required this.profile, this.viaHostId});

  final SSHClient client;
  final HostProfile profile;
  final String? viaHostId;
  int shellRefs = 0;
  int sftpRefs = 0;
  int tunnelRefs = 0;
}
