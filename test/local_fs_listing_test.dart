import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_pad_flutter/ui/files/local_fs_listing.dart';

void main() {
  test('classifyLocalEntityType: directory and file', () {
    expect(
      classifyLocalEntityType(FileSystemEntityType.directory).isDirectory,
      isTrue,
    );
    expect(
      classifyLocalEntityType(FileSystemEntityType.directory).skipped,
      isFalse,
    );

    final file = classifyLocalEntityType(
      FileSystemEntityType.file,
      size: 42,
    );
    expect(file.isDirectory, isFalse);
    expect(file.size, 42);
    expect(file.skipped, isFalse);
  });

  test('classifyLocalEntityType: link / notFound skipped', () {
    expect(
      classifyLocalEntityType(FileSystemEntityType.link).skipped,
      isTrue,
    );
    expect(
      classifyLocalEntityType(FileSystemEntityType.notFound).skipped,
      isTrue,
    );
  });

  test('listLocalDirectory shows files and dirs (temp)', () async {
    final tmp = await Directory.systemTemp.createTemp('sshpad_local_');
    addTearDown(() => tmp.delete(recursive: true));

    await Directory('${tmp.path}/subdir').create();
    await File('${tmp.path}/hello.txt').writeAsString('hi');
    await File('${tmp.path}/.hidden').writeAsString('x');

    final entries = await listLocalDirectory(tmp.path);
    final names = entries.map((e) => e.name).toList();
    expect(names, containsAll(['subdir', 'hello.txt']));
    expect(names, isNot(contains('.hidden')));

    final file = entries.firstWhere((e) => e.name == 'hello.txt');
    expect(file.isDirectory, isFalse);
    expect(file.size, 2);

    final dir = entries.firstWhere((e) => e.name == 'subdir');
    expect(dir.isDirectory, isTrue);
  });

  test('listLocalDirectory survives length failure style paths', () async {
    // Empty existing dir still returns empty list, not error.
    final tmp = await Directory.systemTemp.createTemp('sshpad_empty_');
    addTearDown(() => tmp.delete(recursive: true));
    final entries = await listLocalDirectory(tmp.path);
    expect(entries, isEmpty);
  });
}
