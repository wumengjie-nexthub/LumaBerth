import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumaberth/src/connect.dart';
import 'package:lumaberth/src/home.dart';
import 'package:lumaberth/src/store.dart';

class EmptyStore extends Fake implements Store {
  @override
  Future<dynamic> pref(String key) async => null;
}

void main() {
  for (final width in [360.0, 1280.0]) {
    testWidgets('首次打开和进入 GitHub 绑定页面，窗口宽度 $width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 720);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messenger = tester.binding.defaultBinaryMessenger;
      const channel = MethodChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      );
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      final client = MockClient((request) async {
        expect(request.url.toString(), 'https://github.com/login/device/code');
        expect(request.bodyFields['client_id'], 'Iv23li13AQFhUby41bqD');
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
        await tester.pumpWidget(MaterialApp(home: AlbumHome(EmptyStore())));
        await tester.pumpAndSettle();
        await tester.tap(find.text('连接我的 GitHub'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          tester.widget<ConnectPage>(find.byType(ConnectPage)).appSlug,
          'lumaberth',
        );
        expect(find.text('DEMO-1234'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('连接我的 GitHub'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      }, () => client);
      messenger.setMockMethodCallHandler(channel, null);
    });
  }
}
