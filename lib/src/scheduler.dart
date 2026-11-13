import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:workmanager/workmanager.dart';

import 'backup.dart';
import 'catalog.dart';
import 'github.dart';
import 'store.dart';
import 'text.dart';

@pragma('vm:entry-point')
void dispatcher() {
  Workmanager().executeTask((_, _) async {
    WidgetsFlutterBinding.ensureInitialized();
    final store = await Store.open();
    final binding = await store.pref('binding') as Json?;
    final client = http.Client();
    try {
      if (binding == null ||
          await store.pref('paused:${binding['target']}') == true) {
        return true;
      }
      return await Backup(store, binding, client).run();
    } catch (e) {
      if (binding == null) return true;
      final target = binding['target'];
      if (e is ApiError && e.status == 401) {
        await store.set('authRequired:$target', true);
      }
      await store.set('status:$target', readable(e));
      if (e is ApiError && e.retryAt != null) {
        await store.set('retry:$target', e.retryAt!.millisecondsSinceEpoch);
      }
      return false;
    } finally {
      client.close();
      await store.close();
    }
  });
}

Future<void> schedule(Store store) async {
  if (!Platform.isAndroid) return;
  final constraints = Constraints(
    networkType: await store.pref('cellular') == true
        ? NetworkType.connected
        : NetworkType.unmetered,
    requiresBatteryNotLow: true,
  );
  await Workmanager().registerPeriodicTask(
    'photoalbum-periodic',
    'backup',
    frequency: const Duration(minutes: 15),
    constraints: constraints,
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
  );
  await Workmanager().registerOneOffTask(
    'photoalbum-queue',
    'backup',
    constraints: constraints,
    existingWorkPolicy: ExistingWorkPolicy.keep,
  );
}
