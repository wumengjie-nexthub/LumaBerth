import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumaberth/src/backup.dart';
import 'package:lumaberth/src/catalog.dart';
import 'package:lumaberth/src/github.dart';
import 'package:lumaberth/src/store.dart';

class TestBackup extends Backup {
  TestBackup(Store store, http.Client transport)
    : testApi = Github(transport, () async => 'fixture-token'),
      super(store, {
        'target': '1-2',
        'repo': 2,
        'name': 'user/album',
        'branch': 'main',
      }, transport);
  final Github testApi;
  @override
  Future<String?> waiting() async => null;
  @override
  Github get github => testApi;
}

// In-memory GitHub responses for the exact endpoints the backup engine uses.
class Remote {
  final assets = <Json>[];
  final indexes = <String, String>{};
  final bytes = <int, List<int>>{};
  int uploads = 0, puts = 0, initialOccupancy = 0;
  final downloads = <int>[];
  final deletedAssets = <int>[];
  int? failDelete;
  String defaultBranch = 'main';
  bool loseUpload = false,
      loseCommit = false,
      failCommit = false,
      wrongDigest = false,
      omitDigest = false;
  late final http.Client transport = MockClient((request) async {
    final path = request.url.path;
    http.Response response(Object value, [int status = 200]) =>
        http.Response(jsonEncode(value), status);
    if (path == '/repositories/2') {
      return response({
        'id': 2,
        'private': true,
        'permissions': {'push': true},
        'full_name': 'user/album',
        'default_branch': defaultBranch,
      });
    }
    if (path.endsWith('/branches/$defaultBranch'))
      return response({'name': 'main'});
    if (path.endsWith('/commits/main')) {
      return response({
        'commit': {
          'tree': {'sha': 'root'},
        },
      });
    }
    if (path.contains('/git/trees/')) {
      final entries = <Json>[];
      final key = path.split('/').last;
      if (key == 'root') {
        entries.add({'type': 'tree', 'path': 'photo-album', 'sha': 'album'});
      }
      if (key == 'album') {
        entries.add({'type': 'tree', 'path': 'v1', 'sha': 'version'});
      }
      final shards = indexes.keys
          .map((v) => v.split('/').reversed.elementAt(1))
          .toSet();
      if (key == 'version') {
        entries.addAll(
          shards.map((s) => {'type': 'tree', 'path': s, 'sha': s}),
        );
      } else if (shards.contains(key)) {
        for (final entry in indexes.entries.where(
          (e) => e.key.contains('/$key/'),
        )) {
          entries.add({
            'type': 'blob',
            'path': entry.key.split('/').last,
            'sha': checksum(base64Decode(entry.value)),
          });
        }
      }
      return response({'tree': entries});
    }
    if (path.contains('/git/blobs/')) {
      final data = indexes.values.singleWhere(
        (v) => checksum(base64Decode(v)) == path.split('/').last,
      );
      return response({'content': data});
    }
    if (path.contains('/releases/tags/')) {
      return response({'id': path.endsWith('-1') ? 10 : 11});
    }
    if (path.endsWith("/releases/10/assets") ||
        path.endsWith("/releases/11/assets")) {
      final group = int.parse(path.split('/').reversed.elementAt(1));
      if (request.method == 'GET') {
        final page = int.parse(request.url.queryParameters['page']!);
        final existing = [
          if (group == 10)
            for (var i = 0; i < initialOccupancy; i++)
              {'name': 'other-$i', 'id': 1000 + i},
          ...assets.where((asset) => asset['group'] == group),
        ];
        return response(existing.skip((page - 1) * 100).take(100).toList());
      }
      uploads++;
      final id = 100 + uploads;
      bytes[id] = request.bodyBytes;
      final asset = {
        'group': group,
        'id': id,
        'name': request.url.queryParameters['name'],
        'size': request.bodyBytes.length,
        'state': 'uploaded',
        if (!omitDigest)
          'digest':
              'sha256:${wrongDigest ? '0' * 64 : checksum(request.bodyBytes)}',
      };
      assets.add(asset);
      if (loseUpload) {
        loseUpload = false;
        throw http.ClientException('模拟丢失上传响应');
      }
      return response(asset, 201);
    }
    if (path.contains('/releases/assets/')) {
      final id = int.parse(path.split('/').last);
      if (request.method == 'DELETE') {
        deletedAssets.add(id);
        if (id == failDelete) return response({}, 503);
        bytes.remove(id);
        assets.removeWhere((v) => v['id'] == id);
        return http.Response('', 204);
      }
      if (request.headers['accept'] != 'application/octet-stream') {
        final asset = assets.where((a) => a['id'] == id).firstOrNull;
        return asset == null ? response({}, 404) : response(asset);
      }
      downloads.add(id);
      return bytes[id] == null
          ? response({}, 404)
          : http.Response.bytes(bytes[id]!, 200);
    }
    if (path.contains('/contents/')) {
      final blob = indexes[path];
      final indexSha = blob == null ? null : checksum(base64Decode(blob));
      if (request.method == 'GET') {
        return indexes.containsKey(path)
            ? response({'content': indexes[path], 'sha': indexSha})
            : response({}, 404);
      }
      if (request.method == 'DELETE') {
        indexes.remove(path);
        return response({});
      }
      final update = jsonDecode(request.body) as Json;
      if (update['sha'] != indexSha) {
        return response({}, 422);
      }
      puts++;
      if (failCommit) return response({}, 503);
      indexes[path] = jsonDecode(request.body)['content'];
      if (loseCommit) throw http.ClientException('模拟目录提交响应丢失');
      return response({}, 201);
    }
    throw StateError('意外的请求 ${request.method} $path');
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Store store;
  late Remote remote;
  late TestBackup engine;
  late Json job;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('photo-album-test-');
    store = await Store.open(directory: dir);
    await store.set('device', 'test-device');
    await store.enqueue('1-2', [
      {'name': '旅行.heic', 'source': 'gone', 'size': 3},
    ]);
    job = (await store.jobs('1-2')).single;
    final source = store.staged(job['id'], 'original');
    final thumb = store.staged(job['id'], 'jpg');
    await source.writeAsBytes([1, 2, 3]);
    await thumb.writeAsBytes([4, 5]);
    job.addAll({
      'sha256': await fileHash(source),
      'thumbSize': 2,
      'thumbHash': await fileHash(thumb),
      'takenAt': '2026-11-11T00:00:00.000Z',
    });
    await store.checkpoint(job, '待校验原图');
    remote = Remote();
    engine = TestBackup(store, remote.transport);
  });
  tearDown(() async {
    remote.transport.close();
    await store.db.close();
    await store.workLock.close();
    await store.tokenLock.close();
    await dir.delete(recursive: true);
  });
  test('上传响应丢失后复用稳定附件，同批次目录回读确认', () async {
    remote.loseUpload = true;
    remote.loseCommit = true;
    remote.omitDigest = true;
    await expectLater(
      engine.backupOne(job),
      throwsA(isA<http.ClientException>()),
    );
    expect(await store.photos('1-2'), isEmpty);
    await engine.backupOne((await store.jobs('1-2')).single);
    expect(remote.uploads, 2);
    expect(remote.puts, 1);
    expect((await store.jobs('1-2')).single['stage'], '已备份');
    final photo = (await store.photos('1-2')).single;
    expect(photo['name'], '旅行.heic');
    expect(photo['original'], 101);
    expect(photo['thumbnail'], 102);
    final recovered = await engine.download(photo, thumbnail: false);
    expect(await recovered.readAsBytes(), [1, 2, 3]);
  });
  test('同大小、错误摘要不会生成目录或完成状态', () async {
    remote.wrongDigest = true;
    await expectLater(engine.backupOne(job), throwsStateError);
    expect(remote.puts, 0);
    expect(await store.photos('1-2'), isEmpty);
    expect((await store.jobs('1-2')).single['stage'], '待校验原图');
  });
  test('目录失败后删除本机原片仍能单独补写，导出检查下载内容', () async {
    remote.failCommit = true;
    await expectLater(engine.backupOne(job), throwsA(isA<ApiError>()));
    final saved = (await store.jobs('1-2')).single;
    expect(saved['stage'], '待写入目录');
    expect(remote.assets.length, 2);
    await store.stagedOriginal(job).delete();
    await store.staged(job['id'], 'jpg').delete();
    remote.failCommit = false;
    await engine.backupOne(saved);
    expect(remote.uploads, 2);
    final photo = (await store.photos('1-2')).single;
    remote.bytes[101] = [3, 2, 1];
    await expectLater(
      engine.download(photo, thumbnail: false),
      throwsStateError,
    );
  });

