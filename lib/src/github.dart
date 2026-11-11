import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'catalog.dart';

class ApiError implements Exception {
  ApiError(this.status, this.message, [this.retryAt]);
  final int status;
  final String message;
  final DateTime? retryAt;
  @override
  String toString() => message;
}

class _FileRequest extends http.BaseRequest with http.Abortable {
  _FileRequest(super.method, super.url, this.file, this.abortTrigger);
  @override
  final Future<void> abortTrigger;
  final File file;
  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(file.openRead());
  }
}

class Github {
  Github(this.client, this.access, {this.beforeWrite, this.uploadStops});
  final http.Client client;
  final Future<String> Function() access;
  final Future<void> Function()? beforeWrite;
  final Stream<String> Function()? uploadStops;
  static Uri api(String path, [Map<String, String>? query]) =>
      Uri.https('api.github.com', path, query);

  static Future<Json> oauth(http.Client client, String path, Json body) async {
    final response = await client
        .post(
          Uri.https('github.com', path),
          headers: {'Accept': 'application/json'},
          body: body.cast<String, String>(),
        )
        .timeout(const Duration(seconds: 35));
    if (response.statusCode != 200) {
      throw ApiError(
        response.statusCode,
        'GitHub 授权请求失败（${response.statusCode}）',
      );
    }
    return jsonDecode(response.body) as Json;
  }

  Future<http.StreamedResponse> _send(
    String method,
    Uri url, {
    Json? body,
    File? file,
    bool binary = false,
  }) async {
    final bearer = await access();
    if (method != 'GET') await beforeWrite?.call();
    final headers = {
      'Authorization': 'Bearer $bearer',
      'Accept': binary
          ? 'application/octet-stream'
          : 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
    };
    final http.BaseRequest request;
    if (file != null) {
      final abort = Completer<void>();
      final upload = _FileRequest(method, url, file, abort.future)
        ..headers.addAll({
          ...headers,
          'Content-Type': 'application/octet-stream',
        })
        ..contentLength = await file.length()
        ..followRedirects = false;
      String? reason;
      void stop(String message) {
        reason = message;
        if (!abort.isCompleted) abort.complete();
      }

      final subscription = uploadStops?.call().listen(
        stop,
        onError: (Object e) => stop(e.toString()),
      );
      final timeout = Timer(
        const Duration(minutes: 10),
        () => stop('上传超时，等待核对远端状态'),
      );
      try {
        final response = await client.send(upload);
        // The upload is only acknowledged once the entire JSON response arrives.
        final bytes = <int>[];
        final received = Completer<void>();
        final body = response.stream.listen(
          bytes.addAll,
          onError: received.completeError,
          onDone: received.complete,
        );
        try {
          await Future.any([received.future, abort.future]);
          if (abort.isCompleted) throw StateError(reason ?? '上传已暂停');
        } finally {
          await body.cancel();
        }
        return await _check(
          http.StreamedResponse(
            Stream.value(bytes),
            response.statusCode,
            headers: response.headers,
          ),
        );
      } on http.RequestAbortedException {
        throw StateError(reason ?? '上传已暂停');
      } finally {
        timeout.cancel();
        await subscription?.cancel();
      }
    } else {
      final json = http.Request(method, url)
        ..headers.addAll(headers)
        ..followRedirects = false;
      if (body != null) {
        json.headers['Content-Type'] = 'application/json';
        json.bodyBytes = utf8.encode(jsonEncode(body));
      }
      request = json;
    }
    var response = await client
        .send(request)
        .timeout(const Duration(seconds: 45));
    if (binary && [301, 302, 303, 307, 308].contains(response.statusCode)) {
      final location = Uri.tryParse(response.headers['location'] ?? '');
      await response.stream.drain<void>();
      if (location == null || location.scheme != 'https') {
        throw const FormatException('无效的附件下载地址');
      }
      // Signed asset URLs do not need the repository access token.
      response = await client
          .send(http.Request('GET', location))
          .timeout(const Duration(seconds: 45));
    }
    return _check(response);
  }

