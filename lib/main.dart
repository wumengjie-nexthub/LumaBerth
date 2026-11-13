import 'dart:io';

import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';

import 'src/home.dart';
import 'src/scheduler.dart';
import 'src/store.dart';
import 'src/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AlbumApp());
}

class AlbumApp extends StatefulWidget {
  const AlbumApp({super.key});
  static Future<Store> start() async {
    if (Platform.isAndroid) await Workmanager().initialize(dispatcher);
    return Store.open();
  }

  @override
  State<AlbumApp> createState() => _AlbumAppState();
}

class _AlbumAppState extends State<AlbumApp> {
  Future<Store> future = AlbumApp.start();

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '映格',
    debugShowCheckedModeBanner: false,
    theme: albumTheme(brightness: Brightness.light),
    darkTheme: albumTheme(brightness: Brightness.dark),
    home: FutureBuilder<Store>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SelectableText(
                      '无法打开本机相册\n${snapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: () =>
                          setState(() => future = AlbumApp.start()),
                      icon: const Icon(Icons.refresh_rounded, size: 19),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return AlbumHome(snapshot.requireData);
      },
    ),
  );
}
