import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show sqfliteFfiInit, databaseFactoryFfi;
import 'package:uuid/uuid.dart';

import 'catalog.dart';
import 'github.dart';

class Store {
  Store(this.db, this.workLock, this.tokenLock, this.dir);
  final Database db, workLock, tokenLock;
  final Directory dir;
  static const vault = FlutterSecureStorage();
  static Future<Store> open({Directory? directory}) async {
    if (Platform.isWindows) sqfliteFfiInit();
    final factory = Platform.isWindows ? databaseFactoryFfi : databaseFactory;
    final dir = directory ?? await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    Future<Database> database(String name) => factory.openDatabase(
      p.join(dir.path, name),
      options: OpenDatabaseOptions(
        singleInstance: false,
        onConfigure: (db) async {
          await db.execute('PRAGMA busy_timeout=15000');
        },
      ),
    );
    final db = await database('album.sqlite');
    await db.transaction((t) async {
      await t.execute(
        'CREATE TABLE IF NOT EXISTS prefs (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      await t.execute(
        'CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, target TEXT NOT NULL, source TEXT NOT NULL, stage TEXT NOT NULL, data TEXT NOT NULL, error TEXT, UNIQUE(target,source))',
      );
      await t.execute(
        'CREATE TABLE IF NOT EXISTS album (target TEXT NOT NULL, path TEXT NOT NULL, sha TEXT, data TEXT NOT NULL, PRIMARY KEY(target,path))',
      );
      await t.execute(
        'CREATE TABLE IF NOT EXISTS removals (target TEXT NOT NULL, path TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(target,path))',
      );
      // Later metadata edits must not automatically restore a user-deleted backup.
      await t.execute(
        'CREATE TABLE IF NOT EXISTS deleted_media (target TEXT NOT NULL, source TEXT NOT NULL, PRIMARY KEY(target,source))',
      );
      await t.insert('prefs', {
        'key': 'device',
        'value': jsonEncode(const Uuid().v4()),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    });
    return Store(
      db,
      await database('work.lock.sqlite'),
      await database('auth.lock.sqlite'),
      dir,
    );
  }

  Future<void> close() async {
    await db.close();
    await workLock.close();
    await tokenLock.close();
  }

  Future<dynamic> pref(String key) async {
    final rows = await db.query('prefs', where: 'key=?', whereArgs: [key]);
    return rows.isEmpty ? null : jsonDecode(rows.first['value'] as String);
  }

  Future<void> set(String key, dynamic value) async {
    await db.insert('prefs', {
      'key': key,
      'value': jsonEncode(value),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> connect(
    Json repo,
    Json user,
    Json tokens,
    String clientId,
  ) async {
    await workLock.transaction((_) async {
      final target = '${user['id']}-${repo['id']}';
      await tokenLock.transaction((_) async {
        await vault.write(
          key: 'github-session',
          value: jsonEncode({
            ...tokens,
            'client_id': clientId,
            'target': target,
            'expires': expiry(tokens),
          }),
        );
        await set('authRequired:$target', false);
        await set('binding', {
          'target': target,
          'repo': repo['id'],
          'name': repo['full_name'],
          'branch': repo['default_branch'],
          'login': user['login'],
        });
      });
    });
  }

  static int expiry(Json tokens) =>
      DateTime.now().millisecondsSinceEpoch +
      (tokens['expires_in'] as int? ?? 28800) * 1000;
  Future<void> disconnect() async {
    await workLock.transaction((_) async {
      await tokenLock.transaction((_) async {
        final binding = await pref('binding');
        if (binding != null) await set('auto:${binding['target']}', null);
        await set('binding', null);
        await vault.delete(key: 'github-session');
      });
    });
  }

  Future<String> token(
    String target,
    http.Client client,
  ) => tokenLock.transaction((_) async {
    final raw = await vault.read(key: 'github-session');
    if (raw == null) throw StateError('请重新连接 GitHub');
    final session = jsonDecode(raw) as Json;
    if (session['target'] != target) throw StateError('已切换仓库');
    if (session['expires'] > DateTime.now().millisecondsSinceEpoch + 90000) {
      return session['access_token'] as String;
    }
    if (session['refresh_token'] == null) throw ApiError(401, '请重新连接原仓库以恢复授权');
    final tokens = await Github.oauth(client, '/login/oauth/access_token', {
      'client_id': session['client_id'],
      'grant_type': 'refresh_token',
      'refresh_token': session['refresh_token'],
    });
    if (tokens['access_token'] == null) throw ApiError(401, '请重新连接原仓库以恢复授权');
    await vault.write(
      key: 'github-session',
      value: jsonEncode({
        ...tokens,
        'target': target,
        'client_id': session['client_id'],
        'expires': expiry(tokens),
      }),
    );
    return tokens['access_token'] as String;
  });

  Future<List<Json>> jobs(String target) async =>
      (await db.query(
            'jobs',
            where: 'target=?',
            whereArgs: [target],
            orderBy: 'rowid',
          ))
          .map(
            (r) => {
              ...jsonDecode(r['data'] as String) as Json,
              'stage': r['stage'],
              'error': r['error'],
            },
          )
          .toList();
  Future<void> enqueue(
    String target,
    List<Json> inputs, {
    bool automatic = false,
  }) async {
    final unversioned = <Json>[];
    for (final input in inputs) {
      if (Platform.isWindows &&
          p.windows.isAbsolute(input['source']) &&
          (input['size'] ?? 0) < maxAssetBytes) {
        await _enqueueWindowsFile(target, input);
      } else {
        unversioned.add(input);
      }
    }
    if (unversioned.isEmpty) return;
    await db.transaction((t) async {
      final batch = t.batch();
      for (final input in unversioned) {
        final id = const Uuid().v4();
        if (automatic) {
          batch.rawInsert(
            'INSERT OR IGNORE INTO jobs (id,target,source,stage,data) '
            'SELECT ?,?,?,?,? WHERE NOT EXISTS '
            '(SELECT 1 FROM deleted_media WHERE target=? AND source=?)',
            [
              id,
              target,
              input['source'],
              '等待备份',
              jsonEncode({...input, 'id': id}),
              target,
              input['source'],
            ],
          );
          continue;
        }
        batch.insert('jobs', {
          'id': id,
          'target': target,
          'source': input['source'],
          'stage': '等待备份',
          'data': jsonEncode({...input, 'id': id}),
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await batch.commit(noResult: true);
    });
  }

  // Keep the bytes chosen in the picker, even if a camera later reuses the filename.
  Future<void> _enqueueWindowsFile(String target, Json input) async {
    final path = input['source'] as String;
    final source = File(path);
    if (await source.length() >= maxAssetBytes) {
      throw StateError('${input['name']} 必须小于 2 GiB');
    }
    final id = const Uuid().v4();
    final snapshot = staged(id, 'original');
    var retained = false;
    try {
      await source.copy(snapshot.path);
      final size = await snapshot.length();
      if (size >= maxAssetBytes) {
        throw StateError('${input['name']} 必须小于 2 GiB');
      }
      final hash = await fileHash(snapshot);
      // The SQL source column is the deduplication key. The original path stays in data.
      final key = jsonEncode([path, hash]);
      retained = await workLock.transaction(
        (_) => db.transaction((t) async {
          final matches = await t.query(
            'jobs',
            where: 'target=? AND source IN (?,?)',
            whereArgs: [target, key, path],
          );
          for (final row in matches) {
            final previous = jsonDecode(row['data'] as String) as Json;
            if (row['source'] == key || previous['sha256'] == hash) {
              return false;
            }
            if (previous['sha256'] == null) {
              // A pre-upgrade pending job has only its path and has never verified any bytes.
              await snapshot.copy(staged(previous['id'], 'original').path);
              await t.update(
                'jobs',
                {
                  'source': key,
                  'data': jsonEncode({
                    ...previous,
                    'size': size,
                    'selectedSha256': hash,
                  }),
                },
                where: 'id=?',
                whereArgs: [previous['id']],
              );
              return false;
            }
          }
          await t.insert('jobs', {
            'id': id,
            'target': target,
            'source': key,
            'stage': '等待备份',
            'data': jsonEncode({
              ...input,
              'id': id,
              'size': size,
              'selectedSha256': hash,
            }),
          });
          return true;
        }),
      );
    } finally {
      if (!retained && await snapshot.exists()) await snapshot.delete();
    }
  }

  // Keep the Android MediaStore URI suppressed for automatic scans only.
  void forgetJob(Batch batch, String target, String id) {
    batch.rawInsert(
      'INSERT OR IGNORE INTO deleted_media(target,source) '
      "SELECT target,source FROM jobs WHERE target=? AND id=? AND source LIKE 'content://media/%'",
      [target, id],
    );
    batch.delete('jobs', where: 'target=? AND id=?', whereArgs: [target, id]);
  }

  Future<void> checkpoint(Json job, String stage, [String? error]) async {
    job['stage'] = stage;
    await db.update(
      'jobs',
      {'stage': stage, 'error': error, 'data': jsonEncode(job)},
      where: 'id=?',
      whereArgs: [job['id']],
    );
  }

  Future<List<Json>> photos(String target) async {
    final rows = await db.query(
      'album',
      where: 'target=?',
      whereArgs: [target],
    );
    final result = rows
        .expand(
          (r) =>
              decodeIndex(r['data'] as String)
                  .map((v) => {...v, 'path': r['path']}),
        )
        .toList();
    result.sort(
      (a, b) => (b['takenAt'] as String).compareTo(a['takenAt'] as String),
    );
    return result;
  }

  File staged(String id, String role) => File(p.join(dir.path, '$id.$role'));
}