  test('本地清理失败仍完成备份，下轮只重试清理', () async {
    remote.failCommit = true;
    await expectLater(engine.backupOne(job), throwsA(isA<ApiError>()));
    remote.failCommit = false;
    final original = store.stagedOriginal(job);
    await original.delete();
    // A directory occupying the file path makes file deletion fail on both platforms.
    final occupied = await Directory(original.path).create();
    expect(await engine.run(), true);
    expect((await store.jobs('1-2')).single['stage'], '已备份');
    expect(await store.db.query('staged_cleanup'), hasLength(1));
    final puts = remote.puts;
    await occupied.delete();
    expect(await engine.run(), true);
    expect(await store.db.query('staged_cleanup'), isEmpty);
    expect(remote.puts, puts);
    expect(remote.uploads, 2);
  });

  test('Windows 覆盖原路径后从所选快照读取拍摄时间', () async {
    final file = File('${dir.path}/camera.jpg');
    await file.writeAsBytes([1]);
    await store.enqueue('1-2', [
      {'source': file.path, 'name': 'camera.jpg', 'size': 1},
    ]);
    await file.writeAsBytes([2]);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(media, (call) async {
      final metadata = File(call.arguments['metadata']);
      expect(metadata.path, endsWith('.jpg'));
      await File(call.arguments['thumb']).writeAsBytes([3]);
      return DateTime.utc(
        (await metadata.readAsBytes()).single == 1 ? 2001 : 2025,
      ).millisecondsSinceEpoch;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(media, null));
    await engine.backupOne((await store.jobs('1-2')).last);
    expect(
      (await store.photos('1-2')).single['takenAt'],
      DateTime.utc(2001).toIso8601String(),
    );
    expect(remote.bytes[101], [1]);
  });

  test('Windows 同名同大小文件覆盖后再选，两份内容各入队一次', () async {
    final file = File('${dir.path}/same.jpg');
    final input = {
      'name': 'same.jpg',
      'source': file.path,
      'size': 3,
      'time': 1,
    };
    await file.writeAsBytes([1, 2, 3]);
    await store.enqueue('1-2', [input]);
    await file.writeAsBytes([3, 2, 1]);
    await Future.wait([
      store.enqueue('1-2', [input]),
      store.enqueue('1-2', [input]),
    ]);
    final versions = (await store.jobs('1-2'))
        .where((j) => j['source'] == file.path)
        .toList();
    expect(versions, hasLength(2));
    expect(await store.staged(versions[0]['id'], 'original').readAsBytes(), [
      1,
      2,
      3,
    ]);
    expect(await store.staged(versions[1]['id'], 'original').readAsBytes(), [
      3,
      2,
      1,
    ]);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(media, (MethodCall call) async {
      await File(call.arguments['thumb']).writeAsBytes([4, 5]);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(media, null));
    await file.delete();
    for (final version in versions) {
      await engine.backupOne(version);
    }
    expect(remote.bytes[101], [1, 2, 3]);
    expect(remote.bytes[103], [3, 2, 1]);
  });

  test('旧版已完成队列仍去重，覆盖为新内容后能再次入队', () async {
    final file = File('${dir.path}/legacy.jpg');
    await file.writeAsBytes([1, 2, 3]);
    final input = {'name': 'legacy.jpg', 'source': file.path, 'size': 3};
    await store.db.insert('jobs', {
      'id': 'legacy',
      'target': '1-2',
      'source': file.path,
      'stage': '已备份',
      'data': jsonEncode({
        ...input,
        'id': 'legacy',
        'sha256': await fileHash(file),
      }),
    });
    await store.enqueue('1-2', [input]);
    expect(
      (await store.jobs('1-2')).where((j) => j['source'] == file.path),
      hasLength(1),
    );
    await file.writeAsBytes([3, 2, 1]);
    await store.enqueue('1-2', [input]);
    final versions = (await store.jobs('1-2'))
        .where((j) => j['source'] == file.path);
    expect(versions.map((j) => j['stage']), ['已备份', '等待备份']);
  });

  test('目录已提交而本机未收尾，另一台设备删除后重试不能恢复目录', () async {
    // Save the checkpoint the first device would recover after a crash.
    await engine.backupOne(job);
    final saved = jsonDecode(
      (await store.db.query('jobs')).single['data'] as String,
    ) as Json;
    await store.checkpoint(saved, '待写入目录');
    final otherStore = await Store.open(
      directory: Directory('${dir.path}/other'),
    );
    try {
      final other = TestBackup(otherStore, remote.transport);
      await other.refresh();
      await other.requestRemoval((await otherStore.photos('1-2')).single);
      await other.run();
      expect(remote.assets, isEmpty);
      await engine.run();
      await other.refresh();
      expect(await otherStore.photos('1-2'), isEmpty);
      expect(await store.photos('1-2'), isEmpty);
      expect(
        (await store.jobs('1-2')).where((j) => j['stage'] == '已备份'),
        isEmpty,
      );
      expect(remote.uploads, 2);
    } finally {
      await otherStore.close();
    }
  });

  test('删除已写入目录但附件清理失败，旧任务停止，重新运行可清完附件', () async {
    await engine.backupOne(job);
    final pending = jsonDecode(
      (await store.db.query('jobs')).single['data'] as String,
    ) as Json;
    await store.checkpoint(pending, '待写入目录');
    final otherStore = await Store.open(
      directory: Directory('${dir.path}/other'),
    );
    try {
      final other = TestBackup(otherStore, remote.transport);
      await other.refresh();
      final photo = (await otherStore.photos('1-2')).single;
      await other.requestRemoval(photo);
      remote.failDelete = photo['thumbnail'];
      expect(await other.run(), isFalse);
      expect(remote.assets, hasLength(2));
      await engine.run();
      expect(await store.photos('1-2'), isEmpty);
      expect(await store.jobs('1-2'), isEmpty);
      remote.failDelete = null;
      await other.run();
      expect(remote.assets, isEmpty);
      expect(await otherStore.db.query('removals'), isEmpty);
    } finally {
      await otherStore.close();
    }
  });

  test('兼容旧端物理删除目录，任一已确认附件缺失均不能补写', () async {
    remote.failCommit = true;
    await expectLater(engine.backupOne(job), throwsA(isA<ApiError>()));
    final saved = (await store.jobs('1-2')).single;
    remote.failCommit = false;
    final originals = List<Json>.of(remote.assets);
    for (final role in ['original', 'thumbnail']) {
      remote.assets
        ..clear()
        ..addAll(originals.where((a) => a['id'] != saved[role]));
      await expectLater(engine.backupOne(saved), throwsA(isA<ApiError>()));
      expect(remote.indexes, isEmpty);
      expect(await store.photos('1-2'), isEmpty);
    }
  });

  test('确认删除后默认分支变化时保留原附件和请求', () async {
    await engine.backupOne(job);
    final photo = (await store.photos('1-2')).single;
    await engine.requestRemoval(photo);
    final puts = remote.puts;
    remote.defaultBranch = 'next';
    await engine.run();
    expect(remote.puts, puts);
    expect(remote.deletedAssets, isEmpty);
    final held = jsonDecode(
      (await store.db.query('removals')).single['data'] as String,
    );
    expect(held['branch'], 'main');
    expect(held['confirmAgain'], true);
    expect(
      await (await engine.download(photo, thumbnail: false)).readAsBytes(),
      [1, 2, 3],
    );
  });

  test('单条删除冲突保留远端文件，同轮继续备份，刷新重选后可删除', () async {
    final old = {
      ...job,
      'id': '55555555-5555-4555-8555-555555555555',
      'original': 701,
      'thumbnail': 702,
    };
    final path = indexPath(old['id']);
    final updated = {...old, 'thumbnail': 703};
    remote.indexes['${engine.root}/contents/$path'] = base64Encode(
      utf8.encode(encodeIndex(updated)),
    );
    await engine.requestRemoval({...old, 'path': path});
    await engine.run();
    expect((await store.jobs('1-2')).single['stage'], '已备份');
    expect(
      remote.indexes['${engine.root}/contents/$path'],
      base64Encode(utf8.encode(encodeIndex(updated))),
    );
    final held = jsonDecode(
      (await store.db.query('removals')).single['data'] as String,
    );
    expect(held['confirmAgain'], true);
    await engine.run();
    expect(remote.deletedAssets, isEmpty);
    await engine.refresh();
    await engine.requestRemoval(
      (await store.photos('1-2')).singleWhere((p) => p['id'] == old['id']),
    );
    await engine.run();
    expect(await store.db.query('removals'), isEmpty);
    expect(remote.deletedAssets, [703, 701]);
    expect((await store.photos('1-2')).map((p) => p['id']), [job['id']]);
  });
  for (final physical in [false, true]) {
    test('另一设备删除后，刷新允许同一原片重新备份（旧端物理删除：$physical）', () async {
      final file = File('${dir.path}/original.jpg');
      await file.writeAsBytes([1, 2, 3]);
      final input = {'source': file.path, 'name': 'original.jpg', 'size': 3};
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(media, (call) async {
        await File(call.arguments['thumb']).writeAsBytes([4, 5]);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(media, null));
      await store.enqueue('1-2', [input]);
      Future<List<Json>> versions() async =>
          (await store.jobs('1-2'))
              .where((j) => j['source'] == file.path)
              .toList();
      final first = (await versions()).single;
      await engine.backupOne(first);
      final otherStore = await Store.open(
        directory: Directory('${dir.path}/other'),
      );
      try {
        final other = TestBackup(otherStore, remote.transport);
        await other.refresh();
        await other.requestRemoval((await otherStore.photos('1-2')).single);
        await other.run();
      } finally {
        await otherStore.close();
      }
      if (physical) {
        remote.indexes.clear();
      } else {
        // Older versions could cache the tombstone without retiring the completed job.
        final raw = base64Decode(remote.indexes.values.single);
        await store.db.update(
          'album',
          {'sha': checksum(raw), 'data': utf8.decode(raw)},
          where: 'target=? AND path=?',
          whereArgs: ['1-2', indexPath(first['id'])],
        );
      }
      await engine.refresh();
      expect(await versions(), isEmpty);
      expect(
        (await store.jobs('1-2')).single['id'],
        job['id'],
      ); // still pending
      await store.enqueue('1-2', [input]);
      final fresh = (await versions()).single;
      expect(fresh['id'], isNot(first['id']));
      await engine.backupOne(fresh);
      final photo = (await store.photos('1-2')).single;
      expect(photo['id'], fresh['id']);
      expect(remote.bytes[photo['original']], [1, 2, 3]);
    });
  }

  test('远端删除后自动扫描不能恢复旧 MediaStore 来源，手动重选仍然有效', () async {
    final input = {
      'source': 'content://media/external/images/media/12',
      'name': 'a.jpg',
    };
    await store.enqueue('1-2', [input], automatic: true);
    final row = (await store.jobs('1-2')).last;
    await store.checkpoint(row, '已备份');
    await engine.refresh(); // the confirmed directory contains no such photo
    await store.enqueue('1-2', [input], automatic: true);
    expect(
      (await store.jobs('1-2')).where((j) => j['source'] == input['source']),
      isEmpty,
    );
    await store.enqueue('1-2', [input]);
    expect((await store.jobs('1-2')).last['source'], input['source']);
  });

  test('刷新遇到坏目录时完整保留旧相册和去重记录，成功后同时切换', () async {
    await engine.backupOne(job);
    await engine.refresh();
    final photo = (await store.photos('1-2')).single;
    final original = await store.db.query('album');
    remote.indexes.clear();
    String key(String id) => '${engine.root}/contents/${indexPath(id)}';
    String encoded(String data) => base64Encode(utf8.encode(data));
    const b = '12000000-0000-4000-8000-000000000002';
    const c = '12000000-0000-4000-8000-000000000003';
    remote.indexes[key(b)] = encoded(encodeIndex({...photo, 'id': b}));
    remote.indexes[key(c)] = encoded('invalid');
    await expectLater(engine.refresh(), throwsFormatException);
    expect(await store.db.query('album'), original);
    expect((await store.jobs('1-2')).single['stage'], '已备份');
    remote.indexes[key(c)] = encoded(encodeIndex({...photo, 'id': c}));
    await engine.refresh();
    expect(
      (await store.photos('1-2')).map((p) => p['id']),
      unorderedEquals([b, c]),
    );
    expect(await store.jobs('1-2'), isEmpty);
  });

  test('旧目录中使用字符串的大小可显示并导出，负数拒绝刷新', () async {
    await engine.backupOne(job);
    final photo = (await store.photos('1-2')).single;
    final key = remote.indexes.keys.single;
    void setSize(dynamic size) {
      remote.indexes[key] = base64Encode(
        utf8.encode(encodeIndex({...photo, 'size': size})),
      );
    }

    setSize('3');
    await engine.refresh();
    final loaded = (await store.photos('1-2')).single;
    expect(loaded['size'], 3);
    expect(
      await (await engine.download(loaded, thumbnail: false)).readAsBytes(),
      [1, 2, 3],
    );
    setSize('-1');
    await expectLater(engine.refresh(), throwsFormatException);
    expect((await store.photos('1-2')).single['size'], 3);
  });

  test('缩略图缓存为空或解码失败后，可以重新下载替换', () async {
    await engine.backupOne(job);
    final photo = (await store.photos('1-2')).single;
    final cache = await engine.download(photo, thumbnail: true);
    await cache.writeAsBytes([]);
    expect(
      await (await engine.download(photo, thumbnail: true)).readAsBytes(),
      [4, 5],
    );
    await cache.writeAsBytes([0]);
    expect(
      await (await engine.download(
        photo,
        thumbnail: true,
        refreshThumbnail: true,
      )).readAsBytes(),
      [4, 5],
    );
    expect(remote.downloads, [102, 102, 102]);
    remote.bytes[102] = [];
    await expectLater(
      engine.download(photo, thumbnail: true, refreshThumbnail: true),
      throwsFormatException,
    );
    expect(await cache.readAsBytes(), [4, 5]);
  });

  test('普通照片按两个附件分组，空仓库 1200 张', () {
    final groups = <int>[0];
    for (var i = 0; i < 1200; i++) {
      if (!hasRoom(groups.last * 2)) groups.add(0);
      groups[groups.length - 1]++;
    }
    expect(groups, [500, 500, 200]);
    expect(hasRoom(999), false);
  });
  test('实际分页读取 999 个附件后把两个新附件放入下一组', () async {
    remote.initialOccupancy = 999;
    await engine.backupOne(job);
    expect(remote.assets.map((v) => v['group']), [11, 11]);
    expect((await store.photos('1-2')).length, 1);
  });
  test('跨账号或跨仓库的队列隔离，同名文件导出保留两份', () async {
    expect(await store.jobs('1-3'), isEmpty);
    expect(await store.jobs('2-2'), isEmpty);
    final source = store.staged(job['id'], 'original');
    await exportVerified(source, dir, '../test.heic');
    final second = await exportVerified(source, dir, 'test.heic');
    expect(second.path, endsWith('test (1).heic'));
    expect(await second.readAsBytes(), [1, 2, 3]);
    expect(exportName('CON.jpg'), '_CON.jpg');
  });
  test('空缓存设备从目录恢复，按需读取缩略图和原图，刷新反映已确认删除', () async {
    await engine.backupOne(job);
    final otherDir = Directory('${dir.path}/second-device');
    final otherStore = await Store.open(directory: otherDir);
    final other = TestBackup(otherStore, remote.transport);
    try {
      await other.refresh();
      final photo = (await otherStore.photos('1-2')).single;
      expect(remote.downloads, isEmpty);
      await other.download(photo, thumbnail: true);
      await other.download(photo, thumbnail: true);
      expect(remote.downloads, [102]);
      expect(
        await (await other.download(photo, thumbnail: false)).readAsBytes(),
        [1, 2, 3],
      );
      expect(remote.downloads, [102, 101]);
      await other.requestRemoval(photo);
      expect(remote.assets.length, 2);
      await other.run();
      expect(remote.assets, isEmpty);
      await engine.refresh();
      expect(await store.photos('1-2'), isEmpty);
    } finally {
      await otherStore.close();
    }
  });
  test('GitHub 限流按 Retry-After 延后', () async {
    final client = MockClient(
      (_) async => http.Response('{}', 429, headers: {'retry-after': '60'}),
    );
    final start = DateTime.now();
    await expectLater(
      Github(client, () async => 'test').json('GET', '/user'),
      throwsA(
        isA<ApiError>().having(
          (e) => e.retryAt!.difference(start).inSeconds,
          'delay',
          greaterThanOrEqualTo(60),
        ),
      ),
    );
    client.close();
  });
  test('拒绝公开仓库并在下载跳转时移除访问凭据', () async {
    final client = MockClient((r) async {
      if (r.url.path == '/repositories/2') {
        return http.Response('{"private":false,"id":2}', 200);
      }
      if (r.url.host == 'api.github.com') {
        return http.Response(
          '',
          302,
          headers: {'location': 'https://assets.example/file'},
        );
      }
      expect(r.headers.containsKey('authorization'), false);
      return http.Response.bytes([5], 200);
    });
    final api = Github(client, () async => 'fake');
    await expectLater(api.verify({'id': 2}), throwsStateError);
    expect(await (await api.assetStream('/repos/user/album', 6)).first, [5]);
    client.close();
  });
}
