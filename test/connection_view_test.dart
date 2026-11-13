import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumaberth/src/home.dart';
import 'package:lumaberth/src/connect.dart';
import 'package:lumaberth/src/store.dart';

class EmptyStore extends Fake implements Store {
  final values = <String, dynamic>{};
  @override
  Future<dynamic> pref(String key) async => values[key];
  @override
  Future<void> set(String key, dynamic value) async => values[key] = value;
}

void main() {
  for (final width in [360.0, 1280.0]) {
    testWidgets('自行配置 GitHub App，窗口宽度 $width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 720);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messenger = tester.binding.defaultBinaryMessenger;
      const channel = MethodChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      );
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final opened = <Uri>[];
      const launcher = MethodChannel('plugins.flutter.io/url_launcher');
      messenger.setMockMethodCallHandler(launcher, (call) async {
        opened.add(Uri.parse(call.arguments['url'] as String));
        return true;
      });
      var clipboard = '';
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': clipboard};
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(launcher, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });

      final store = EmptyStore();
      var challenges = 0;
      final client = MockClient((request) async {
        if (request.url.path == '/apps/personal-app') {
          // Private apps 404 on api.github.com; the page is the only check.
          return http.Response('<html>personal-app</html>', 200);
        }
        challenges++;
        expect(request.url.toString(), 'https://github.com/login/device/code');
        expect(request.bodyFields['client_id'], 'client-test');
        return http.Response(
          jsonEncode({
            'device_code': 'test-device',
            'user_code': 'DEMO-1234',
            'interval': 5,
            'expires_in': 900,
          }),
          200,
        );
      });
      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(home: AlbumHome(store)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('连接我的 GitHub'));
        await tester.pumpAndSettle();
        expect(find.text('连接你的私人相册'), findsOneWidget);
        expect(challenges, 0);

        if (width == 360) {
          await tester.tap(find.text('开始设置'));
          await tester.pumpAndSettle();
          expect(find.text('第 1 步：创建专属连接'), findsOneWidget);
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(find.text('连接你的私人相册'), findsOneWidget);
          await tester.tap(find.text('开始设置'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('打开 GitHub 创建页面'));
          await tester.tap(find.text('打开 GitHub 创建页面'));
          await tester.pumpAndSettle();
          expect(opened, hasLength(1));
          final uri = opened.single;
          expect(uri.host, 'github.com');
          expect(uri.path, '/settings/apps/new');
          expect(
            uri.queryParameters['name'],
            matches(r'^yingge-[a-f0-9]{12}$'),
          );
          expect(
            uri.queryParameters['url'],
            'https://github.com/wumengjie-nexthub/LumaBerth',
          );
          expect(uri.queryParameters['contents'], 'write');
          expect(uri.queryParameters['public'], 'false');
          expect(uri.queryParameters['webhook_active'], 'false');
          expect(uri.queryParameters['request_oauth_on_install'], 'false');
          await tester.ensureVisible(find.text('我已创建，继续'));
          await tester.tap(find.text('我已创建，继续'));
        } else {
          await tester.ensureVisible(find.text('我已经创建过 GitHub App'));
          await tester.tap(find.text('我已经创建过 GitHub App'));
        }
        await tester.pumpAndSettle();
        expect(find.text('第 2 步：填写连接信息'), findsOneWidget);
        expect(find.byType(TextField), findsNWidgets(2));

        await tester.ensureVisible(find.text('保存并继续'));
        await tester.tap(find.text('保存并继续'));
        await tester.pumpAndSettle();
        expect(find.textContaining('请填写 Client ID'), findsOneWidget);
        expect(challenges, 0);

        clipboard = ' client-test ';
        await tester.ensureVisible(find.byTooltip('粘贴 Client ID'));
        await tester.tap(find.byTooltip('粘贴 Client ID'));
        await tester.pumpAndSettle();
        expect(find.textContaining('请填写 Client ID'), findsNothing);
        clipboard = width == 360
            ? 'https://github.com/settings/apps/personal-app/'
            : 'https://github.com/apps/personal-app/';
        await tester.ensureVisible(find.byTooltip('粘贴页面链接'));
        await tester.tap(find.byTooltip('粘贴页面链接'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('保存并继续'));
        await tester.tap(find.text('保存并继续'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(challenges, 1);
        expect(find.text('DEMO-1234'), findsOneWidget);
        expect(store.values['githubApp'], {
          'clientId': 'client-test',
          'appSlug': 'personal-app',
        });

        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.text('连接我的 GitHub'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byType(TextField).at(0))
              .controller!
              .text,
          'client-test',
        );
        expect(
          tester
              .widget<TextField>(find.byType(TextField).at(1))
              .controller!
              .text,
          'personal-app',
        );
        expect(challenges, 1);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      }, () => client);
    });
  }
  for (final status in [400, 404]) {
    testWidgets('配置出错（$status）时给出修改提示，修正后可继续', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 720);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = EmptyStore();
      final client = MockClient((request) async {
        if (request.url.path == '/apps/personal-app') {
          // Private apps 404 on api.github.com; the page is the only check.
          return http.Response('<html>personal-app</html>', 200);
        }
        if (request.bodyFields['client_id'] == '123456') {
          return http.Response('', status);
        }
        expect(request.bodyFields['client_id'], 'client-correct');
        return http.Response(
          jsonEncode({
            'device_code': 'device-test',
            'user_code': 'TEST-1234',
            'interval': 5,
            'expires_in': 900,
          }),
          200,
        );
      });

      await http.runWithClient(() async {
        await tester.pumpWidget(MaterialApp(home: ConnectPage(store)));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('我已经创建过 GitHub App'));
        await tester.tap(find.text('我已经创建过 GitHub App'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).at(0), '123456');
        await tester.enterText(find.byType(TextField).at(1), 'personal-app');
        await tester.ensureVisible(find.text('保存并继续'));
        await tester.tap(find.text('保存并继续'));
        await tester.pumpAndSettle();

        expect(find.text('第 2 步：填写连接信息'), findsOneWidget);
        final message = status == 400
            ? '请在 GitHub App 设置页勾选 Enable Device Flow'
            : 'GitHub 没有识别这个 Client ID';
        expect(find.textContaining(message), findsOneWidget);
        expect(find.textContaining('不是 App ID'), findsWidgets);
        expect(find.text('重新获取设备码'), findsNothing);
        expect(store.values['githubApp'], isNull);

        await tester.enterText(find.byType(TextField).at(0), 'client-correct');
        await tester.pump();
        expect(find.textContaining(message), findsNothing);
        await tester.ensureVisible(find.text('保存并继续'));
        await tester.tap(find.text('保存并继续'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('TEST-1234'), findsOneWidget);
        expect(store.values['githubApp'], {
          'clientId': 'client-correct',
          'appSlug': 'personal-app',
        });
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      }, () => client);
    });
  }

  testWidgets('填错 App 名称时提示修正，且不保存配置', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 720);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = EmptyStore();
    var challenges = 0;
    final client = MockClient((request) async {
      if (request.url.path.startsWith('/apps/')) {
        final slug = request.url.pathSegments.last;
        return slug == 'personal-app'
            ? http.Response('<html>personal-app</html>', 200)
            : http.Response('Not Found', 404);
      }
      challenges++;
      expect(request.url.path, '/login/device/code');
      return http.Response(
        jsonEncode({
          'device_code': 'device-test',
          'user_code': 'TEST-1234',
          'interval': 5,
          'expires_in': 900,
        }),
        200,
      );
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(home: ConnectPage(store)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('我已经创建过 GitHub App'));
      await tester.tap(find.text('我已经创建过 GitHub App'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'client-test');
      await tester.enterText(
        find.byType(TextField).at(1),
        'https://github.com/settings/apps/typo-app',
      );
      await tester.ensureVisible(find.text('保存并继续'));
      await tester.tap(find.text('保存并继续'));
      await tester.pumpAndSettle();

      expect(find.textContaining('GitHub 上没有找到这个 App'), findsOneWidget);
      expect(challenges, 0);
      expect(store.values['githubApp'], isNull);

      await tester.enterText(find.byType(TextField).at(1), 'personal-app');
      await tester.pump();
      expect(find.textContaining('GitHub 上没有找到这个 App'), findsNothing);
      await tester.ensureVisible(find.text('保存并继续'));
      await tester.tap(find.text('保存并继续'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('TEST-1234'), findsOneWidget);
      expect(store.values['githubApp'], {
        'clientId': 'client-test',
        'appSlug': 'personal-app',
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => client);
  });
  testWidgets('私有 App 通过校验：不依赖会隐藏私有 App 的匿名 API', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 720);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = EmptyStore();
    var anonymousApiCalls = 0;
    final client = MockClient((request) async {
      if (request.url.host == 'api.github.com') {
        // 匿名 apps/<slug> 接口对所有私有 App 都返回 404。
        anonymousApiCalls++;
        return http.Response('{"message":"Not Found"}', 404);
      }
      if (request.url.path == '/apps/private-app') {
        return http.Response('private-app is a private GitHub App.', 200);
      }
      expect(request.url.path, '/login/device/code');
      return http.Response(
        jsonEncode({
          'device_code': 'device-test',
          'user_code': 'TEST-1234',
          'interval': 5,
          'expires_in': 900,
        }),
        200,
      );
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(home: ConnectPage(store)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('我已经创建过 GitHub App'));
      await tester.tap(find.text('我已经创建过 GitHub App'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'client-test');
      await tester.enterText(find.byType(TextField).at(1), 'private-app');
      await tester.ensureVisible(find.text('保存并继续'));
      await tester.tap(find.text('保存并继续'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('GitHub 上没有找到这个 App'), findsNothing);
      expect(find.text('TEST-1234'), findsOneWidget);
      expect(anonymousApiCalls, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => client);
  });
  testWidgets('校验超时不阻断连接：网络抖动时仍能继续', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 720);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = EmptyStore();
    final client = MockClient((request) async {
      if (request.url.path.startsWith('/apps/')) {
        // 慢速或被拦截的网络：辅助校验拿不到结果。
        throw TimeoutException('slow', const Duration(seconds: 8));
      }
      expect(request.url.path, '/login/device/code');
      return http.Response(
        jsonEncode({
          'device_code': 'device-test',
          'user_code': 'TEST-1234',
          'interval': 5,
          'expires_in': 900,
        }),
        200,
      );
    });

    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(home: ConnectPage(store)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('我已经创建过 GitHub App'));
      await tester.tap(find.text('我已经创建过 GitHub App'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'client-test');
      await tester.enterText(find.byType(TextField).at(1), 'slow-app');
      await tester.ensureVisible(find.text('保存并继续'));
      await tester.tap(find.text('保存并继续'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('TimeoutException'), findsNothing);
      expect(find.text('TEST-1234'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }, () => client);
  });
}
