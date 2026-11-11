import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
      await tester.pumpWidget(MaterialApp(home: AlbumHome(EmptyStore())));
      await tester.pumpAndSettle();
      expect(find.text('连接我的 GitHub'), findsOneWidget);
      await tester.tap(find.text('连接我的 GitHub'));
      await tester.pumpAndSettle();
      expect(find.text('获取设备码'), findsOneWidget);
      expect(find.text('GitHub App Client ID'), findsOneWidget);
      await tester.tap(find.text('获取设备码'));
      await tester.pumpAndSettle();
      expect(find.text('请输入 GitHub App 的公开 Client ID'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('连接我的 GitHub'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      messenger.setMockMethodCallHandler(channel, null);
    });
  }
}
