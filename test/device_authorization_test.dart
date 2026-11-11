import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumaberth/src/connect.dart';
import 'package:lumaberth/src/store.dart';

class _UnusedStore extends Fake implements Store {}

void main() {
  testWidgets('授权轮询断网后保留设备码，恢复后可继续加载仓库', (tester) async {
    var challenges = 0, polls = 0, lists = 0;
    final client = MockClient((request) async {
      Object reply;
      switch (request.url.path) {
        case '/login/device/code':
          challenges++;
          reply = {
            'user_code': 'ABCD-1234',
            'device_code': 'device-1',
            'interval': 1,
            'expires_in': 900,
          };
        case '/login/oauth/access_token':
          expect(request.bodyFields['device_code'], 'device-1');
          expect(request.bodyFields['client_id'], 'client-1');
          polls++;
          if (polls == 1) throw http.ClientException('connection aborted');
          if (polls == 2) throw TimeoutException('offline');
          reply = polls == 3
              ? {'error': 'authorization_pending'}
              : {'access_token': 'approved'};
        case '/user':
          expect(request.headers['Authorization'], 'Bearer approved');
          lists++;
          if (lists == 1) throw http.ClientException('offline again');
          reply = {'login': 'test-user'};
        case '/user/installations':
          reply = {'installations': []};
        default:
          throw StateError('Unexpected request ${request.url.path}');
      }
      return http.Response(jsonEncode(reply), 200);
    });
    const launcher = MethodChannel('plugins.flutter.io/url_launcher');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      launcher,
      (_) async => true,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        launcher,
        null,
      ),
    );

    await http.runWithClient(
      () => tester.pumpWidget(MaterialApp(home: ConnectPage(_UnusedStore()))),
      () => client,
    );
    await tester.enterText(find.byType(TextField).first, 'client-1');
    await tester.tap(find.text('获取设备码'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('ABCD-1234'), findsOneWidget);
    expect(find.textContaining('将自动使用当前设备码重试'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(polls, 1);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 4));
    expect(polls, 3);
    await tester.pump(const Duration(seconds: 1));
    expect(lists, 1);
    expect(find.text('ABCD-1234'), findsNothing);

    await tester.tap(find.text('刷新可用仓库'));
    await tester.pumpAndSettle();
    expect(find.text('已授权账号  test-user'), findsOneWidget);
    expect(challenges, 1);
    expect(polls, 4);
    expect(lists, 2);
  });
}
