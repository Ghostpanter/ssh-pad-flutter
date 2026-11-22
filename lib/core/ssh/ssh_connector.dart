import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../data/host_profile.dart';
import '../security/host_key_verifier.dart';
import '../session/session_log.dart';

/// Answers a keyboard-interactive challenge. Return null to refuse the method.
typedef KeyboardInteractiveHandler = Future<List<String>?> Function(
  HostProfile profile,
  SSHUserInfoRequest request,
);

/// Shared SSH connect + auth + TOFU host-key check for terminal and SFTP.
class SshConnector {
  /// Optional app-wide verifier (set from main / providers).
  static HostKeyVerifier? hostKeyVerifier;

  /// Optional UI prompt for keyboard-interactive (OTP, PAM). Null skips it.
  static KeyboardInteractiveHandler? keyboardInteractive;

  /// [via] is an already authenticated jump client. Each hop still verifies
  /// its own host key before any credential is sent.
  static Future<SSHClient> connect(
    HostProfile profile, {
    SSHClient? via,
  }) async {
    final jumped = via != null;
    sessionLog.add(
      jumped
          ? 'Connecting ${profile.protocol.label} ${profile.host}:${profile.port} via jump'
          : 'Connecting ${profile.protocol.label} ${profile.host}:${profile.port}',
    );

    final SSHSocket socket;
    if (via == null) {
      socket = await SSHSocket.connect(
        profile.host,
        profile.port,
        timeout: const Duration(seconds: 20),
      );
    } else {
      // direct-tcpip. localHost/localPort are originator fields, not a bind.
      socket = await via.forwardLocal(profile.host, profile.port);
    }

    List<SSHKeyPair>? identities;
    if (profile.auth == AuthMethod.key) {
      final pem = profile.privateKey?.trim();
      if (pem == null || pem.isEmpty) {
        throw StateError('Private key is empty');
      }
      identities = SSHKeyPair.fromPem(pem, profile.passphrase);
    }

    final interactive = keyboardInteractive;
    final verifier = hostKeyVerifier;
    final client = SSHClient(
      socket,
      username: profile.username.isEmpty ? 'root' : profile.username,
      identities: identities,
      onPasswordRequest: profile.auth == AuthMethod.keyboardInteractive
          ? null
          : profile.auth == AuthMethod.password
              ? () => profile.password ?? ''
              : (profile.passphrase != null && profile.passphrase!.isNotEmpty
                  ? () => profile.passphrase!
                  : null),
      onUserInfoRequest: interactive == null
          ? null
          : (request) => interactive(profile, request),
      keepAliveInterval: const Duration(seconds: 8),
      onVerifyHostKey: (type, fingerprint) async {
        if (verifier == null) {
          // Fail closed without a verifier in production paths.
          sessionLog.add(
            'Host key rejected: no verifier registered',
            level: SessionLogLevel.error,
          );
          return false;
        }
        final ok = await verifier.verify(
          host: profile.host,
          port: profile.port,
          keyType: type,
          fingerprintBytes: fingerprint,
        );
        if (ok) {
          sessionLog.add(
            'Host key OK ${profile.host}:${profile.port} '
            '${decodeHostKeyFingerprint(fingerprint)}',
          );
        } else {
          sessionLog.add(
            'Host key rejected ${profile.host}:${profile.port}',
            level: SessionLogLevel.warn,
          );
        }
        return ok;
      },
    );

    try {
      await client.authenticated;
    } catch (e) {
      sessionLog.add('Auth/connect failed: $e', level: SessionLogLevel.error);
      try {
        client.close();
      } catch (_) {}
      rethrow;
    }
    sessionLog.add('Authenticated ${profile.host}:${profile.port}');
    return client;
  }
}

/// Helper re-export for fingerprint display.
String fingerprintToString(Uint8List bytes) =>
    decodeHostKeyFingerprint(bytes);
