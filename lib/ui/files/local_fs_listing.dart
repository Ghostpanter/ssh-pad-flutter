import 'dart:io';

/// Classified local filesystem entry for the dual-pane file browser.
class LocalFsEntry {
  const LocalFsEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size,
    this.contentUri,
    this.documentUri,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int? size;

  /// MediaStore or SAF content Uri. When set, upload must read via
  /// [readContentUri] instead of [File.readAsBytes] (scoped storage).
  final String? contentUri;

  /// SAF document Uri for a directory inside a granted tree.
  final String? documentUri;
}

/// Result of classifying a [FileSystemEntity] via [stat] (not `is File`).
class LocalEntityClass {
  const LocalEntityClass({
    required this.isDirectory,
    this.size,
    this.skipped = false,
  });

  final bool isDirectory;
  final int? size;
  final bool skipped;

  static const skippedEntry = LocalEntityClass(
    isDirectory: false,
    skipped: true,
  );
}

/// Pure classification from a [FileSystemEntityType] + optional length.
///
/// Used so unit tests can cover Android cases where `Directory.list()` yields
/// entities that are neither `File` nor `Directory` (generic / Link), which
/// previously caused files to be silently skipped.
LocalEntityClass classifyLocalEntityType(
  FileSystemEntityType type, {
  int? size,
}) {
  switch (type) {
    case FileSystemEntityType.directory:
      return const LocalEntityClass(isDirectory: true);
    case FileSystemEntityType.file:
      return LocalEntityClass(isDirectory: false, size: size);
    case FileSystemEntityType.link:
      // Caller should re-stat with followLinks: true; treat unresolved as skip.
      return LocalEntityClass.skippedEntry;
    case FileSystemEntityType.notFound:
    case FileSystemEntityType.unixDomainSock:
    case FileSystemEntityType.pipe:
      return LocalEntityClass.skippedEntry;
  }
  // Defensive: unknown future enum values.
  return LocalEntityClass.skippedEntry;
}

/// List [dirPath] including files and directories.
///
/// Uses [FileSystemEntity.type] / [stat] per entry with try/catch so one bad
/// file cannot empty the whole list. Length failures still show the file with
/// [LocalFsEntry.size] = null.
Future<List<LocalFsEntry>> listLocalDirectory(String dirPath) async {
  final dir = Directory(dirPath);
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }

  final entities = await dir.list(followLinks: false).toList();
  final entries = <LocalFsEntry>[];

  for (final e in entities) {
    try {
      final name = e.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.')) continue;

      FileSystemEntityType type;
      try {
        type = await FileSystemEntity.type(e.path, followLinks: true);
      } catch (_) {
        try {
          final st = await e.stat();
          type = st.type;
        } catch (_) {
          continue;
        }
      }

      if (type == FileSystemEntityType.directory) {
        entries.add(
          LocalFsEntry(name: name, path: e.path, isDirectory: true),
        );
        continue;
      }

      if (type == FileSystemEntityType.file) {
        int? len;
        try {
          len = await File(e.path).length();
        } catch (_) {
          try {
            final st = await e.stat();
            if (st.type == FileSystemEntityType.file) {
              len = st.size;
            }
          } catch (_) {
            len = null;
          }
        }
        entries.add(
          LocalFsEntry(
            name: name,
            path: e.path,
            isDirectory: false,
            size: len,
          ),
        );
        continue;
      }

      // Unresolved link / special node — skip.
    } catch (_) {
      // Per-entry isolation: never abort the whole listing.
      continue;
    }
  }

  entries.sort((a, b) {
    if (a.isDirectory != b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return entries;
}


/// Normalize separators and drop a trailing slash (except root).
String normalizeLocalPath(String path) {
  var n = path.replaceAll('\\', '/');
  if (n.length > 1 && n.endsWith('/')) {
    n = n.substring(0, n.length - 1);
  }
  return n;
}

final RegExp _publicDownload = RegExp(
  r'^/storage/emulated/\d+/(Download|Downloads)(?:/(.*))?$',
);

/// `Download/` or `Download/QuarkDownloads/` for a public downloads path.
///
/// Returns null when [path] is not under `/storage/emulated/N/Download(s)`.
String? downloadRelativePath(String path) {
  final n = normalizeLocalPath(path);
  final m = _publicDownload.firstMatch(n);
  if (m == null) return null;
  final root = m.group(1)!;
  final rest = (m.group(2) ?? '').replaceAll(RegExp(r'/+$'), '');
  if (rest.isEmpty) return '$root/';
  return '$root/$rest/';
}

/// True for public Download and its children (scoped-storage blind spot).
bool isPublicDownloadPath(String path) => downloadRelativePath(path) != null;

/// Merge dart:io entries with MediaStore/SAF rows.
///
/// Directories from [ioEntries] win. A file already listed by dart:io keeps
/// its path but adopts [extraEntries]' content Uri so upload can read it
/// under scoped storage. Names are deduped.
List<LocalFsEntry> mergeLocalEntries(
  List<LocalFsEntry> ioEntries,
  List<LocalFsEntry> extraEntries,
) {
  final byName = <String, LocalFsEntry>{};
  for (final e in ioEntries) {
    if (e.name.isEmpty || e.name.startsWith('.')) continue;
    byName[e.name] = e;
  }
  for (final m in extraEntries) {
    if (m.name.isEmpty || m.name.startsWith('.')) continue;
    final existing = byName[m.name];
    if (existing == null) {
      byName[m.name] = m;
      continue;
    }
    if (existing.isDirectory) continue;
    final uri = m.contentUri;
    if ((existing.contentUri == null || existing.contentUri!.isEmpty) &&
        uri != null &&
        uri.isNotEmpty) {
      byName[m.name] = LocalFsEntry(
        name: existing.name,
        path: existing.path.isNotEmpty ? existing.path : m.path,
        isDirectory: false,
        size: existing.size ?? m.size,
        contentUri: uri,
        documentUri: m.documentUri ?? existing.documentUri,
      );
    }
  }
  final list = byName.values.toList();
  list.sort((a, b) {
    if (a.isDirectory != b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return list;
}
