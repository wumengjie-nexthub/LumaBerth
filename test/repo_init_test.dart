import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumaberth/src/github.dart';

const _repo = {
  'id': 9,
  'full_name': 'eth4n/album',
  'private': true,
  'default_branch': 'main',
  'permissions': {'push': true},
};

Github _api(http.Client client) => Github(client, () async => 'token');

http.Response _json(Object value, [int status = 200]) =>
    http.Response(jsonEncode(value), status);

void main() {
  test('空仓库在连接时自动提交第一份 README', () async {
    var branchChecks = 0;
    final writes = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      switch ('${request.method} ${request.url.path}') {
        case 'GET /repositories/9':
          return _json(_repo);
        case 'GET /repos/eth4n/album/branches/main':
          branchChecks++;
          // An empty repository answers 409 until the first commit exists.
          return branchChecks == 1
              ? _json({'message': 'Git Repository is empty.'}, 409)
              : _json({'name': 'main'});
        case 'PUT /repos/eth4n/album/contents/README.md':
          writes.add(jsonDecode(request.body) as Map<String, dynamic>);
          return _json({
            'commit': {'sha': 'first'},
          }, 201);
      }
      fail('Unexpected request ${request.method} ${request.url}');
    });

    final value = await _api(client).verify({'id': 9});

    expect(value['full_name'], 'eth4n/album');
    expect(branchChecks, 2);
    final body = writes.single;
    expect(body['message'], isNotEmpty);
    // Naming no branch lets GitHub create the repository's default branch.
    expect(body.containsKey('branch'), isFalse);
    final readme = utf8.decode(base64Decode(body['content'] as String));
    expect(readme, contains('映格'));
    expect(readme, contains('photo-album/v1/'));
  });

  test('另一台设备同时初始化后仍能连接', () async {
    var branchChecks = 0;
    final client = MockClient((request) async {
      switch ('${request.method} ${request.url.path}') {
        case 'GET /repositories/9':
          return _json(_repo);
        case 'GET /repos/eth4n/album/branches/main':
          // Empty on the first check, then the commit another client (or the
          // browser) created lands before the README write is answered.
          branchChecks++;
          return branchChecks == 1
              ? _json({'message': 'Git Repository is empty.'}, 409)
              : _json({'name': 'main'});
        case 'PUT /repos/eth4n/album/contents/README.md':
          return _json({'message': 'Reference already exists'}, 422);
      }
      fail('Unexpected request ${request.method} ${request.url}');
    });

    final value = await _api(client).verify({'id': 9});
    expect(value['default_branch'], 'main');
    expect(branchChecks, 2);
  });

  test('已有分支的仓库不写入任何文件', () async {
    final client = MockClient((request) async {
      switch ('${request.method} ${request.url.path}') {
        case 'GET /repositories/9':
          return _json(_repo);
        case 'GET /repos/eth4n/album/branches/main':
          return _json({'name': 'main'});
      }
      fail('Unexpected write ${request.method} ${request.url}');
    });

    final value = await _api(client).verify({'id': 9});
    expect(value['private'], true);
  });

  test('没有内容写入权限时给出可读提示', () async {
    final client = MockClient((request) async {
      switch ('${request.method} ${request.url.path}') {
        case 'GET /repositories/9':
          return _json(_repo);
        case 'GET /repos/eth4n/album/branches/main':
          return _json({'message': 'Git Repository is empty.'}, 409);
        case 'PUT /repos/eth4n/album/contents/README.md':
          return _json({
            'message': 'Resource not accessible by integration',
          }, 403);
      }
      fail('Unexpected request ${request.method} ${request.url}');
    });

    await expectLater(
      _api(client).verify({'id': 9}),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Contents: Read and write'),
        ),
      ),
    );
  });
}
