import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../data/host_profile.dart';
import '../session/file_backend.dart';
import '../ssh/ssh_connection_hub.dart';
import '../ssh/ssh_connector.dart';

/// OpenSSH `DEFAULT_NUM_REQUESTS` is 64. dartssh2's [SftpFile.read] and
/// [SftpFile.writeBytes] default to 16 KiB packets; its own fast download
/// path uses 64 KiB. That is the bulk-copy window a Go sftp client gets
/// from a larger packet plus a bounded pipeline, without holding more than
/// one file in memory beyond what the caller already asked for.
const int kSftpChunkSize = 64 * 1024;
const int kSftpMaxPending = 64;

/// SFTP via dartssh2 [SftpClient].
///
/// Prefer a [SshConnectionHub] so Files attaches to an existing SSH session
/// (`client.sftp()`) instead of opening a second TCP+auth. Without a hub
/// (tests / edge), falls back to a dedicated [SshConnector] connection.
class SftpFileBackend implements FileBackend {
  SftpFileBackend(
    this.profile, {
    this._hub,
  });

  final HostProfile profile;
  final SshConnectionHub? _hub;

  SftpClient? _sftp;
  String _cwd = '.';
  bool _retained = false;
  /// Owned client when connected without a hub (must close on disconnect).
  SSHClient? _ownedClient;

  @override
  String get currentPath => _cwd;

  @override
  Future<void> connect() async {
    final hub = _hub;
    late final SSHClient client;
    try {
      if (hub != null) {
        client = await hub.ensureClient(profile);
        hub.retainSftp(profile.id);
        _retained = true;
      } else {
        client = await SshConnector.connect(profile);
        _ownedClient = client;
      }

      _sftp = await client.sftp();
      try {
        _cwd = await _sftp!.absolute('.');
      } catch (_) {
        _cwd = '/';
      }
    } catch (_) {
      await disconnect();
      rethrow;
    }
  }

  @override
  Future<List<RemoteFileEntry>> list([String? path]) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('SFTP not connected');
    final target = path ?? _cwd;
    final names = await sftp.listdir(target);
    final entries = <RemoteFileEntry>[];
    for (final n in names) {
      if (n.filename == '.' || n.filename == '..') continue;
      entries.add(
        RemoteFileEntry(
          name: n.filename,
          isDirectory: n.attr.isDirectory,
          size: n.attr.size,
          modified: n.attr.modifyTime != null
              ? DateTime.fromMillisecondsSinceEpoch(
                  n.attr.modifyTime! * 1000,
                )
              : null,
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    if (path != null) _cwd = path;
    return entries;
  }

  @override
  Future<void> changeDirectory(String path) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('SFTP not connected');
    String next;
    if (path == '..') {
      final abs = await sftp.absolute(_cwd);
      final idx = abs.lastIndexOf('/');
      next = idx <= 0 ? '/' : abs.substring(0, idx);
      if (next.isEmpty) next = '/';
    } else if (path.startsWith('/')) {
      next = path;
    } else {
      next = _cwd.endsWith('/') ? '$_cwd$path' : '$_cwd/$path';
    }
    final st = await sftp.stat(next);
    if (!st.isDirectory) {
      throw StateError('Not a directory: $next');
    }
    _cwd = await sftp.absolute(next);
  }

  @override
  Future<void> mkdir(String name) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('SFTP not connected');
    final path = _cwd.endsWith('/') ? '$_cwd$name' : '$_cwd/$name';
    await sftp.mkdir(path);
  }

  @override
  Future<void> delete(RemoteFileEntry entry) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('SFTP not connected');
    final path =
        _cwd.endsWith('/') ? '$_cwd${entry.name}' : '$_cwd/${entry.name}';
    if (entry.isDirectory) {
      await sftp.rmdir(path);
    } else {
      await sftp.remove(path);
    }
  }

  @override
  Future<void> upload(String remoteName, Uint8List bytes) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('SFTP not connected');
    final path =
        _cwd.endsWith('/') ? '$_cwd$remoteName' : '$_cwd/$remoteName';
    final file = await sftp.open(
      path,
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    try {
      await file.writeBytes(
        bytes,
        chunkSize: kSftpChunkSize,
        maxPendingRequests: kSftpMaxPending,
      );
    } finally {
      await file.close();
    }
  }

  @override
  Future<Uint8List> download(String remoteName) async {
    final sftp = _sftp;
    if (sftp == null) throw StateError('SFTP not connected');
    final path =
        _cwd.endsWith('/') ? '$_cwd$remoteName' : '$_cwd/$remoteName';
    final file = await sftp.open(path, mode: SftpFileOpenMode.read);
    try {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.read(
        chunkSize: kSftpChunkSize,
        maxPendingRequests: kSftpMaxPending,
      )) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> disconnect() async {
    _sftp = null;
    if (_retained) {
      _retained = false;
      await _hub?.releaseSftp(profile.id);
    }
    final owned = _ownedClient;
    _ownedClient = null;
    if (owned != null) {
      try {
        owned.close();
      } catch (_) {}
    }
  }
}
