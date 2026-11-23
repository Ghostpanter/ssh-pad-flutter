import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_pad_flutter/core/keepalive/keepalive_controller.dart';
import 'package:ssh_pad_flutter/core/session/file_backend.dart';
import 'package:ssh_pad_flutter/core/session/file_browser_session.dart';
import 'package:ssh_pad_flutter/core/session/session_backend.dart';
import 'package:ssh_pad_flutter/core/session/session_manager.dart';
import 'package:ssh_pad_flutter/data/host_profile.dart';
import 'package:ssh_pad_flutter/ui/pad/pad_breakpoints.dart';
import 'package:ssh_pad_flutter/ui/terminal/files_beside_split.dart';
import 'package:ssh_pad_flutter/ui/terminal/files_pane_controller.dart';

class _FakeBackend implements FileBackend {
  var connects = 0;
  @override
  String get currentPath => '/home';
  @override
  Future<void> connect() async => connects++;
  @override
  Future<void> disconnect() async {}
  @override
  Future<List<RemoteFileEntry>> list([String? path]) async => const [];
  @override
  Future<void> changeDirectory(String path) async {}
  @override
  Future<void> mkdir(String name) async {}
  @override
  Future<void> delete(RemoteFileEntry entry) async {}
  @override
  Future<void> upload(String remoteName, Uint8List bytes) async {}
  @override
  Future<Uint8List> download(String remoteName) async => Uint8List(0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PadBreakpoints files-beside', () {
    test('splits at 700dp content width', () {
      expect(PadBreakpoints.canShowFilesBeside(699), isFalse);
      expect(PadBreakpoints.canShowFilesBeside(700), isTrue);
      expect(PadBreakpoints.canShowFilesBeside(1200), isTrue);
    });

    test('host split breakpoint is unchanged', () {
      expect(PadBreakpoints.isSplit(const BoxConstraints(maxWidth: 599)), isFalse);
      expect(PadBreakpoints.isSplit(const BoxConstraints(maxWidth: 600)), isTrue);
    });

    test('clampFilesPaneWidth respects min, max fraction, and terminal floor', () {
      expect(PadBreakpoints.clampFilesPaneWidth(100, 1000),
          PadBreakpoints.filesPaneMin);
      expect(PadBreakpoints.clampFilesPaneWidth(340, 1000), 340);
      final maxed = PadBreakpoints.clampFilesPaneWidth(800, 1000);
      expect(maxed, lessThanOrEqualTo(1000 * PadBreakpoints.filesPaneMaxFraction));
      expect(maxed, lessThanOrEqualTo(1000 - PadBreakpoints.terminalMin));
    });
  });

  group('FilesPaneController', () {
    test('toggle and visibility respect breakpoint', () {
      final c = FilesPaneController();
      expect(c.open, isFalse);
      expect(c.isVisibleAt(1200), isFalse);
      c.toggle();
      expect(c.open, isTrue);
      expect(c.isVisibleAt(1200), isTrue);
      expect(c.isVisibleAt(500), isFalse);
      c.setOpen(false);
      expect(c.open, isFalse);
    });

    test('setWidth clamps and persist/load round-trips', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = FilesPaneController();
      c.setOpen(true);
      c.setWidth(900, 1000);
      expect(c.width, lessThanOrEqualTo(500));
      await c.persistTo(prefs);

      final loaded = FilesPaneController();
      loaded.loadFrom(prefs);
      expect(loaded.open, isTrue);
      expect(loaded.width, c.width);
    });
  });

  group('SessionManager SFTP reuse', () {
    late SessionManager mgr;
    final profile = HostProfile(
      id: 'h1',
      name: 'lab',
      protocol: HostProtocol.ssh,
      host: '10.0.0.1',
      username: 'root',
    );

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      mgr = SessionManager(KeepAliveController(prefs));
    });

    tearDown(() => mgr.dispose());

    test('openFiles reuses a live file session for the same host', () async {
      final backend = _FakeBackend();
      final session = FileBrowserSession(
        id: 'file_existing',
        profile: profile.asSftp(),
        backend: backend,
      );
      session.phase = SessionPhase.connected;
      mgr.addFileForTest(session);

      final again = await mgr.openFiles(profile);
      expect(identical(again, session), isTrue);
      expect(again.id, 'file_existing');
      expect(mgr.files, hasLength(1));
      expect(backend.connects, 0);
    });

    test('fileSessionForHost prefers connected session and shares profile id', () {
      final live = FileBrowserSession(
        id: 'file_live',
        profile: profile.asSftp(),
        backend: _FakeBackend(),
      )..phase = SessionPhase.connected;
      final stale = FileBrowserSession(
        id: 'file_stale',
        profile: profile.asSftp(),
        backend: _FakeBackend(),
      )..phase = SessionPhase.disconnected;
      mgr.addFileForTest(stale);
      mgr.addFileForTest(live);
      expect(mgr.fileSessionForHost('h1')?.id, 'file_live');
      expect(profile.asSftp().id, profile.id);
    });

    test('file sessions for different hosts stay independent', () {
      final first = FileBrowserSession(
        id: 'file_a',
        profile: profile.asSftp(),
        backend: _FakeBackend(),
      )..phase = SessionPhase.connected;
      final second = FileBrowserSession(
        id: 'file_b',
        profile: HostProfile(
          id: 'h2',
          name: 'other',
          protocol: HostProtocol.sftp,
          host: '10.0.0.2',
        ),
        backend: _FakeBackend(),
      )..phase = SessionPhase.connected;
      mgr.addFileForTest(first);
      mgr.addFileForTest(second);
      expect(mgr.fileSessionForHost('h1')?.id, 'file_a');
      expect(mgr.fileSessionForHost('h2')?.id, 'file_b');
      expect(mgr.files, hasLength(2));
    });
  });

  testWidgets('FilesBesideSplit lays out terminal and files', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FilesBesideSplit(
            contentWidth: 1000,
            paneWidth: 340,
            terminal: ColoredBox(
              color: Colors.black,
              child: Text('term-pane'),
            ),
            files: ColoredBox(
              color: Colors.white,
              child: Text('files-pane'),
            ),
            onPaneDrag: _noop,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('files-beside-pane')), findsNothing);
    // The split itself has no default key unless the caller sets one.
    expect(find.text('term-pane'), findsOneWidget);
    expect(find.text('files-pane'), findsOneWidget);
    final filesBox = tester.getSize(find.text('files-pane'));
    expect(filesBox.width, lessThan(500));
  });
}

void _noop(double _) {}
