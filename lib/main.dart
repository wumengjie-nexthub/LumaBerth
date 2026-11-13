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

class AlbumApp extends StatelessWidget {
  const AlbumApp({super.key});
  static Future<Store> start() async {
    if (Platform.isAndroid) await Workmanager().initialize(dispatcher);
    return Store.open();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '映格',
    debugShowCheckedModeBanner: false,
    theme: albumTheme(),
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
