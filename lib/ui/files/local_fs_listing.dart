import 'dart:io';

/// Classified local filesystem entry for the dual-pane file browser.
class LocalFsEntry {
  const LocalFsEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int? size;
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
