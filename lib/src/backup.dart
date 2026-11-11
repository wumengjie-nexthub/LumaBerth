import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'catalog.dart';
import 'github.dart';
import 'store.dart';

const media = MethodChannel('photoalbum/media');
const dialogs = MethodChannel('photoalbum/dialogs');
const oneWay = '已备份的照片会保留在你的私有仓库。从手机相册删除照片，不会删除云端原图。请等照片显示「已备份」后，再清理本机原片。';
Json plainMap(dynamic value) => jsonDecode(jsonEncode(value)) as Json;
String readable(Object e) => e is PlatformException
    ? (e.message ?? e.code)
    : e.toString().replaceFirst('Bad state: ', '');

// Only mounted volumes advance. The floor is the user's original opt-in boundary.
Json advanceMediaCursor(Json previous, Json mounted) => {
  ...previous,
  for (final v in mounted.entries)
    v.key: {
      ...v.value as Json,
      'floor':
          previous[v.key]?['floor'] ??
          previous[v.key]?['generation'] ??
          v.value['generation'],
    },
};

Json initialMediaCursor(Json mounted, {required bool includeExisting}) => {
  for (final v in mounted.entries)
    v.key: {
      'version': v.value['version'],
      'generation': includeExisting ? -1 : v.value['generation'],
    },
};

class Backup {
  Backup(this.store, this.binding, this.client);
  final Store store;
  final Json binding;
  final http.Client client;
  String get target => binding['target'];
  String get root => '/repos/${binding['name']}';
  String get branch => binding['branch'];
  late final github = Github(
    client,
    () => store.token(target, client),
    beforeWrite: _beforeWrite,
    uploadStops: () => Stream<int>.periodic(
      const Duration(seconds: 1),
      (n) => n,
    ).asyncMap((_) => waiting()).where((s) => s != null).cast<String>(),
  );
  Future<void> _beforeWrite() async {
    final delay =
        (await store.pref('writeAt') as int? ?? 0) +
        1050 -
        DateTime.now().millisecondsSinceEpoch;
    if (delay > 0) await Future<void>.delayed(Duration(milliseconds: delay));
    final reason = await waiting();
    if (reason != null) throw StateError(reason);
    final current = await github.json('GET', root);
    if (current['id'] != binding['repo'] || current['private'] != true) {
      throw StateError('仓库身份或可见性已改变，已停止写入');
    }
    await store.set('writeAt', DateTime.now().millisecondsSinceEpoch);
  }

  Future<String?> waiting() async {
    if ((await store.pref('binding'))?['target'] != target) return '已断开 GitHub';
    if (await store.pref('authRequired:$target') == true) return '请重新授权原仓库';
    if (await store.pref('paused:$target') == true) return '队列已暂停';
    final until = await store.pref('retry:$target') as int? ?? 0;
    if (DateTime.now().millisecondsSinceEpoch < until) return '稍后继续（GitHub 限流）';
    final network = await Connectivity().checkConnectivity();
    if (network.isEmpty || network.contains(ConnectivityResult.none)) {
      return '等待网络';
    }
    if (network.contains(ConnectivityResult.mobile) &&
        !network.contains(ConnectivityResult.wifi) &&
        await store.pref('cellular') != true) {
      return '等待 Wi-Fi';
    }
    return null;
  }

  Future<void> verify() async {
    final repo = await github.verify({'id': binding['repo']});
    binding['name'] = repo['full_name'];
    binding['branch'] = repo['default_branch'];
  }

  Future<void> pick({bool fileOriginal = false}) async {
    final rows = <Json>[];
    if (Platform.isAndroid) {
      final paths =
          await dialogs.invokeListMethod<String>(
            fileOriginal ? 'pickFiles' : 'pick',
          ) ??
          [];
      for (final uri in paths) {
        rows.add(
          plainMap(await media.invokeMethod('metadata', {'source': uri})),
        );
      }
    } else {
      const images = XTypeGroup(
        label: '照片',
        extensions: [
          'jpg',
          'jpeg',
          'png',
          'heic',
          'heif',
          'webp',
          'bmp',
          'tif',
          'tiff',
          'gif',
          'avif',
        ],
      );
      for (final file in await openFiles(acceptedTypeGroups: [images])) {
        final stat = await File(file.path).stat();
        rows.add({
          'source': file.path,
          'name': file.name,
          'size': stat.size,
          'time': stat.modified.millisecondsSinceEpoch,
        });
      }
    }
    await store.enqueue(target, rows);
  }

