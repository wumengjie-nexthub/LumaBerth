import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lumaberth/src/backup.dart';
import 'package:lumaberth/src/catalog.dart';
import 'package:lumaberth/src/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const target = 'scan-test';
  late Directory dir;
  late Store store;
  late Backup backup;
  late http.Client client;
  late Json mounted;
  Json volume(int generation) => {'version': 'v1', 'generation': generation};
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('media-scan-');
    store = await Store.open(directory: dir);
    client = http.Client();
    backup = Backup(store, {'target': target}, client);
    await store.db.execute(
      'CREATE TABLE images (volume TEXT, source TEXT, '
      'generation_added INTEGER, generation_modified INTEGER, is_pending INTEGER, is_trashed INTEGER)',
    );
    messenger.setMockMethodCallHandler(media, (call) async {
      if (call.method == 'permission') return 'full';
      if (call.method == 'snapshot') return mounted;
      if (call.method != 'scan') throw StateError(call.method);
      final args = call.arguments as Map;
      final result = <Json>[];
      for (final w in (args['windows'] as Map).entries) {
        final rows = await store.db.query(
          'images',
          columns: ['source'],
          where: 'volume=? AND (${args['selection']})',
          whereArgs: [w.key, ...w.value],
        );
        result.addAll(rows);
      }
      return result;
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(media, null);
    await store.close();
    client.close();
    await dir.delete(recursive: true);
  });
  Future<void> add(
    String name,
    String volume,
    int added, {
    bool pending = false,
  }) => store.db.rawInsert('INSERT INTO images VALUES (?,?,?,?,?,0)', [
    volume,
    'content://media/$name',
    added,
    added,
    pending ? 1 : 0,
  ]);
  Future<List<String>> sources() async =>
      (await store.jobs(target)).map((j) => j['source'] as String).toList();
  Future<void> enable() async => store.set(
    'auto:$target',
    advanceMediaCursor(
      initialMediaCursor(mounted, includeExisting: false),
      mounted,
    ),
  );
  test('写入中的新照片发布后入队一次，编辑起点前的照片不会入队', () async {
    mounted = {'phone': volume(10)};
    await add('old', 'phone', 3);
    await enable();
    await add('new', 'phone', 11, pending: true);
    mounted = {'phone': volume(11)};
    await backup.discover();
    expect(await sources(), isEmpty);
    await store.db.execute(
      'UPDATE images SET is_pending=0,generation_modified=12',
    );
    mounted = {'phone': volume(12)};
    await backup.discover();
    expect(await sources(), ['content://media/new']);
    await store.db.execute('UPDATE images SET generation_modified=13');
    mounted = {'phone': volume(13)};
    await backup.discover();
    expect(await sources(), ['content://media/new']);
  });
  test('已有照片模式包含旧照片，也能在下一轮看到刚刚发布的照片', () async {
    mounted = {'phone': volume(10)};
    await add('old', 'phone', 0);
    await add('camera', 'phone', 9, pending: true);
    final start = initialMediaCursor(mounted, includeExisting: true);
    await store.enqueue(target, await backup.changes(start, mounted));
    await store.set('auto:$target', advanceMediaCursor(start, mounted));
    expect(await sources(), ['content://media/old']);
    await store.db.execute(
      'UPDATE images SET is_pending=0,generation_modified=11 WHERE is_pending=1',
    );
    mounted = {'phone': volume(11)};
    await backup.discover();
    expect(await sources(), ['content://media/old', 'content://media/camera']);
  });
}
