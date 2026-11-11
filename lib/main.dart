import 'dart:io';

import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';

import 'src/home.dart';
import 'src/scheduler.dart';
import 'src/store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AlbumApp());
}

class AlbumApp extends StatelessWidget {
  const AlbumApp({super.key});
  static Future<Store> start() async {
    if (Platform.isAndroid) await Workmanager().initialize(dispatcher);
    return Store.open();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '泊光相册',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff28665b)),
      scaffoldBackgroundColor: const Color(0xfff8faf7),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: FutureBuilder<Store>(
      future: start(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(child: SelectableText('无法打开本机相册\n${snapshot.error}')),
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
