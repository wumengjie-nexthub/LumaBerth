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
  int tab = 0;
  bool busy = false,
      running = false,
      paused = false,
      cellular = false,
      automatic = false,
      loaded = false;
  String? notice, status, scanInfo;
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
                status != null)) {
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

  void message(String text) {
    if (mounted) setState(() => notice = text);
  }

  Future<void> guardSilent(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      message(readable(e));
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
      message(readable(e));
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

  Future<bool> confirm(String title, String body, String action) async =>
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
    await dialogs.invokeMethod('permission');
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
            title: const Text('备份手机已有照片？'),
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
    final folder = Platform.isWindows
        ? await getDirectoryPath(confirmButtonText: '导出到这里')
        : null;
    if (Platform.isWindows && folder == null) return;
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
    final b = backup!;
    final action = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(photo['name']),
        content: SingleChildScrollView(
          child: SizedBox(
            width: 480,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 260,
                  width: double.infinity,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: Theme.of(c).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Thumb(b, photo, fit: BoxFit.contain),
                ),
                const SizedBox(height: 16),
                Text(
                  "${dateLabel(photo)}   ·   ${sizeLabel(photo['size'])}",
                  style: Theme.of(c).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(c).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  title: const Text('文件校验信息'),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        "SHA-256\n${photo['sha256']}",
                        style: Theme.of(c).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, 'delete'),
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
    if (action == 'export') await export([photo]);
    if (action == 'delete' &&
        await confirm(
          '删除云端备份？',
          "${photo['name']}\n\n将从 ${b.binding['name']} 移除原图附件 #${photo['original']}、缩略图附件 #${photo['thumbnail']} 和该照片的目录记录。",
          '确认删除',
        )) {
      await b.requestRemoval(photo);
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
    await initialize();
  }

  static const icons = [
    Icons.photo_library_outlined,
    Icons.cloud_upload_outlined,
    Icons.tune_rounded,
  ];
  static const selectedIcons = [
    Icons.photo_library_rounded,
    Icons.cloud_upload_rounded,
    Icons.tune_rounded,
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
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(icon, size: 36, color: theme.colorScheme.primary),
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
    final wide = MediaQuery.sizeOf(context).width >= 760;
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
            0 => album(b),
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
                    color: colors.secondaryContainer,
                    child: ListTile(
                      leading: const Icon(Icons.info_outline_rounded),
                      title: Text(notice!),
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
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
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
                      style: TextButton.styleFrom(
                        backgroundColor:
                            theme.colorScheme.surfaceContainerLowest,
                      ),
                      icon: const Icon(Icons.add_rounded, size: 20),
                      label: const Text('选择照片'),
                    ),
                  ],
                ),
                if (pendingCount > 0) ...[
                  const SizedBox(height: 16),
                  panel(
                    child: ListTile(
                      leading: const Icon(Icons.cloud_upload_outlined),
                      title: Text('$pendingCount 张照片在备份队列中'),
                      subtitle: const Text('查看备份进度与处理状态'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => setState(() => tab = 1),
                    ),
                  ),
                ],
                if (Platform.isAndroid || selection.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (Platform.isAndroid)
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
                          label: const Text('备份手机已有照片'),
                        ),
                      if (selection.isNotEmpty)
                        OutlinedButton.icon(
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
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
                child: Text(group.key, style: theme.textTheme.titleMedium),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: wide ? 20 : 0),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: wide ? 210 : 150,
                  crossAxisSpacing: wide ? 8 : 2,
                  mainAxisSpacing: wide ? 8 : 2,
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
    return Semantics(
      label: "${photo['name']}，${dateLabel(photo)}",
      button: true,
      child: Tooltip(
        message: photo['name'],
        child: ClipRRect(
          borderRadius: BorderRadius.circular(
            MediaQuery.sizeOf(context).width >= 760 ? 8 : 2,
          ),
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: InkWell(
              onTap: busy ? null : () => guard(() => detail(photo)),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Thumb(b, photo, key: ValueKey('${b.target}:$id')),
                  if (Platform.isWindows)
                    Align(
                      alignment: Alignment.topLeft,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Material(
                          color: Colors.black54,
                          shape: const CircleBorder(),
                          child: Checkbox(
                            value: selection.contains(id),
                            side: const BorderSide(
                              color: Colors.white,
                              width: 1.5,
                            ),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                selection.add(id);
                              } else {
                                selection.remove(id);
                              }
                            }),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget panel({required Widget child}) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLowest,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );

  Widget queue() {
    final theme = Theme.of(context);
    final uploads = jobs.where((j) => j['stage'] != '已备份').toList();
    final pending = [...removals, ...uploads];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('备份进度', style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 5),
                  Text(
                    '照片备份状态与队列',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 22),
                  panel(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.cloud_done_outlined,
                                color: theme.colorScheme.primary,
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
                          ),
                          if (removals.isNotEmpty)
                            Text('待删除 ${removals.length} 张'),
                          const SizedBox(height: 12),
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
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: pending.length,
                      itemBuilder: (c, i) {
                        final j = pending[i];
                        return ListTile(
                          leading: Icon(
                            j['error'] == null
                                ? Icons.schedule
                                : Icons.error_outline,
                          ),
                          title: Text(j['name']),
                          trailing: j['confirmAgain'] == true
                              ? TextButton(
                                  onPressed: busy
                                      ? null
                                      : () => guard(() async {
                                          final target = backup!.target;
                                          await store.db.delete(
                                            'removals',
                                            where: 'target=? AND path=? AND data=?',
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
                          subtitle: Text(
                            [
                              i < removals.length ? '待删除' : j['stage'],
                              if (j['error'] != null) j['error'],
                            ].join(' · '),
                          ),
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
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
          children: [
            Text('设置', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 5),
            Text(
              '管理相册与备份偏好',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            Text('已连接的相册', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            panel(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 4,
                ),
                leading: Icon(
                  Icons.lock_outline_rounded,
                  color: theme.colorScheme.primary,
                ),
                title: Text(b.binding['name']),
                subtitle: Text("已连接 · ${b.binding['login']}"),
              ),
            ),
            const SizedBox(height: 24),
            Text('备份偏好', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            panel(
              child: Column(
                children: [
                  if (Platform.isAndroid)
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
                  const ListTile(
                    leading: Icon(Icons.image_outlined),
                    title: Text('原图质量'),
                    subtitle: Text('保留静态照片原始文件，缩略图单独生成。'),
                  ),
                  if (Platform.isWindows)
                    const ListTile(
                      leading: Icon(Icons.desktop_windows_outlined),
                      title: Text('窗口打开时继续备份'),
                      subtitle: Text('关闭后保留队列，下次打开继续。'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text('账户', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            panel(
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

  Widget retry(String reason, [File? invalid]) => IconButton(
    tooltip: '$reason · 点击重新下载',
    icon: const Icon(Icons.broken_image_outlined),
    onPressed: () =>
        setState(() => file = load(refresh: true, invalid: invalid)),
  );

  @override
  Widget build(BuildContext context) => FutureBuilder<File>(
    future: file,
    builder: (context, v) {
      if (v.hasError) {
        return retry(readable(v.error!));
      }
      if (!v.hasData) return const Center(child: Icon(Icons.image_outlined));
      return Image.file(
        v.requireData,
        fit: widget.fit,
        errorBuilder: (c, e, s) => retry('缩略图无法解码', v.requireData),
      );
    },
  );
}
