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

  test('public Download path and relative folder', () {
    expect(
      isPublicDownloadPath('/storage/emulated/0/Download'),
      isTrue,
    );
    expect(downloadRelativePath('/storage/emulated/0/Download'), 'Download/');
    expect(
      downloadRelativePath('/storage/emulated/0/Download/QuarkDownloads'),
      'Download/QuarkDownloads/',
    );
    expect(
      downloadRelativePath('/storage/emulated/0/Downloads'),
      'Downloads/',
    );
    expect(isPublicDownloadPath('/data/user/0/com.sshtab/files/SSHPad'), isFalse);
    expect(downloadRelativePath('/data/user/0/com.sshtab/files/SSHPad'), isNull);
  });

  test('mergeLocalEntries adds MediaStore files and keeps dirs', () {
    final io = [
      const LocalFsEntry(name: 'Browser', path: '/d/Browser', isDirectory: true),
      const LocalFsEntry(
        name: 'owned.txt',
        path: '/d/owned.txt',
        isDirectory: false,
        size: 3,
      ),
    ];
    final media = [
      const LocalFsEntry(
        name: 'owned.txt',
        path: '/d/owned.txt',
        isDirectory: false,
        size: 3,
        contentUri: 'content://media/1',
      ),
      const LocalFsEntry(
        name: 'app.apk',
        path: '/d/app.apk',
        isDirectory: false,
        size: 100,
        contentUri: 'content://media/2',
      ),
      const LocalFsEntry(
        name: 'Browser',
        path: '/d/Browser',
        isDirectory: false,
        contentUri: 'content://media/3',
      ),
      const LocalFsEntry(name: '.hidden', path: '/d/.hidden', isDirectory: false),
    ];
    final merged = mergeLocalEntries(io, media);
    final names = merged.map((e) => e.name).toList();
    expect(names.first, 'Browser');
    expect(merged.first.isDirectory, isTrue);
    expect(names, contains('app.apk'));
    expect(names, contains('owned.txt'));
    expect(names, isNot(contains('.hidden')));
    final owned = merged.firstWhere((e) => e.name == 'owned.txt');
    expect(owned.contentUri, 'content://media/1');
    expect(owned.path, '/d/owned.txt');
    final apk = merged.firstWhere((e) => e.name == 'app.apk');
    expect(apk.contentUri, 'content://media/2');
    expect(apk.size, 100);
  });
}