  Future<List<Json>> changes(Json from, Json to) async {
    final windows = <String, dynamic>{};
    for (final v in to.entries) {
      final last = from[v.key];
      // A newly mounted volume starts at this snapshot.
      if (last == null) continue;
      if (last['version'] != v.value['version']) {
        throw PlatformException(code: 'media', message: '系统媒体库已重建，请重新选择自动备份起点');
      }
      if (last['generation'] == v.value['generation']) continue;
      windows[v.key] = [
        last['floor'] ?? last['generation'],
        last['generation'],
        v.value['generation'],
      ].map((n) => n.toString()).toList();
    }
    if (windows.isEmpty) return [];
    final rows = (await media.invokeListMethod<dynamic>('scan', {
      'windows': windows,
      // Publication changes generation_modified; editing a pre-opt-in item must not import it.
      'selection':
          'generation_added > ? AND generation_modified > ? '
          'AND generation_modified <= ? AND is_pending=0 AND is_trashed=0',
    }))!;
    return rows.map(plainMap).toList();
  }

  Future<void> discover() async {
    final cursor = await store.pref('auto:$target');
    if (cursor == null) return;
    if (await media.invokeMethod('permission') != 'full') {
      await store.set('scanInfo:$target', '相册权限已改变，请重新授权以继续自动发现');
      return;
    }
    final next = plainMap(await media.invokeMethod('snapshot'));
    final previous = cursor as Json;
    final rebuilt = next.keys
        .where(
          (volume) =>
              previous.containsKey(volume) &&
              previous[volume]['version'] != next[volume]['version'],
        )
        .toList();
    for (final volume in rebuilt) {
      next.remove(volume);
    }
    final rows = await changes(previous, next);
    await store.enqueue(target, rows, automatic: true);
    await store.set('auto:$target', advanceMediaCursor(previous, next));
    await store.set(
      'scanInfo:$target',
      rebuilt.isEmpty ? null : '存储卷 ${rebuilt.join('、')} 的媒体库已重建，请重新选择自动备份起点',
    );
  }

  Future<void> _prepare(Json job, File original) async {
    final thumb = store.staged(job['id'], 'jpg');
    if (job['sha256'] != null &&
        (job['original'] != null || await original.exists()) &&
        (job['thumbnail'] != null || await thumb.exists())) {
      return;
    }
    if ((job['size'] ?? 0) >= maxAssetBytes) throw StateError('原片必须小于 2 GiB');
    final source = job['source'] as String;
    int? taken;
    if (Platform.isAndroid) {
      taken = await media.invokeMethod<int>('prepare', {
        'source': source,
        'original': original.path,
        'thumb': thumb.path,
      });
    } else {
      if (job['selectedSha256'] == null || !await original.exists()) {
        await File(source).copy(original.path);
      }
      taken = await media.invokeMethod<int>('thumbnail', {
        'source': original.path,
        'thumb': thumb.path,
        'metadata': original.path,
      });
    }
    final size = await original.length();
    if (size >= maxAssetBytes) throw StateError('原片必须小于 2 GiB');
    final hash = await fileHash(original);
    final expected = job['sha256'] ?? job['selectedSha256'];
    if (expected != null && expected != hash) {
      throw StateError('原片内容已变化，请选择原始版本');
    }
    job.addAll({
      'size': size,
      'sha256': hash,
      'thumbSize': await thumb.length(),
      'thumbHash': await fileHash(thumb),
      'takenAt':
          job['takenAt'] ??
          DateTime.fromMillisecondsSinceEpoch(
            taken ?? job['time'] ?? DateTime.now().millisecondsSinceEpoch,
            isUtc: true,
          ).toIso8601String(),
    });
    await store.checkpoint(job, '待校验原图');
  }

