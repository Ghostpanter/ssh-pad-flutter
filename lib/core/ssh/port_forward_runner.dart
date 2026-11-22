import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../data/host_profile.dart';
import '../session/session_log.dart';

/// Starts the forwards stored on a host when its SSH client is up, and tears
/// them down with that client. Listens on loopback only.
class PortForwardRunner {
  final Map<String, List<_LiveForward>> _live = {};

  Future<void> sync(HostProfile profile, SSHClient client) async {
    await stop(profile.id);
    if (profile.forwards.isEmpty) return;
    final started = <_LiveForward>[];
    for (final spec in profile.forwards) {
      if (spec.listenPort <= 0 || spec.listenPort > 65535) {
        sessionLog.add(
          '忽略转发 ${spec.label}：端口无效',
          level: SessionLogLevel.warn,
        );
        continue;
      }
      try {
        started.add(await _start(client, spec));
        sessionLog.add('转发已开 ${spec.label}');
      } catch (e) {
        sessionLog.add(
          '转发失败 ${spec.label}: $e',
          level: SessionLogLevel.error,
        );
      }
    }
    if (started.isNotEmpty) _live[profile.id] = started;
  }

  Future<void> stop(String hostId) async {
    final list = _live.remove(hostId);
    if (list == null) return;
    for (final live in list) {
      try {
        await live.close();
      } catch (e) {
        sessionLog.add('关闭转发失败: $e', level: SessionLogLevel.warn);
      }
    }
  }

  Future<void> stopAll() async {
    for (final id in List<String>.of(_live.keys)) {
      await stop(id);
    }
  }

  Future<_LiveForward> _start(SSHClient client, ForwardSpec spec) async {
    switch (spec.kind) {
      case ForwardKind.local:
        final server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          spec.listenPort,
        );
        final sub = server.listen((socket) async {
          try {
            final channel = await client.forwardLocal(
              spec.targetHost,
              spec.targetPort,
            );
            _bridge(socket, channel);
          } catch (e) {
            sessionLog.add('本地转发接入失败: $e', level: SessionLogLevel.warn);
            socket.destroy();
          }
        });
        return _LiveForward(() async {
          await sub.cancel();
          await server.close();
        });
      case ForwardKind.remote:
        final remote = await client.forwardRemote(
          host: '127.0.0.1',
          port: spec.listenPort,
        );
        if (remote == null) {
          throw StateError('远端拒绝转发端口 ${spec.listenPort}');
        }
        final sub = remote.connections.listen((channel) async {
          try {
            final socket = await Socket.connect(
              spec.targetHost,
              spec.targetPort,
              timeout: const Duration(seconds: 10),
            );
            _bridge(socket, channel);
          } catch (e) {
            sessionLog.add('远端转发接入失败: $e', level: SessionLogLevel.warn);
            channel.close();
          }
        });
        return _LiveForward(() async {
          await sub.cancel();
          remote.close();
        });
      case ForwardKind.socks:
        final dynamic = await client.forwardDynamic(
          bindHost: '127.0.0.1',
          bindPort: spec.listenPort,
        );
        return _LiveForward(dynamic.close);
    }
  }

  void _bridge(Socket socket, SSHSocket channel) {
    late final StreamSubscription<Uint8List> inbound;
    inbound = socket.listen(
      (data) {
        channel.sink.add(data);
      },
      onError: (_) {
        channel.close();
      },
      onDone: () {
        channel.close();
      },
      cancelOnError: true,
    );
    channel.stream.listen(
      (data) {
        socket.add(data);
      },
      onError: (_) {
        inbound.cancel();
        socket.destroy();
      },
      onDone: () {
        inbound.cancel();
        socket.destroy();
      },
      cancelOnError: true,
    );
  }
}

class _LiveForward {
  _LiveForward(this.close);

  final Future<void> Function() close;
}
