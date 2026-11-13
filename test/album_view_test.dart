import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumaberth/src/catalog.dart';
import 'package:lumaberth/src/home.dart';
import 'package:lumaberth/src/store.dart';
import 'package:lumaberth/src/theme.dart';
import 'package:sqflite/sqflite.dart';

class AlbumDatabase extends Fake implements Database {
  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async => [];
}

class AlbumStore extends Fake implements Store {
  AlbumStore(this.dir);

  @override
  final Directory dir;
  final database = AlbumDatabase();
  final preferences = <String, dynamic>{
    'binding': {
      'target': 'preview',
      'repo': 1,
      'name': 'demo/album',
      'branch': 'main',
      'login': 'demo',
    },
    'paused:preview': true,
  };
  final queued = <Json>[];
  final items = <Json>[
    {
      'id': '00000000-0000-4000-8000-000000000001',
      'name': 'photo-a.jpg',
      'takenAt': '2026-11-12T12:00:00Z',
      'size': 1024,
      'sha256':
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'original': 201,
      'thumbnail': 101,
    },
    {
      'id': '00000000-0000-4000-8000-000000000002',
      'name': 'photo-b.jpg',
      'takenAt': '2026-10-12T12:00:00Z',
      'size': 2048,
      'sha256':
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'original': 202,
      'thumbnail': 102,
    },
  ];

  @override
  Database get db => database;
  @override
  Database get workLock => database;
  @override
  Future<dynamic> pref(String key) async => preferences[key];
  @override
  Future<void> set(String key, dynamic value) async => preferences[key] = value;
  @override
  Future<List<Json>> photos(String target) async => items;
  @override
  Future<List<Json>> jobs(String target) async => queued;
}

void main() {
  for (final width in [320.0, 1280.0]) {
    testWidgets('相册网格和导航可用，窗口宽度 $width', (tester) async {
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

      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('album-view-test-'),
      );
      final store = AlbumStore(dir!);
      await tester.pumpWidget(
        MaterialApp(theme: albumTheme(), home: AlbumHome(store)),
      );
      await tester.pumpAndSettle();

      expect(find.text('2026年11月'), findsOneWidget);
      expect(find.text('2026年10月'), findsOneWidget);
      await tester.tap(find.byTooltip('photo-a.jpg'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('photo-a.jpg'), findsOneWidget);
      expect(find.text('下载原图'), findsOneWidget);
      await tester.tap(find.text('文件校验信息'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('SHA-256'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      if (Platform.isWindows) {
        await tester.tap(find.byType(Checkbox).first);
        await tester.pumpAndSettle();
        expect(find.text('导出所选（1）'), findsOneWidget);
      }

      await tester.tap(find.text('备份').first);
      await tester.pumpAndSettle();
      expect(find.text('队列已暂停'), findsOneWidget);
      await tester.tap(find.text('设置').first);
      await tester.pumpAndSettle();
      expect(find.text('demo/album'), findsOneWidget);
      expect(find.text('允许移动数据上传'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await dir.delete(recursive: true);
      });
    });
    testWidgets('相册首页能看到待备份队列，窗口宽度 $width', (tester) async {
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

      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('album-queue-test-'),
      );
      final store = AlbumStore(dir!)
        ..items.clear()
        ..queued.add({'id': '1', 'name': 'example.jpg', 'stage': '等待备份'});
      await tester.pumpWidget(
        MaterialApp(theme: albumTheme(), home: AlbumHome(store)),
      );
      await tester.pumpAndSettle();

      expect(find.text('1 张照片在备份队列中'), findsOneWidget);
      expect(find.text('照片已加入备份队列'), findsOneWidget);
      await tester.ensureVisible(find.text('1 张照片在备份队列中'));
      await tester.tap(find.text('1 张照片在备份队列中'));
      await tester.pumpAndSettle();
      expect(find.text('备份进度'), findsOneWidget);
      expect(find.text('example.jpg'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await dir.delete(recursive: true);
      });
    });
  }
}