  Future<void> backupOne(Json job) async {
    final id = job['id'] as String;
    final resumeIndex = job['original'] != null && job['thumbnail'] != null;
    final originalFile = store.stagedOriginal(job);
    if (!resumeIndex) {
      // Older and newly selected snapshots initially use the extensionless staging name.
      final legacy = store.staged(id, 'original');
      if (legacy.path != originalFile.path && await legacy.exists()) {
        await legacy.rename(originalFile.path);
      }
      if (job['sha256'] == null) await _prepare(job, originalFile);
      var group =
          job['group'] as int? ??
          await store.pref('group:$target') as int? ??
          1;
      final device = await store.pref('device');
      while (true) {
        final rel = await github.release(
          root,
          'photo-album-$device-$group',
          branch,
        );
        final assets = await github.pages('$root/releases/${rel['id']}/assets');
        final names = assets.map((a) => a['name']).toSet();
        for (final pair in {
          'original': '$id.original',
          'thumbnail': '$id.thumb.jpg',
        }.entries) {
          if (!assets.any(
            (a) => a['name'] == pair.value && a['id'] == job[pair.key],
          )) {
            job.remove(pair.key);
          }
        }
        final missing = [
          '$id.original',
          '$id.thumb.jpg',
        ].where((n) => !names.contains(n)).length;
        if (!hasRoom(assets.length, needed: missing)) {
          // A competing upload can occupy the second slot after our first asset.
          // Keep the staged pair and retire the old asset only after both new IDs are durable.
          for (final a in assets.where(
            (a) => a['name'] == '$id.original' || a['name'] == '$id.thumb.jpg',
          )) {
            final original = a['name'] == '$id.original';
            final file = original ? originalFile : store.staged(id, 'jpg');
            if (!await file.exists()) {
              final sink = file.openWrite();
              try {
                await sink.addStream(await github.assetStream(root, a['id']));
              } finally {
                await sink.close();
              }
            }
            if (await fileHash(file) !=
                job[original ? 'sha256' : 'thumbHash']) {
              await file.delete();
              throw StateError('换组时原附件校验失败，已保留远端附件');
            }
            job['retired'] = {
              ...(job['retired'] as List? ?? []),
              a['id'],
            }.toList();
          }
          job.remove('original');
          job.remove('thumbnail');
          job['group'] = ++group;
          await store.checkpoint(job, '正在重新分组');
          continue;
        }
        if ((!names.contains('$id.original') && !await originalFile.exists()) ||
            (!names.contains('$id.thumb.jpg') &&
                !await store.staged(id, 'jpg').exists())) {
          await _prepare(job, originalFile);
        }
        job['group'] = group;
        await store.set('group:$target', group);
        await store.checkpoint(
          job,
          job['original'] == null ? '待校验原图' : '待上传缩略图',
        );
        if (job['original'] == null) {
          job['original'] = await github.ensureAsset(
            root,
            rel['id'],
            assets,
            '$id.original',
            originalFile,
            job['size'],
            job['sha256'],
          );
          await store.checkpoint(job, '待上传缩略图');
        }
        if (job['thumbnail'] == null) {
          job['thumbnail'] = await github.ensureAsset(
            root,
            rel['id'],
            assets,
            '$id.thumb.jpg',
            store.staged(id, 'jpg'),
            job['thumbSize'],
            job['thumbHash'],
          );
          await store.checkpoint(job, '待写入目录');
        }
        break;
      }
    }
    for (final asset in job['retired'] as List? ?? []) {
      try {
        await github.json('DELETE', '$root/releases/assets/$asset');
      } on ApiError catch (e) {
        if (e.status != 404) rethrow;
      }
    }
    final entry = {
      for (final key in [
        'id',
        'name',
        'size',
        'takenAt',
        'sha256',
        'original',
        'thumbnail',
      ])
        key: job[key],
    };
    final data = encodeIndex(entry);
    final path = indexPath(id);
    final published = await github.putIndex(
      root,
      branch,
      path,
      data,
      verifySavedAssets: resumeIndex
          ? () async {
              await github.verifySavedAsset(
                root,
                job['original'],
                '$id.original',
                job['size'],
                job['sha256'],
              );
              await github.verifySavedAsset(
                root,
                job['thumbnail'],
                '$id.thumb.jpg',
                job['thumbSize'],
                job['thumbHash'],
              );
            }
          : null,
    );
    await store.db.transaction((t) async {
      await t.insert('staged_cleanup', {
        'id': id,
        'name': job['name'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (!published) {
        await t.delete(
          'album',
          where: 'target=? AND path=?',
          whereArgs: [target, path],
        );
        final batch = t.batch();
        store.forgetJob(batch, target, id);
        await batch.commit(noResult: true);
        return;
      }
      await t.insert('album', {
        'target': target,
        'path': path,
        'data': data,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await t.update(
        'jobs',
        {'stage': '已备份', 'error': null},
        where: 'id=?',
        whereArgs: [id],
      );
    });
    await _cleanStaged(job);
  }

  Future<void> _cleanStaged(Json job) async {
    final id = job['id'] as String;
    for (final path in {
      store.stagedOriginal(job).path,
      store.staged(id, 'original').path,
      store.staged(id, 'jpg').path,
    }) {
      try {
        await File(path).delete();
      } on PathNotFoundException {
        continue;
      } on FileSystemException {
        return; // A later queue pass retries cleanup after the file is released.
      }
    }
    await store.db.delete('staged_cleanup', where: 'id=?', whereArgs: [id]);
  }

  Future<bool> run() async {
    var success = true;
    final blocked = await waiting();
    await store.set('status:$target', blocked);
    if (blocked != null) return false;
    await store.workLock.transaction((_) async {
      for (final job in await store.db.query('staged_cleanup')) {
        await _cleanStaged(job);
      }
      if ((await store.pref('binding'))?['target'] != target) return;
      try {
        await discover();
      } on PlatformException catch (e) {
        await store.set('scanInfo:$target', readable(e));
      }
    });
    final jobs = await store.db.query(
      'jobs',
      where: 'target=? AND stage<>?',
      whereArgs: [target, '已备份'],
      orderBy: 'rowid',
      columns: ['id'],
    );
    final deletes = await store.db.query(
      'removals',
      columns: ['path'],
      where: 'target=?',
      whereArgs: [target],
    );
    if (jobs.isEmpty && deletes.isEmpty) return true;
    await verify();
    for (final row in deletes) {
      await store.workLock.transaction((_) async {
        if (await waiting() != null) return;
        final current = await store.db.query(
          'removals',
          where: 'target=? AND path=?',
          whereArgs: [target, row['path']],
        );
        if (current.isEmpty) return;
        final photo = jsonDecode(current.single['data'] as String) as Json;
        if (photo['confirmAgain'] == true) return;
        try {
          await _remove(photo);
        } catch (e) {
          if (e is SocketException ||
              e is http.ClientException ||
              e is ApiError && (e.status == 401 || e.retryAt != null)) {
            rethrow;
          }
          success = false;
          await _removalError(photo, readable(e));
        }
      });
    }
    for (final row in jobs) {
      final wait = await waiting();
      if (wait != null) {
        await store.set('status:$target', wait);
        return false;
      }
      var stop = false;
      await store.workLock.transaction((_) async {
        final current = await store.db.query(
          'jobs',
          where: 'id=? AND stage<>?',
          whereArgs: [row['id'], '已备份'],
        );
        if (current.isEmpty || await waiting() != null) return;
        final job = jsonDecode(current.single['data'] as String) as Json;
        try {
          try {
            await backupOne(job);
          } on ApiError catch (e) {
            if (e.status != 422) rethrow;
            await backupOne(job);
          }
        } catch (e) {
          success = false;
          await store.checkpoint(job, job['stage'] ?? '等待备份', readable(e));
          if (e is ApiError && e.status == 401) {
            await store.set('authRequired:$target', true);
          }
          if (e is ApiError && e.retryAt != null) {
            await store.set('retry:$target', e.retryAt!.millisecondsSinceEpoch);
          }
          stop =
              e is SocketException ||
              e is http.ClientException ||
              e is ApiError && (e.status == 401 || e.retryAt != null);
          if (stop) await store.set('status:$target', readable(e));
        }
      });
      if (stop) break;
    }
    return success;
  }

  Future<void> refresh() => store.workLock.transaction((_) async {
    await verify();
    final remote = await github.directory(root, branch);
    final old = await store.db.query(
      'album',
      where: 'target=?',
      whereArgs: [target],
    );
    final previous = {for (final row in old) row['path']: row};
    final changed = <String, Json>{};
    for (final entry in remote.entries) {
      if (previous[entry.key]?['sha'] == entry.value) continue;
      final blob = await github.json('GET', '$root/git/blobs/${entry.value}');
      final data = utf8.decode(
        base64Decode((blob['content'] as String).replaceAll('\n', '')),
      );
      decodeIndex(data);
      changed[entry.key] = {
        'target': target,
        'path': entry.key,
        'sha': entry.value,
        'data': data,
      };
    }
    await store.db.transaction((t) async {
      final batch = t.batch();
      for (final row in changed.values) {
        batch.insert(
          'album',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final path in previous.keys.where(
        (key) => !remote.containsKey(key),
      )) {
        batch.delete(
          'album',
          where: 'target=? AND path=?',
          whereArgs: [target, path],
        );
      }
      // Reconcile even if an earlier app version already cached the deletion marker.
      final completed = await t.query(
        'jobs',
        columns: ['id'],
        where: 'target=? AND stage=?',
        whereArgs: [target, '已备份'],
      );
      for (final row in completed) {
        final id = row['id'] as String;
        final path = indexPath(id);
        final cached = changed[path] ?? previous[path];
        if (!remote.containsKey(path) ||
            deletedPhoto(cached!['data'] as String)?['id'] == id) {
          store.forgetJob(batch, target, id);
        }
      }
      await batch.commit(noResult: true);
    });
  });

  Future<File> download(Json photo, {required bool thumbnail}) async {
    final id = photo[thumbnail ? 'thumbnail' : 'original'] as int;
    final cache = Directory(p.join(store.dir.path, 'thumbs', target));
    await cache.create(recursive: true);
    final file = File(p.join(cache.path, '$id.jpg'));
    if (thumbnail && await file.exists()) return file;
    final temp = File(p.join(cache.path, '${const Uuid().v4()}.part'));
    try {
      final stream = await github.assetStream(root, id);
      final sink = temp.openWrite();
      try {
        await sink.addStream(stream);
      } finally {
        await sink.close();
      }
      if (thumbnail) return await temp.rename(file.path);
      if (await temp.length() != photo['size'] ||
          await fileHash(temp) != photo['sha256']) {
        throw StateError('原图大小或 SHA-256 不一致，未导出');
      }
      return temp;
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }

  Future<void> requestRemoval(Json photo) async {
    await store.workLock.transaction(
      (_) => store.db.insert('removals', {
        'target': target,
        'path': photo['path'],
        'data': jsonEncode({...photo, 'branch': branch}),
      }, conflictAlgorithm: ConflictAlgorithm.replace),
    );
  }

  Future<void> _removalError(
    Json photo,
    String error, {
    bool confirmAgain = false,
  }) async {
    await store.db.update(
      'removals',
      {
        'data': jsonEncode({
          ...photo,
          'error': error,
          'confirmAgain': confirmAgain,
        }),
      },
      where: 'target=? AND path=?',
      whereArgs: [target, photo['path']],
    );
  }

  Future<void> _remove(Json photo) async {
    if (photo['branch'] != null && photo['branch'] != branch) {
      await _removalError(photo, '默认分支已变化，请刷新相册并重新确认删除', confirmAgain: true);
      return;
    }
    final dest = '$root/contents/${photo['path']}';
    final batch = await github.optional(dest, query: {'ref': branch});
    if (batch == null) {
      await _removalError(
        photo,
        '当前分支找不到目录记录，请刷新相册并重新确认删除',
        confirmAgain: true,
      );
      return;
    }
    final raw = utf8.decode(
      base64Decode((batch['content'] as String).replaceAll('\n', '')),
    );
    final marker = deletedPhoto(raw);
    final entries = marker == null ? decodeIndex(raw) : [marker];
    if ((photo['branch'] == null && marker == null) ||
        entries.length != 1 ||
        entries.single['id'] != photo['id'] ||
        entries.single['original'] != photo['original'] ||
        entries.single['thumbnail'] != photo['thumbnail']) {
      await _removalError(photo, '目录已变化，请刷新相册并重新确认删除', confirmAgain: true);
      return;
    }
    if (marker == null) {
      await github.json(
        'PUT',
        dest,
        body: {
          'sha': batch['sha'],
          'content': base64Encode(utf8.encode(encodeDeletion(photo))),
          'message': 'Remove photo batch',
          'branch': branch,
        },
      );
    }
    for (final key in ['thumbnail', 'original']) {
      try {
        await github.json('DELETE', '$root/releases/assets/${photo[key]}');
      } on ApiError catch (e) {
        if (e.status != 404) rethrow;
      }
    }
    await store.db.transaction((t) async {
      for (final table in ['album', 'removals']) {
        await t.delete(
          table,
          where: 'target=? AND path=?',
          whereArgs: [target, photo['path']],
        );
      }
      final batch = t.batch();
      store.forgetJob(batch, target, photo['id']);
      await batch.commit(noResult: true);
    });
  }
}
