import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:workmanager/workmanager.dart';

import 'backup.dart';
import 'catalog.dart';
import 'connect.dart';
import 'github.dart';
import 'scheduler.dart';
import 'store.dart';
import 'theme.dart';

class AlbumHome extends StatefulWidget {
  const AlbumHome(this.store, {super.key});
  final Store store;
  @override
  State<AlbumHome> createState() => _AlbumHomeState();
}

class _AlbumHomeState extends State<AlbumHome> with WidgetsBindingObserver {
  Store get store => widget.store;
  final client = http.Client();
  Backup? backup;
  List<Json> photos = [], jobs = [];
  Set<String> selection = {};
  Json? selected;
  int tab = 0;
  bool busy = false,
      running = false,
      paused = false,
      cellular = false,
      automatic = false,
      loaded = false;
  String? notice, status, scanInfo;
  bool noticeError = false;
  List<Json> removals = [];
  Timer? timer;
  StreamSubscription<List<ConnectivityResult>>? connectivity;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(guard(initialize));
    connectivity = Connectivity().onConnectivityChanged.listen(
      (_) => unawaited(runQueue()),
    );
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && backup != null && !busy) {
        unawaited(guardSilent(reload));
        if (!running &&
            !paused &&
            (jobs.any((j) => j['stage'] != '已备份' && j['error'] == null) ||
                removals.any((r) => r['error'] == null) ||
                status != null ||
                // Android schedules scans through WorkManager; desktop scans
                // while the window is open.
                (automatic && !Platform.isAndroid))) {
          unawaited(runQueue());
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !busy && backup != null) {
      unawaited(runQueue());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    connectivity?.cancel();
    client.close();
    super.dispose();
  }

  void message(String text, {bool error = false}) {
    if (mounted) {
      setState(() {
        notice = text;
        noticeError = error;
      });
    }
  }

  Future<void> guardSilent(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      message(readable(e), error: true);
    }
  }

  Future<void> guard(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      notice = null;
    });
    try {
      await action();
    } catch (e) {
      message(readable(e), error: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> initialize() async {
    final binding = await store.pref('binding') as Json?;
    backup = binding == null ? null : Backup(store, binding, client);
    await reload();
    if (backup != null) {
      await schedule(store);
      await guardSilent(backup!.refresh);
      await reload();
      unawaited(runQueue());
    }
  }

  Future<void> reload() async {
    final b = backup;
    final target = b?.target;
    final data = target == null ? <Json>[] : await store.photos(target);
    final queue = target == null ? <Json>[] : await store.jobs(target);
    final pause = await store.pref('paused:$target') == true;
    final cell = await store.pref('cellular') == true;
    final auto = await store.pref('auto:$target') != null;
    final info = await store.pref('status:$target') as String?;
    final scan = await store.pref('scanInfo:$target') as String?;
    final pending = target == null
        ? <Json>[]
        : (await store.db.query(
            'removals',
            columns: ['data'],
            where: 'target=?',
            whereArgs: [target],
          )).map((r) => jsonDecode(r['data'] as String) as Json).toList();
    if (!mounted || backup != b) return;
    setState(() {
      photos = data;
      jobs = queue;
      paused = pause;
      cellular = cell;
      automatic = auto;
      status = info;
      scanInfo = scan;
      removals = pending;
      loaded = true;
      selection.retainAll(data.map((p) => p['id'] as String));
      if (selected != null &&
          !data.any((p) => p['id'] == selected!['id'])) {
        selected = null;
      }
    });
  }

  Future<void> runQueue() async {
    final b = backup;
    if (running || b == null) return;
    if (mounted) setState(() => running = true);
    try {
      await b.run();
    } catch (e) {
      if (e is ApiError && e.status == 401) {
        await store.set('authRequired:${b.target}', true);
      }
      if (e is ApiError && e.retryAt != null) {
        await store.set('retry:${b.target}', e.retryAt!.millisecondsSinceEpoch);
      }
      await store.set('status:${b.target}', readable(e));
    } finally {
      if (mounted) {
        setState(() => running = false);
        await guardSilent(reload);
      }
    }
  }

  Future<bool> confirm(
    String title,
    String body,
    String action, {
    bool danger = false,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(body)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              style: danger
                  ? FilledButton.styleFrom(
                      backgroundColor: Theme.of(c).colorScheme.error,
                      foregroundColor: Theme.of(c).colorScheme.onError,
                    )
                  : null,
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> connect() async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => ConnectPage(store)),
    );
    if (ok == true && mounted) {
      setState(() {
        tab = 0;
        selection.clear();
      });
      await initialize();
    }
  }

  Future<void> pick() async {
    final b = backup!;
    if (await store.pref('consent:${b.target}') != true) {
      if (!await confirm('开始单向备份？', '$oneWay\n\n仅备份静态照片。', '选择照片')) return;
      await store.set('consent:${b.target}', true);
    }
    bool fileOriginal = false;
    if (Platform.isAndroid) {
      if (!mounted) return;
      final mode = await showDialog<bool>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('选择照片来源'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, false),
              child: const ListTile(
                title: Text('系统照片选择器'),
                subtitle: Text('按系统授权读取，位置元数据可能被隐去。'),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, true),
              child: const ListTile(
                title: Text('从文件选择原件'),
                subtitle: Text('从本机文件夹读取所选文件。'),
              ),
            ),
          ],
        ),
      );
      if (mode == null) return;
      fileOriginal = mode;
    }
    await b.pick(fileOriginal: fileOriginal);
    await reload();
    await schedule(store);
    unawaited(runQueue());
  }

  Future<void> startAlbumBackup({
    required bool existing,
    required bool enableAuto,
  }) async {
    final b = backup!;
    if (Platform.isAndroid) await dialogs.invokeMethod('permission');
    if (await media.invokeMethod('permission') != 'full') {
      throw StateError('备份整个相册需要完整照片权限。你也可以用「选择照片」备份部分照片。');
    }
    final end = plainMap(await media.invokeMethod('snapshot'));
    final start = initialMediaCursor(end, includeExisting: existing);
    if (existing) {
      final rows = await b.changes(start, end);
      final bytes = rows.fold<int>(0, (n, v) => n + (v['size'] as int? ?? 0));
      if (!mounted) return;
      var futurePhotos = enableAuto || automatic;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => StatefulBuilder(
          builder: (c, update) => AlertDialog(
            title: const Text('备份已有照片？'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "可读取 ${rows.length} 张，原图共 ${sizeLabel(bytes)}。\n备份到 ${b.binding['name']}。\n\n$oneWay",
                  ),
                  if (!enableAuto && !automatic)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('以后也自动备份新照片'),
                      value: futurePhotos,
                      onChanged: (v) => update(() => futurePhotos = v == true),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('开始备份'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true) return;
      await store.enqueue(b.target, rows);
      enableAuto = futurePhotos;
    }
    if (enableAuto && !automatic) {
      await store.set('auto:${b.target}', advanceMediaCursor(start, end));
      await store.set('scanInfo:${b.target}', null);
    }
    await store.set('consent:${b.target}', true);
    await schedule(store);
    await reload();
    if (mounted && existing) setState(() => tab = 1);
    unawaited(runQueue());
  }

  Future<void> auto(bool enable) async {
    final b = backup!;
    if (enable) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('自动备份从哪里开始？'),
          contentPadding: const EdgeInsets.all(24),
          children: [
            const Text('$oneWay\n\n仅备份静态照片。'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('从现在开始'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('同时备份已有照片'),
            ),
          ],
        ),
      );
      if (choice == null) return;
      await startAlbumBackup(existing: choice, enableAuto: true);
      return;
    }
    await store.workLock.transaction(
      (_) => store.set('auto:${b.target}', null),
    );
    await store.set('scanInfo:${b.target}', null);
    await reload();
    unawaited(runQueue());
  }

  Future<void> pause(bool next) async {
    await store.set('paused:${backup!.target}', next);
    await reload();
    if (!next) {
      await schedule(store);
      unawaited(runQueue());
    }
  }

  Future<void> refresh() async {
    await backup!.refresh();
    await reload();
  }

  Future<void> export(List<Json> items) async {
    final b = backup!;
    final desktop = Platform.isWindows || Platform.isMacOS;
    final folder = desktop
        ? await getDirectoryPath(confirmButtonText: '导出到这里')
        : null;
    if (desktop && folder == null) return;
    var count = 0;
    for (final photo in items) {
      try {
        final file = await b.download(photo, thumbnail: false);
        try {
          if (folder != null) {
            await exportVerified(file, Directory(folder), photo['name']);
          } else if (await dialogs.invokeMethod<bool>('export', {
                'path': file.path,
                'name': exportName(photo['name']),
              }) !=
              true) {
            break;
          }
          count++;
        } finally {
          if (await file.exists()) await file.delete();
        }
      } catch (e) {
        throw StateError("${photo['name']}：${readable(e)}（已导出 $count 张）");
      }
    }
    if (count > 0) {
      message('已校验并导出 $count 张原图${folder == null ? '' : '到 $folder'}');
    }
  }

  Future<void> detail(Json photo) async {
    if (MediaQuery.sizeOf(context).width >= 1000) {
      setState(() => selected = photo);
      return;
    }
    final b = backup!;
    final action = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(photo['name'], overflow: TextOverflow.ellipsis),
        content: SingleChildScrollView(
          child: SizedBox(width: 480, child: detailInfo(b, photo)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, 'delete'),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(c).colorScheme.error,
            ),
            child: const Text('删除云端备份'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, 'export'),
            child: const Text('下载原图'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    await detailAction(photo, action);
  }

  Future<void> detailAction(Json photo, String? action) async {
    final b = backup!;
    if (action == 'export') await export([photo]);
    if (action == 'delete' &&
        await confirm(
          '删除云端备份？',
          "${photo['name']}\n\n将从 ${b.binding['name']} 移除原图附件 #${photo['original']}、缩略图附件 #${photo['thumbnail']} 和该照片的目录记录。",
          '确认删除',
          danger: true,
        )) {
      await b.requestRemoval(photo);
      if (mounted && selected?['id'] == photo['id']) {
        setState(() => selected = null);
      }
      await reload();
      await schedule(store);
      await runQueue();
    }
  }

  Future<void> disconnect() async {
    if (!await confirm('断开 GitHub？', '照片仍在你的私有仓库，重新连接即可访问。', '断开连接')) return;
    await store.disconnect();
    if (Platform.isAndroid) {
      await Workmanager().cancelByUniqueName('photoalbum-queue');
      await Workmanager().cancelByUniqueName('photoalbum-periodic');
    }
    selection.clear();
    selected = null;
    await initialize();
  }

  static const icons = [
    Icons.photo_library_outlined,
    Icons.cloud_upload_outlined,
    Icons.settings_outlined,
  ];
  static const selectedIcons = [
    Icons.photo_library_rounded,
    Icons.cloud_upload_rounded,
    Icons.settings_rounded,
  ];
  static const labels = ['照片', '备份', '设置'];

  Widget empty(IconData icon, String title, String text, {Widget? action}) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 390),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLowest,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: 40,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                title,
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              if (action != null) ...[const SizedBox(height: 24), action],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 760;
    final deskDetail = width >= 1000;
    final colors = Theme.of(context).colorScheme;
    final b = backup;
    final page = !loaded
        ? const Center(child: CircularProgressIndicator())
        : b == null
        ? empty(
            Icons.photo_library_outlined,
            '你的照片备份',
            '连接 GitHub 私有仓库，即可备份照片或打开已有相册。',
            action: FilledButton.icon(
              onPressed: busy ? null : () => guard(connect),
              icon: const Icon(Icons.link_rounded, size: 19),
              label: const Text('连接我的 GitHub'),
            ),
          )
        : switch (tab) {
            0 => RefreshIndicator(
              onRefresh: () => guard(refresh),
              child: album(b),
            ),
            1 => queue(),
            _ => settings(b),
          };
    return Scaffold(
      appBar: AppBar(
        title: const Text('映格'),
        actions: [
          if (b != null)
            IconButton(
              onPressed: busy ? null : () => guard(refresh),
              tooltip: '刷新远端目录',
              icon: const Icon(Icons.refresh_rounded),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Row(
        children: [
          if (wide && b != null)
            NavigationRail(
              selectedIndex: tab,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (i) => setState(() => tab = i),
              destinations: [
                for (var i = 0; i < 3; i++)
                  NavigationRailDestination(
                    icon: Icon(icons[i]),
                    selectedIcon: Icon(selectedIcons[i]),
                    label: Text(labels[i]),
                  ),
              ],
            ),
          Expanded(
            child: Column(
              children: [
                if (busy) const LinearProgressIndicator(minHeight: 2),
                if (notice != null)
                  Material(
                    color: noticeError
                        ? colors.errorContainer
                        : colors.secondaryContainer,
                    child: ListTile(
                      leading: Icon(
                        noticeError
                            ? Icons.error_outline_rounded
                            : Icons.info_outline_rounded,
                        color: noticeError ? colors.onErrorContainer : null,
                      ),
                      title: Text(
                        notice!,
                        style: noticeError
                            ? TextStyle(color: colors.onErrorContainer)
                            : null,
                      ),
                      trailing: IconButton(
                        onPressed: () => setState(() => notice = null),
                        icon: const Icon(Icons.close),
                        tooltip: '关闭',
                      ),
                    ),
                  ),
                Expanded(child: page),
              ],
            ),
          ),
          if (deskDetail && b != null && selected != null)
            detailPanel(b, selected!),
        ],
      ),
      bottomNavigationBar: !wide && b != null
          ? NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (v) => setState(() => tab = v),
              destinations: [
                for (var i = 0; i < 3; i++)
                  NavigationDestination(
                    icon: Icon(icons[i]),
                    selectedIcon: Icon(selectedIcons[i]),
                    label: labels[i],
                  ),
              ],
            )
          : null,
    );
  }

  Widget detailInfo(Backup b, Json photo) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 240,
          width: double.infinity,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Thumb(b, photo, fit: BoxFit.contain),
        ),
        const SizedBox(height: 16),
        Text(
          '${dateLabel(photo)} · ${sizeLabel(photo['size'])}',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.check_circle_rounded, size: 18, color: backupDoneColor(context)),
            const SizedBox(width: 6),
            Text(
              '已备份',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: backupDoneColor(context),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: const Text('文件校验信息'),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                "SHA-256\n${photo['sha256']}",
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget detailPanel(Backup b, Json photo) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return SizedBox(
      width: 360,
      child: Material(
        color: colors.surface,
        shape: Border(left: BorderSide(color: colors.outlineVariant)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      photo['name'],
                      style: theme.textTheme.titleLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    onPressed: () => setState(() => selected = null),
                    tooltip: '关闭详情',
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
                children: [detailInfo(b, photo)],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () => guard(() => detailAction(photo, 'export')),
                      icon: const Icon(Icons.download_rounded, size: 19),
                      label: const Text('下载原图'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => guard(() => detailAction(photo, 'delete')),
                        style: TextButton.styleFrom(
                          foregroundColor: colors.error,
                        ),
                        child: const Text('删除云端备份'),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setState(() => selected = null),
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget album(Backup b) {
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final pendingCount = jobs.where((j) => j['stage'] != '已备份').length;
    final groups = <String, List<Json>>{};
    for (final photo in photos) {
      final date = DateTime.parse(photo['takenAt']).toLocal();
      final month = '${date.year}年${date.month}月';
      groups.putIfAbsent(month, () => []).add(photo);
    }

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('照片', style: theme.textTheme.headlineMedium),
                          const SizedBox(height: 4),
                          Text(
                            '${photos.length} 张照片已备份',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: busy ? null : () => guard(pick),
                      icon: const Icon(Icons.add_rounded, size: 20),
                      label: const Text('选择照片'),
                    ),
                  ],
                ),
                if (pendingCount > 0) ...[
                  const SizedBox(height: 14),
                  Material(
                    color: theme.colorScheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => setState(() => tab = 1),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.cloud_upload_outlined,
                              size: 22,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '$pendingCount 张照片在备份队列中',
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      color: theme.colorScheme.onSurface,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '查看备份进度与处理状态',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                if (albumScanSupported || selection.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (albumScanSupported)
                        OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () => guard(
                                  () => startAlbumBackup(
                                    existing: true,
                                    enableAuto: false,
                                  ),
                                ),
                          icon: const Icon(Icons.backup_outlined, size: 18),
                          label: Text(
                            Platform.isAndroid ? '备份手机已有照片' : '备份系统相册',
                          ),
                        ),
                      if (selection.isNotEmpty)
                        FilledButton.tonalIcon(
                          onPressed: busy
                              ? null
                              : () => guard(
                                  () => export(
                                    photos
                                        .where(
                                          (v) => selection.contains(v['id']),
                                        )
                                        .toList(),
                                  ),
                                ),
                          icon: const Icon(Icons.download_outlined, size: 18),
                          label: Text('导出所选（${selection.length}）'),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        if (photos.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: empty(
              Icons.collections_outlined,
              pendingCount > 0 ? '照片已加入备份队列' : '相册里还没有照片',
              pendingCount > 0
                  ? '备份完成后会显示在这里，点击上方可查看进度。'
                  : '选择本机照片开始备份，或刷新已绑定仓库的目录。',
            ),
          )
        else
          for (final group in groups.entries) ...[
            SliverPersistentHeader(
              pinned: true,
              delegate: _MonthHeader(
                group.key,
                theme.textTheme.titleMedium,
                theme.scaffoldBackgroundColor,
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: wide ? 20 : 2),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: wide ? 220 : 160,
                  crossAxisSpacing: wide ? 6 : 2,
                  mainAxisSpacing: wide ? 6 : 2,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => photoTile(b, group.value[index]),
                  childCount: group.value.length,
                ),
              ),
            ),
          ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget photoTile(Backup b, Json photo) {
    final id = photo['id'] as String;
    return _PhotoTile(
      backup: b,
      photo: photo,
      selected: selection.contains(id),
      active: selected?['id'] == id,
      busy: busy,
      onOpen: () => guard(() => detail(photo)),
      onSelect: (v) => setState(() {
        if (v) {
          selection.add(id);
        } else {
          selection.remove(id);
        }
      }),
    );
  }

  Widget infoRow(IconData icon, String title, String subtitle) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyLarge),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget queue() {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final uploads = jobs.where((j) => j['stage'] != '已备份').toList();
    final pending = [...removals, ...uploads];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('备份进度', style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 5),
                  Text(
                    '照片备份状态与队列',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Material(
                    color: colors.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                paused
                                    ? Icons.pause_circle_outline
                                    : status != null
                                    ? Icons.error_outline
                                    : running
                                    ? Icons.cloud_sync_outlined
                                    : Icons.cloud_done_outlined,
                                color: paused
                                    ? colors.onSurfaceVariant
                                    : status != null
                                    ? colors.error
                                    : backupDoneColor(context),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  paused
                                      ? '队列已暂停'
                                      : status ?? (running ? '正在检查队列' : '队列就绪'),
                                  style: theme.textTheme.titleMedium,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '已备份 ${photos.length} 张 · 待完成 ${uploads.length} 张',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          if (removals.isNotEmpty)
                            Text(
                              '待删除 ${removals.length} 张',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          if (uploads.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: photos.length /
                                    (photos.length + uploads.length),
                                minHeight: 6,
                              ),
                            ),
                          ],
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton(
                                onPressed: () => guard(() => pause(!paused)),
                                child: Text(paused ? '继续备份' : '暂停队列'),
                              ),
                              TextButton(
                                onPressed: paused || running
                                    ? null
                                    : () => guard(runQueue),
                                child: const Text('立即重试'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: pending.isEmpty
                  ? Center(
                      child: Text(
                        '暂无等待处理的照片',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      itemCount: pending.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (c, i) {
                        final j = pending[i];
                        final failed = j['error'] != null;
                        final removal = i < removals.length;
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 4,
                          ),
                          leading: Icon(
                            failed
                                ? Icons.error_outline
                                : removal
                                ? Icons.delete_outline_rounded
                                : Icons.schedule_rounded,
                            color: failed ? colors.error : colors.onSurfaceVariant,
                          ),
                          title: Text(
                            j['name'],
                            style: theme.textTheme.bodyLarge,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            [
                              removal ? '待删除' : j['stage'],
                              if (j['error'] != null) j['error'],
                            ].join(' · '),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: failed ? colors.error : colors.onSurfaceVariant,
                            ),
                          ),
                          trailing: j['confirmAgain'] == true
                              ? TextButton(
                                  onPressed: busy
                                      ? null
                                      : () => guard(() async {
                                          final target = backup!.target;
                                          await store.db.delete(
                                            'removals',
                                            where:
                                                'target=? AND path=? AND data=?',
                                            whereArgs: [
                                              target,
                                              j['path'],
                                              jsonEncode(j),
                                            ],
                                          );
                                          await reload();
                                        }),
                                  child: const Text('取消删除请求'),
                                )
                              : null,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget settings(Backup b) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          children: [
            Text('设置', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 5),
            Text(
              '管理相册与备份偏好',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            Text('已连接的相册', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            Material(
              color: colors.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(16),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 4,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                leading: Icon(
                  Icons.lock_outline_rounded,
                  color: colors.onSurfaceVariant,
                ),
                title: Text(b.binding['name']),
                subtitle: Text("已连接 · ${b.binding['login']}"),
              ),
            ),
            const SizedBox(height: 24),
            Text('备份偏好', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            Material(
              color: colors.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  if (albumScanSupported)
                    SwitchListTile(
                      value: automatic,
                      title: const Text('自动备份新照片'),
                      subtitle: Text(scanInfo ?? '使用系统相册的新增记录发现照片'),
                      onChanged: busy ? null : (v) => guard(() => auto(v)),
                    ),
                  SwitchListTile(
                    value: cellular,
                    title: const Text('允许移动数据上传'),
                    onChanged: busy
                        ? null
                        : (v) => guard(() async {
                            await store.set('cellular', v);
                            await schedule(store);
                            await reload();
                            unawaited(runQueue());
                          }),
                  ),
                  infoRow(
                    Icons.image_outlined,
                    '原图质量',
                    '保留静态照片原始文件，缩略图单独生成。',
                  ),
                  if (Platform.isWindows || Platform.isMacOS)
                    infoRow(
                      Platform.isWindows
                          ? Icons.desktop_windows_outlined
                          : Icons.laptop_mac_outlined,
                      '窗口打开时继续备份',
                      '关闭后保留队列，下次打开继续。',
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text('账户', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            Material(
              color: colors.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.key_outlined),
                    title: const Text('重新授权'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: busy ? null : () => guard(connect),
                  ),
                  ListTile(
                    leading: const Icon(Icons.link_off_rounded),
                    title: const Text('断开 GitHub'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: busy ? null : () => guard(disconnect),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthHeader extends SliverPersistentHeaderDelegate {
  _MonthHeader(this.label, this.style, this.background);
  final String label;
  final TextStyle? style;
  final Color background;
  @override
  double get minExtent => 42;
  @override
  double get maxExtent => 42;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Container(
    color: background,
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
    child: Text(label, style: style),
  );
  @override
  bool shouldRebuild(_MonthHeader old) =>
      old.label != label || old.background != background;
}

String sizeLabel(int n) => n < 1024 * 1024
    ? '${(n / 1024).toStringAsFixed(0)} KB'
    : '${(n / 1048576).toStringAsFixed(1)} MB';
String dateLabel(Json p) =>
    DateTime.parse(p['takenAt']).toLocal().toString().substring(0, 10);

class Thumb extends StatefulWidget {
  const Thumb(this.backup, this.photo, {super.key, this.fit = BoxFit.cover});
  final Backup backup;
  final Json photo;
  final BoxFit fit;
  @override
  State<Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<Thumb> {
  late Future<File> file = load();
  Future<File> load({bool refresh = false, File? invalid}) async {
    if (invalid != null) await FileImage(invalid).evict();
    return widget.backup.download(
      widget.photo,
      thumbnail: true,
      refreshThumbnail: refresh,
    );
  }

  Widget retry(String reason, [File? invalid]) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: '$reason · 点击重新下载',
      child: InkWell(
        onTap: () =>
            setState(() => file = load(refresh: true, invalid: invalid)),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image_outlined, color: colors.onSurfaceVariant),
              const SizedBox(height: 6),
              Text('加载失败', style: Theme.of(context).textTheme.bodySmall),
              Text(
                '点击重试',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<File>(
    future: file,
    builder: (context, v) {
      if (v.hasError) {
        return retry(readable(v.error!));
      }
      if (!v.hasData) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.image_outlined,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 6),
              Text(
                '加载中',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      }
      return Image.file(
        v.requireData,
        fit: widget.fit,
        errorBuilder: (c, e, s) => retry('缩略图无法解码', v.requireData),
      );
    },
  );
}

class _PhotoTile extends StatefulWidget {
  const _PhotoTile({
    required this.backup,
    required this.photo,
    required this.selected,
    required this.active,
    required this.busy,
    required this.onOpen,
    required this.onSelect,
  });
  final Backup backup;
  final Json photo;
  final bool selected, active, busy;
  final VoidCallback onOpen;
  final ValueChanged<bool> onSelect;
  @override
  State<_PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<_PhotoTile> {
  bool hover = false;
  @override
  Widget build(BuildContext context) {
    final photo = widget.photo;
    final id = photo['id'] as String;
    final colors = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 760;
    return Semantics(
      label: "${photo['name']}，${dateLabel(photo)}",
      button: true,
      child: Tooltip(
        message: photo['name'],
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(wide ? 6 : 3),
            border: Border.all(
              color: widget.selected || widget.active
                  ? colors.primary
                  : Colors.transparent,
              width: 2,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(wide ? 4 : 1.5),
            child: Material(
              color: colors.surfaceContainerHighest,
              child: InkWell(
                onTap: widget.busy ? null : widget.onOpen,
                child: MouseRegion(
                  onEnter: (_) => setState(() => hover = true),
                  onExit: (_) => setState(() => hover = false),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Thumb(
                        widget.backup,
                        photo,
                        key: ValueKey('${widget.backup.target}:$id'),
                      ),
                      if (widget.selected)
                        ColoredBox(
                          color: colors.primary.withValues(alpha: 0.18),
                        ),
                      if ((Platform.isWindows || Platform.isMacOS) &&
                          (widget.selected || hover))
                        Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Checkbox(
                              value: widget.selected,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                              onChanged: (v) => widget.onSelect(v == true),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
