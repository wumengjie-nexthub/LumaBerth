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
  bool detail = false;

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
          final theme = Theme.of(context);
          return Scaffold(
            body: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.folder_off_outlined,
                        size: 40,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '无法打开本机相册',
                        style: theme.textTheme.headlineSmall,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '请重试。如果反复出现，可以重启应用后再试一次。',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: () =>
                            setState(() => future = AlbumApp.start()),
                        icon: const Icon(Icons.refresh_rounded, size: 19),
                        label: const Text('重试'),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => setState(() => detail = !detail),
                        child: Text(detail ? '收起详细信息' : '详细信息'),
                      ),
                      if (detail)
                        SelectableText(
                          '${snapshot.error}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                    ],
                  ),
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
