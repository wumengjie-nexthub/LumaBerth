import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumaberth/src/store.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('album-startup-');
  });
  tearDown(() => dir.delete(recursive: true));

  test('foreground can reopen and read while the backup worker holds a write transaction', () async {
    final worker = await Store.open(directory: dir);
    addTearDown(worker.close);
    await worker.enqueue('target', [
      {'source': 'content://photos/1', 'name': 'photo.png', 'size': 42},
    ]);
    await worker.db.transaction((txn) async {
      await txn.delete('jobs');
      final foreground = await Store.open(directory: dir);
      try {
        expect((await foreground.jobs('target')).single['name'], 'photo.png');
      } finally {
        await foreground.close();
      }
    });
    expect(await worker.jobs('target'), isEmpty);
  });

  test(
    'upgrading an unversioned album preserves its device and pending queue',
    () async {
      final legacy = await Store.open(directory: dir);
      final device = await legacy.pref('device');
      await legacy.enqueue('target', [
        {'source': 'content://photos/2', 'name': 'pending.png', 'size': 5},
      ]);
      final job = (await legacy.jobs('target')).single;
      await legacy.db.execute('DROP TABLE staged_cleanup');
      await legacy.db.execute('PRAGMA user_version=0');
      await legacy.close();

      final upgraded = await Store.open(directory: dir);
      addTearDown(upgraded.close);
      expect(await upgraded.pref('device'), device);
      expect(await upgraded.jobs('target'), [job]);
      expect(await upgraded.db.query('staged_cleanup'), isEmpty);
      expect(await upgraded.db.getVersion(), 1);
    },
  );
}
