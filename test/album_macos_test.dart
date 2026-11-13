import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumaberth/src/backup.dart';
import 'package:lumaberth/src/catalog.dart';
import 'package:lumaberth/src/store.dart';

import 'backup_test.dart' show Remote, TestBackup;

/// Mirrors the macOS Photos implementation: one virtual volume whose generation
/// is the newest asset modification time in milliseconds.
class FakePhotosLibrary {
  final assets = <Json>[
    {'source': 'A/L0/001', 'name': 'IMG_0001.HEIC', 'size': 100, 'time': 1000},
    {'source': 'B/L0/001', 'name': 'IMG_0002.jpg', 'size': 200, 'time': 2000},
  ];
  int generation = 2000;

  Json snapshot() => {
    'photos': {'version': 'photos', 'generation': generation},
  };

  List<Json> scan(Map<dynamic, dynamic> windows) {
    final bounds = (windows['photos'] as List).cast<String>();
    final floor = int.parse(bounds[0]);
    final previous = int.parse(bounds[1]);
    final current = int.parse(bounds[2]);
    final lower = floor > previous ? floor : previous;
    return assets
        .where((a) => (a['time'] as int) > lower && (a['time'] as int) <= current)
        .toList();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('macOS 相册：整库导入、增量发现与原件导出', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final library = FakePhotosLibrary();
    var prepares = 0;
    var thumbnails = 0;

    messenger.setMockMethodCallHandler(media, (call) async {
      switch (call.method) {
        case 'permission':
          return 'full';
        case 'snapshot':
          return library.snapshot();
        case 'scan':
          final arguments = (call.arguments as Map).cast<String, dynamic>();
          return library.scan(arguments['windows'] as Map);
        case 'thumbnail':
          thumbnails++;
          return null;
        case 'prepare':
          prepares++;
          final arguments = (call.arguments as Map).cast<String, dynamic>();
          await File(arguments['original'] as String).writeAsBytes(
            List.filled(2048, 7),
          );
          await File(arguments['thumb'] as String).writeAsBytes(
            List.filled(64, 8),
          );
          return 1699999999000;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(media, null));

    final dir = await Directory.systemTemp.createTemp('album-macos-');
    final remote = Remote();
    final store = await Store.open(directory: dir);
    addTearDown(() async {
      remote.transport.close();
      await store.close();
      await dir.delete(recursive: true);
    });

    // TestBackup pins the binding to repo 2 / user 1, so match those ids.
    await store.connect(
      {'id': 2, 'full_name': 'user/album', 'default_branch': 'main'},
      {'id': 1, 'login': 'user'},
      {'access_token': 'fixture'},
      'fixture',
    );
    final binding = await store.pref('binding') as Json;
    final target = binding['target'] as String;
    expect(target, '1-2');
    final engine = TestBackup(store, remote.transport);

    // 「同时备份已有照片」：opt-in 游标从 -1 开始，整库都符合条件。
    final snap = plainMap(await media.invokeMethod('snapshot'));
    final existing = await engine.changes(
      initialMediaCursor(snap, includeExisting: true),
      snap,
    );
    expect(existing.map((r) => r['name']), ['IMG_0001.HEIC', 'IMG_0002.jpg']);
    expect(existing.first['source'], 'A/L0/001');

    // 「从现在开始」：游标落在当前 generation 上，暂时没有新照片。
    final start = initialMediaCursor(snap, includeExisting: false);
    await store.set('auto:$target', advanceMediaCursor(start, snap));
    await engine.discover();
    expect(await store.jobs(target), isEmpty);

    // 相册新增一张照片后，只有它被入队。
    library.assets.add({
      'source': 'C/L0/001',
      'name': 'IMG_0003.HEIC',
      'size': 300,
      'time': 3000,
    });
    library.generation = 3000;
    await engine.discover();

    final jobs = await store.jobs(target);
    expect(jobs.length, 1);
    expect(jobs.single['name'], 'IMG_0003.HEIC');
    expect(jobs.single['stage'], '等待备份');

    // 再扫一次不重复入队。
    await engine.discover();
    expect((await store.jobs(target)).length, 1);

    // 相册来源走 prepare（导出原件 + 生成缩略图），不走桌面文件缩略图。
    await engine.backupOne(jobs.single);
    expect(prepares, 1);
    expect(thumbnails, 0);

    final photos = await store.photos(target);
    expect(photos.single['name'], 'IMG_0003.HEIC');
    expect(photos.single['size'], 2048);
    expect(photos.single['takenAt'], '2023-11-14T22:13:19.000Z');
  }, timeout: const Timeout(Duration(seconds: 90)));
}
