import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_pad_flutter/core/keepalive/keepalive_controller.dart';
import 'package:ssh_pad_flutter/core/session/session_manager.dart';
import 'package:ssh_pad_flutter/core/session/terminal_session.dart';
import 'package:ssh_pad_flutter/data/host_profile.dart';
import 'package:xterm/xterm.dart';

class FakeSession implements TerminalSession {
  FakeSession(this.id);
  @override
  final String id;
  @override
  final HostProfile profile =
      HostProfile(id: 'h', name: 'lab', host: '10.0.0.9');
  @override
  final Terminal terminal = Terminal();
  @override
  SessionPhase phase = SessionPhase.connected;
  @override
  String? errorMessage;
  @override
  VoidCallback? onChanged;

  @override
  bool get isConnected => phase == SessionPhase.connected;
  @override
  String get title => profile.name;
  @override
  String get keepAliveTitle => 'SSH lab';

  int connects = 0;
  bool failNext = false;
  Completer<void>? gate;
  final buf = StringBuffer();

  @override
  Future<void> connect() async {
    connects++;
    phase = SessionPhase.connecting;
    onChanged?.call();
    if (gate != null) await gate!.future;
    if (failNext) {
      failNext = false;
      phase = SessionPhase.error;
      errorMessage = 'Auth failed';
      onChanged?.call();
      throw StateError('Auth failed');
    }
    phase = SessionPhase.connected;
    onChanged?.call();
  }

  @override
  Future<void> disconnect({bool silent = false}) async {
    if (!silent && phase != SessionPhase.error) {
      phase = SessionPhase.disconnected;
      onChanged?.call();
    }
  }

  @override
  void dispose() {}
  @override
  void sendInterrupt() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SessionManager mgr;
  late FakeSession s;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    mgr = SessionManager(KeepAliveController(prefs));
    s = FakeSession('t1');
    s.terminal.onOutput = null;
    mgr.addTerminalForTest(s);
  });

  test('cannot reconnect while connected', () async {
    expect(mgr.canReconnect(s), isFalse);
    expect(await mgr.reconnect('t1'), isFalse);
    expect(s.connects, 0);
  });

  test('user disconnect keeps tab and allows reconnect', () async {
    await mgr.disconnectSession('t1');
    expect(mgr.sessions, hasLength(1));
    expect(s.phase, SessionPhase.disconnected);
    expect(mgr.canReconnect(s), isTrue);
    expect(await mgr.reconnect('t1'), isTrue);
    expect(s.phase, SessionPhase.connected);
    expect(identical(mgr.sessions.single, s), isTrue);
  });

  test('double reconnect is ignored while in flight', () async {
    await mgr.disconnectSession('t1');
    s.gate = Completer<void>();
    final f1 = mgr.reconnect('t1');
    await Future<void>.delayed(Duration.zero);
    expect(mgr.isReconnecting('t1'), isTrue);
    expect(await mgr.reconnect('t1'), isFalse);
    s.gate!.complete();
    expect(await f1, isTrue);
    expect(s.connects, 1);
    expect(mgr.isReconnecting('t1'), isFalse);
  });

  test('auth failure leaves error state and is retryable', () async {
    await mgr.disconnectSession('t1');
    s.failNext = true;
    expect(await mgr.reconnect('t1'), isFalse);
    expect(s.phase, SessionPhase.error);
    expect(s.errorMessage, 'Auth failed');
    expect(mgr.canReconnect(s), isTrue);
    expect(await mgr.reconnect('t1'), isTrue);
  });

  test('close removes the tab', () async {
    await mgr.disconnectSession('t1');
    await mgr.close('t1');
    expect(mgr.sessions, isEmpty);
    expect(await mgr.reconnect('t1'), isFalse);
  });
}
