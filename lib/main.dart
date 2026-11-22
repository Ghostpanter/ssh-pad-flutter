import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/keepalive/keepalive_controller.dart';
import 'core/status/host_status_monitor.dart';
import 'core/security/host_key_store.dart';
import 'core/security/host_key_verifier.dart';
import 'core/ssh/ssh_connector.dart';
import 'data/host_store.dart';
import 'ui/keyboard/app_escape_policy.dart';
import 'ui/keyboard/root_back_guard.dart';
import 'ui/pad/pad_shell.dart';
import 'ui/security/host_key_dialog.dart';
import 'ui/security/keyboard_auth_dialog.dart';
import 'ui/theme.dart';

final navigatorKey = GlobalKey<NavigatorState>();

final hostKeyStoreProvider = Provider<HostKeyStore>((ref) {
  return HostKeyStore(ref.watch(sharedPreferencesProvider));
});

final hostKeyVerifierProvider = Provider<HostKeyVerifier>((ref) {
  final verifier = HostKeyVerifier(ref.watch(hostKeyStoreProvider));
  SshConnector.hostKeyVerifier = verifier;
  return verifier;
});

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  AppEscapePolicy.bindNavigator(navigatorKey);
  AppEscapePolicy.install();
  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: const SshPadApp(),
    ),
  );
}

class SshPadApp extends ConsumerStatefulWidget {
  const SshPadApp({super.key});

  @override
  ConsumerState<SshPadApp> createState() => _SshPadAppState();
}

class _SshPadAppState extends ConsumerState<SshPadApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final verifier = ref.read(hostKeyVerifierProvider);
      verifier.promptHandler = (request) async {
        final ctx = navigatorKey.currentContext;
        if (ctx == null) return HostKeyDecision.reject;
        return showHostKeyDialog(ctx, request);
      };
      SshConnector.keyboardInteractive = (profile, request) async {
        final ctx = navigatorKey.currentContext;
        if (ctx == null) return null;
        return showKeyboardAuthDialog(ctx, profile, request);
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(keepAliveControllerProvider);
    ref.watch(hostStatusMonitorProvider);
    ref.watch(hostKeyVerifierProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp(
      title: 'SSH Pad',
      navigatorKey: navigatorKey,
      theme: AppThemes.light,
      darkTheme: AppThemes.dark,
      themeMode: themeMode,
      // Escape must never map to DismissIntent / Back at the app level.
      shortcuts: AppEscapePolicy.shortcutsWithoutEscapeBack(
        Map<ShortcutActivator, Intent>.of(WidgetsApp.defaultShortcuts),
      ),
      actions: AppEscapePolicy.actionsWithoutEscapeBack(
        Map<Type, Action<Intent>>.of(WidgetsApp.defaultActions),
      ),
      // Root Back/Esc remapped to BACK must not finish the Activity (OEM
      // tablets). Nested routes still pop normally; only the shell is guarded.
      home: RootBackGuard(
        navigatorKey: navigatorKey,
        child: const PadShell(),
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}