  Future<http.StreamedResponse> _check(http.StreamedResponse response) async {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    final raw = await response.stream.bytesToString();
    final headers = response.headers;
    final retry = int.tryParse(headers['retry-after'] ?? '');
    final reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
    DateTime? at;
    if (retry != null) {
      at = DateTime.now().add(Duration(seconds: retry));
    } else if (headers['x-ratelimit-remaining'] == '0' && reset != null) {
      at = DateTime.fromMillisecondsSinceEpoch(reset * 1000);
    } else if (response.statusCode == 429 || raw.contains('rate limit')) {
      at = DateTime.now().add(const Duration(minutes: 1));
    }
    String reason = 'GitHub 请求失败';
    if (response.statusCode == 401) reason = '授权已失效，请重新连接原仓库';
    if (response.statusCode == 403) reason = 'GitHub 拒绝访问，请检查安装范围和读写权限';
    if (response.statusCode == 404) reason = 'GitHub 找不到仓库或文件，请检查授权和远端状态';
    if (at != null) reason = 'GitHub 限流，${at.toLocal()} 后继续';
    throw ApiError(response.statusCode, '$reason（${response.statusCode}）', at);
  }

  Future<dynamic> json(
    String method,
    String path, {
    Map<String, String>? query,
    Json? body,
  }) async {
    final response = await _send(method, api(path, query), body: body);
    final raw = await response.stream.bytesToString().timeout(
      const Duration(seconds: 60),
    );
    return raw.isEmpty ? null : jsonDecode(raw);
  }

  Future<List<Json>> pages(String path, {String? field}) async {
    final rows = <Json>[];
    for (var page = 1; ; page++) {
      final data = await json(
        'GET',
        path,
        query: {'per_page': '100', 'page': '$page'},
      );
      final chunk = (field == null ? data : data[field]) as List;
      rows.addAll(chunk.cast<Json>());
      if (chunk.length < 100) return rows;
    }
  }

  Future<List<Json>> repositories() async {
    final repos = <Json>[];
    for (final installation in await pages(
      '/user/installations',
      field: 'installations',
    )) {
      if (installation['permissions']?['contents'] != 'write') continue;
      final scope = '/user/installations/${installation['id']}/repositories';
      repos.addAll(
        (await pages(scope, field: 'repositories')).where(
          (r) =>
              r['private'] == true &&
              r['archived'] != true &&
              r['permissions']?['push'] == true,
        ),
      );
    }
    return repos;
  }

  Future<Json> verify(Json repo) async {
    final value = await json('GET', '/repositories/${repo['id']}') as Json;
    if (value['id'] != repo['id'] ||
        value['private'] != true ||
        value['archived'] == true ||
        value['permissions']?['push'] != true) {
      throw StateError('请选择已授权、可写的专用私有仓库');
    }
    try {
      await json(
        'GET',
        '/repos/${value['full_name']}/branches/${value['default_branch']}',
      );
    } on ApiError catch (e) {
      if (e.status == 404 || e.status == 409) {
        throw StateError('请先在 GitHub 为仓库初始化 README');
      }
      rethrow;
    }
    return value;
  }

