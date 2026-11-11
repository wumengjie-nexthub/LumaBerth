import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumaberth/src/catalog.dart';
import 'package:lumaberth/src/connect.dart';
import 'package:lumaberth/src/store.dart';

class _UnusedStore extends Fake implements Store {}

class _RecordingStore extends Fake implements Store {
  String? bound;
  @override
  Future<void> connect(
    Json repo,
    Json user,
    Json tokens,
    String clientId,
  ) async {
    bound = repo['full_name'] as String;
  }
}

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
      () => tester.pumpWidget(
        MaterialApp(
          home: ConnectPage(
            _UnusedStore(),
            clientId: 'client-1',
            appSlug: 'demo',
          ),
        ),
      ),
      () => client,
    );
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('复制并前往 GitHub'), findsOneWidget);
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
    expect(find.text('已登录 GitHub · test-user'), findsOneWidget);
    expect(challenges, 1);
    expect(polls, 4);
    expect(lists, 2);
  });
  for (final existing in [true, false]) {
    testWidgets(existing ? '唯一已授权私库只需确认一次' : '新建相册后仅授权指定私库再确认', (tester) async {
      final store = _RecordingStore();
      var installed = existing;
      final repo = {
        'id': 2,
        'full_name': 'demo/photos',
        'private': true,
        'default_branch': 'main',
        'permissions': {'push': true},
      };
      final client = MockClient((request) async {
        final Object reply = switch (request.url.path) {
          '/login/device/code' => {
            'user_code': 'ABCD-1234',
            'device_code': 'd',
            'expires_in': 900,
            'interval': 1,
          },
          '/login/oauth/access_token' => {'access_token': 'ok'},
          '/user' => {'id': 1, 'login': 'demo'},
          '/user/installations' => {
            'installations': installed
                ? [
                    {
                      'id': 7,
                      'permissions': {'contents': 'write'},
                    },
                  ]
                : [],
          },
          '/user/installations/7/repositories' => {
            'repositories': [repo],
          },
          '/repositories/2' => repo,
          '/repos/demo/photos/branches/main' => {'name': 'main'},
          _ => throw StateError('Unexpected request ${request.url}'),
        };
        return http.Response(jsonEncode(reply), 200);
      });
      final events = <String>[];
      const launcher = MethodChannel('plugins.flutter.io/url_launcher');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(launcher, (call) async {
        events.add(call.arguments['url'] as String);
        return true;
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          events.add(call.arguments['text'] as String);
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(launcher, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });
      await http.runWithClient(
        () => tester.pumpWidget(
          MaterialApp(
            initialRoute: '/connect',
            routes: {
              '/': (_) => const Scaffold(body: Text('相册首页')),
              '/connect': (_) =>
                  ConnectPage(store, clientId: 'client-1', appSlug: 'demo-app'),
            },
          ),
        ),
        () => client,
      );
      await tester.pump();
      expect(events, isEmpty);
      await tester.tap(find.text('复制并前往 GitHub'));
      await tester.pump();
      expect(events, ['ABCD-1234', 'https://github.com/login/device']);
      await tester.pump(const Duration(seconds: 1));
      if (!existing) {
        await tester.tap(find.text('创建私有相册'));
        await tester.pump();
        await tester.tap(find.text('前往 GitHub 创建私库'));
        await tester.tap(find.text('已创建，继续授权'));
        await tester.pump();
        await tester.tap(find.text('前往 GitHub 选择私库'));
        expect(
          events.last,
          'https://github.com/apps/demo-app/installations/new',
        );
        expect(events, contains('https://github.com/new'));
        installed = true;
        await tester.tap(find.text('刷新可用仓库'));
        await tester.pump();
      }
      expect(find.text('demo/photos'), findsOneWidget);
      expect(store.bound, isNull);
      await tester.tap(find.text('确认使用'));
      await tester.pumpAndSettle();
      expect(store.bound, 'demo/photos');
      expect(find.text('相册首页'), findsOneWidget);
    });
  }
}
