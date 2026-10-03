import 'dart:io';

import 'package:flutter/services.dart';

import 'local_fs_listing.dart';

/// Android MethodChannel for MediaStore downloads + SAF trees.
class LocalStorageChannel {
  const LocalStorageChannel();

  static const MethodChannel _ch = MethodChannel(
    'com.sshtab.ssh_pad_flutter/storage',
  );

  Future<List<LocalFsEntry>> listDownloadFiles(String directory) async {
    if (!Platform.isAndroid) return const [];
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('listDownloadFiles', {
        'directory': directory,
      });
      return _parseList(raw);
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Persistable [ACTION_OPEN_DOCUMENT_TREE]. Null if the user cancels.
  Future<SafTreeGrant?> openDocumentTree() async {
    if (!Platform.isAndroid) return null;
    final raw = await _ch.invokeMethod<dynamic>('openDocumentTree');
    if (raw is! Map) return null;
    final tree = raw['treeUri'] as String?;
    if (tree == null || tree.isEmpty) return null;
    final name = (raw['name'] as String?)?.trim();
    final display = (raw['displayPath'] as String?)?.trim();
    return SafTreeGrant(
      treeUri: tree,
      name: (name == null || name.isEmpty) ? 'folder' : name,
      displayPath: (display == null || display.isEmpty)
          ? (name ?? 'folder')
          : display,
    );
  }

  Future<List<LocalFsEntry>> listSafChildren({
    required String treeUri,
    String? documentUri,
  }) async {
    final raw = await _ch.invokeMethod<List<dynamic>>('listSafChildren', {
      'treeUri': treeUri,
      'documentUri': documentUri,
    });
    return _parseList(raw);
  }

  /// Copy [contentUri] via ContentResolver into app cache. Returns cache path.
  Future<String> readContentUri(String contentUri) async {
    final path = await _ch.invokeMethod<String>('readContentUri', {
      'uri': contentUri,
    });
    if (path == null || path.isEmpty) {
      throw StateError('无法读取文件');
    }
    return path;
  }

  Future<void> writeSafFile({
    required String treeUri,
    String? parentDocumentUri,
    required String name,
    required String sourcePath,
  }) async {
    await _ch.invokeMethod<dynamic>('writeSafFile', {
      'treeUri': treeUri,
      'parentDocumentUri': parentDocumentUri,
      'name': name,
      'sourcePath': sourcePath,
    });
  }

  List<LocalFsEntry> _parseList(List<dynamic>? raw) {
    if (raw == null) return const [];
    final out = <LocalFsEntry>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final name = item['name'] as String? ?? '';
      if (name.isEmpty) continue;
      final size = item['size'];
      out.add(
        LocalFsEntry(
          name: name,
          path: item['path'] as String? ?? '',
          isDirectory: item['isDirectory'] == true,
          size: size is num ? size.toInt() : null,
          contentUri: item['contentUri'] as String?,
          documentUri: item['documentUri'] as String?,
        ),
      );
    }
    return out;
  }
}

class SafTreeGrant {
  const SafTreeGrant({
    required this.treeUri,
    required this.name,
    required this.displayPath,
  });

  final String treeUri;
  final String name;
  final String displayPath;
}