  Future<Json?> optional(String path, {Map<String, String>? query}) async {
    try {
      return await json('GET', path, query: query) as Json;
    } on ApiError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<Json> release(String root, String tag, String branch) async {
    final existing = await optional('$root/releases/tags/$tag');
    if (existing != null) return existing;
    try {
      return await json(
        'POST',
        '$root/releases',
        body: {
          'tag_name': tag,
          'name': tag,
          'target_commitish': branch,
          'make_latest': 'false',
        },
      ) as Json;
    } on ApiError catch (e) {
      if (e.status != 422) rethrow;
      return await json('GET', '$root/releases/tags/$tag') as Json;
    }
  }

  Future<int> ensureAsset(
    String root,
    int release,
    List<Json> assets,
    String name,
    File file,
    int size,
    String digest,
  ) async {
    Json? asset = assets.where((a) => a['name'] == name).firstOrNull;
    if (asset?['state'] == 'starter') {
      await json('DELETE', '$root/releases/assets/${asset!['id']}');
      asset = null;
    }
    if (asset == null) {
      final url = Uri.https(
        'uploads.github.com',
        '$root/releases/$release/assets',
        {'name': name},
      );
      final response = await _send('POST', url, file: file);
      asset = jsonDecode(await response.stream.bytesToString()) as Json;
    }
    return _verifyAsset(root, asset, name, size, digest);
  }

  Future<void> verifySavedAsset(
    String root,
    int id,
    String name,
    int size,
    String digest,
  ) async {
    final asset = await json('GET', '$root/releases/assets/$id') as Json;
    if (asset['id'] != id) throw StateError('远端附件 ID 不一致：$name');
    await _verifyAsset(root, asset, name, size, digest);
  }

  Future<int> _verifyAsset(
    String root,
    Json asset,
    String name,
    int size,
    String digest,
  ) async {
    if (asset['name'] != name ||
        asset['state'] != 'uploaded' ||
        asset['size'] != size ||
        asset['id'] is! int) {
      throw StateError('附件尚未通过状态与大小校验：$name');
    }
    var actual = asset['digest']?.toString() ?? '';
    if (!RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(actual)) {
      final stream = await assetStream(root, asset['id']);
      actual = 'sha256:${await sha256.bind(stream).first}';
    }
    if (actual != 'sha256:$digest') throw StateError('附件 SHA-256 不一致：$name');
    return asset['id'] as int;
  }

  Future<Stream<List<int>>> assetStream(String root, int id) async =>
      (await _send(
        'GET',
        api('$root/releases/assets/$id'),
        binary: true,
      )).stream.timeout(const Duration(seconds: 60));

  // False means a confirmed remote deletion has superseded this upload.
  Future<bool> putIndex(
    String root,
    String branch,
    String path,
    String data, {
    Future<void> Function()? verifySavedAssets,
  }) async {
    final dest = '$root/contents/$path';
    final encoded = base64Encode(utf8.encode(data));
    Future<bool?> published() async {
      final found = await optional(dest, query: {'ref': branch});
      if (found == null) return null;
      final content = (found['content'] as String).replaceAll('\n', '');
      if (content != encoded) {
        final marker = deletedPhoto(utf8.decode(base64Decode(content)));
        if (marker != null && indexPath(marker['id']) == path) return false;
        throw StateError('远端批次内容冲突，已保留本机队列');
      }
      return true;
    }

    for (var attempt = 0; ; attempt++) {
      final existing = await published();
      if (existing == false) return false;
      await verifySavedAssets?.call();
      if (existing == true) return true;
      try {
        await json(
          'PUT',
          dest,
          body: {
            'message': 'Add photo batch',
            'branch': branch,
            'content': encoded,
          },
        );
        return true;
      } catch (e) {
        if (e is ApiError && e.retryAt != null) rethrow;
        final result = await published();
        if (result != null) return result;
        if (e is! ApiError || e.status != 409 || attempt >= 2) rethrow;
      }
    }
  }

  // Walk only this application's subtree at one immutable commit. No 1,000-entry Contents limit.
  Future<Map<String, String>> directory(String root, String branch) async {
    final commit = await json('GET', '$root/commits/$branch');
    String tree = commit['commit']['tree']['sha'];
    Future<List<Json>> children(String sha) async {
      final value = await json('GET', '$root/git/trees/$sha');
      if (value['truncated'] == true) throw StateError('相册目录过大，未能完整刷新');
      return (value['tree'] as List).cast<Json>();
    }

    for (final part in ['photo-album', 'v1']) {
      final entry = (await children(tree))
          .where((e) => e['path'] == part && e['type'] == 'tree')
          .firstOrNull;
      if (entry == null) return {};
      tree = entry['sha'];
    }
    final result = <String, String>{};
    for (final shard in await children(tree)) {
      if (shard['type'] != 'tree' ||
          !RegExp(r'^[0-9a-f]{2}$').hasMatch(shard['path'])) {
        continue;
      }
      for (final item in await children(shard['sha'])) {
        if (item['type'] == 'blob' &&
            RegExp(r'^[a-f0-9-]{36}\.json$').hasMatch(item['path'])) {
          result['photo-album/v1/${shard['path']}/${item['path']}'] =
              item['sha'];
        }
      }
    }
    return result;
  }
}
