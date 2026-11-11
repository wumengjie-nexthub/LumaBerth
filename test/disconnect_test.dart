import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lumaberth/src/backup.dart';
import 'package:lumaberth/src/catalog.dart';
import 'package:lumaberth/src/store.dart';

import 'backup_test.dart' show Remote;

class WaitingUpload extends http.BaseClient {
  WaitingUpload(this.remote);
  final Remote remote;
  final started = Completer<void>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path == '/repos/user/album') {
      return http.StreamedResponse(
        Stream.value('{"id":2,"private":true}'.codeUnits),
        200,
      );
    }
    if (request.url.host == 'uploads.github.com') {
      started.complete();
      await (request as http.Abortable).abortTrigger!;
      throw http.RequestAbortedException(request.url);
    }
    return remote.transport.send(request);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('断开绑定会中止当前上传，并保留可恢复的任务', () async {
    FlutterSecureStorage.setMockInitialValues({});
    const channel = MethodChannel('dev.fluttercommunity.plus/connectivity');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => ['wifi']);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final dir = await Directory.systemTemp.createTemp('disconnect-');
    final store = await Store.open(directory: dir);
    final remote = Remote();
    final client = WaitingUpload(remote);
    addTearDown(() async {
      remote.transport.close();
      await store.close();
      await dir.delete(recursive: true);
    });
    await store.connect(
      {'id': 2, 'full_name': 'user/album', 'default_branch': 'main'},
      {'id': 1, 'login': 'user'},
      {'access_token': 'fixture'},
      'fixture',
    );
    await store.enqueue('1-2', [
      {'source': 'selected', 'name': 'photo.jpg', 'size': 1},
    ]);
    final job = (await store.jobs('1-2')).single;
    await store.staged(job['id'], 'original').writeAsBytes([1]);
    await store.staged(job['id'], 'jpg').writeAsBytes([2]);
    job.addAll({
      'sha256': checksum([1]),
      'thumbHash': checksum([2]),
      'thumbSize': 1,
      'takenAt': DateTime.utc(2025).toIso8601String(),
    });
    await store.checkpoint(job, '待校验原图');
    final engine = Backup(store, await store.pref('binding') as Json, client);
    final run = engine.run();
    await client.started.future;
    await store.disconnect().timeout(const Duration(seconds: 8));
    expect(await run, false);
    expect(await store.pref('binding'), isNull);
    expect((await store.jobs('1-2')).single['stage'], isNot('已备份'));
    expect(remote.puts, 0);
    expect(remote.assets, isEmpty);
  });
}
