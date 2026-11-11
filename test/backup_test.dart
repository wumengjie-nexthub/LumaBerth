import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
        'default_branch': 'main',
      });
    }
    if (path.endsWith('/branches/main')) return response({'name': 'main'});
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
        bytes.remove(id);
        assets.removeWhere((v) => v['id'] == id);
        return http.Response('', 204);
      }
      downloads.add(id);
      return bytes[id] == null
          ? response({}, 404)
          : http.Response.bytes(bytes[id]!, 200);
    }
    if (path.contains('/contents/')) {
      if (request.method == 'GET') {
        return indexes.containsKey(path)
            ? response({'content': indexes[path], 'sha': 'index-sha'})
            : response({}, 404);
      }
      if (request.method == 'DELETE') {
        indexes.remove(path);
        return response({});
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
    for (final role in ['original', 'jpg']) {
      await store.staged(job['id'], role).delete();
    }
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
