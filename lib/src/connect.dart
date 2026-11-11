import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'backup.dart';
import 'catalog.dart';
import 'github.dart';
import 'store.dart';

// An unconfigured build uses the public registration, including CI builds
// that pass empty repository variables. Custom registrations override the pair.
const _customClientId = String.fromEnvironment('GITHUB_CLIENT_ID');
const _customAppSlug = String.fromEnvironment('GITHUB_APP_SLUG');
const _useOfficialApp = _customClientId == '' && _customAppSlug == '';

enum _RepositoryStep { choose, create, install }

class ConnectPage extends StatefulWidget {
  const ConnectPage(
    this.store, {
    super.key,
    this.clientId = _useOfficialApp ? 'Iv23li13AQFhUby41bqD' : _customClientId,
    this.appSlug = _useOfficialApp ? 'lumaberth' : _customAppSlug,
  });
  final Store store;
  final String clientId, appSlug;
  @override
  State<ConnectPage> createState() => _ConnectState();
}

class _ConnectState extends State<ConnectPage> with WidgetsBindingObserver {
  final client = http.Client();
  bool get configured =>
      widget.clientId.isNotEmpty && widget.appSlug.isNotEmpty;
  _RepositoryStep step = _RepositoryStep.choose;
  int? selectedId;
  bool refreshOnReturn = false;
  String? code, error;
  bool busy = false;
  Json? tokens, user;
  List<Json>? repos;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (configured) unawaited(guard(authorize));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && refreshOnReturn && !busy) {
      refreshOnReturn = false;
      unawaited(guard(list));
    }
  }

  @override
  void dispose() {
    client.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> guard(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = readable(e));
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          code = null;
        });
      }
    }
  }

  Future<void> authorize() async {
    final clientId = widget.clientId;
    final challenge = await Github.oauth(client, '/login/device/code', {
      'client_id': clientId,
    });
    if (challenge['user_code'] == null) {
      throw StateError('设备授权未开启，或 Client ID 无效');
    }
    if (!mounted) return;
    setState(() => code = challenge['user_code']);
    final deadline = DateTime.now().add(
      Duration(seconds: challenge['expires_in']),
    );
    var interval = challenge['interval'] as int? ?? 5;
    var failures = 0;
    while (mounted) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      final delay = Duration(seconds: interval) * (1 << failures);
      await Future<void>.delayed(delay < remaining ? delay : remaining);
      if (!mounted) return;
      if (delay >= remaining || !DateTime.now().isBefore(deadline)) break;
      final Json response;
      try {
        response = await Github.oauth(client, '/login/oauth/access_token', {
          'client_id': clientId,
          'device_code': challenge['device_code'],
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        });
      } catch (e) {
        if (e is! http.ClientException &&
            e is! SocketException &&
            e is! TimeoutException) {
          rethrow;
        }
        if (!mounted) return;
        if (failures < 3) failures++;
        setState(() => error = '网络连接中断，将自动使用当前设备码重试。');
        continue;
      }
      if (!mounted) return;
      failures = 0;
      if (error != null) setState(() => error = null);
      if (response['error'] == 'authorization_pending') continue;
      if (response['error'] == 'slow_down') {
        interval += 5;
        continue;
      }
      if (response['access_token'] == null) {
        throw StateError('设备授权未完成：${response['error'] ?? '请重试'}');
      }
      setState(() {
        tokens = response;
        code = null;
      });
      await list();
      return;
    }
    throw StateError('设备码已过期，请重新连接');
  }

  Github get github =>
      Github(client, () async => tokens!['access_token'] as String);
  Future<void> list() async {
    final api = github;
    try {
      user = await api.json('GET', '/user') as Json;
      final rows = await api.repositories();
      if (!mounted) return;
      setState(() {
        repos = rows;
        selectedId = rows.length == 1 ? rows.single['id'] as int : null;
        if (rows.isNotEmpty) step = _RepositoryStep.choose;
      });
    } on ApiError catch (e) {
      if (e.status == 401 && mounted) {
        setState(() {
          tokens = null;
          user = null;
          repos = null;
          selectedId = null;
          step = _RepositoryStep.choose;
          refreshOnReturn = false;
        });
      }
      rethrow;
    }
  }

  Future<void> bind(Json row) async {
    final repo = await github.verify(row);
    if (!mounted) return;
    if (repo['full_name'] != row['full_name']) {
      await list();
      throw StateError('仓库名称已更新，请重新确认相册。');
    }
    await widget.store.connect(repo, user!, tokens!, widget.clientId);
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> openGitHub(String path, {bool copyCode = false}) async {
    try {
      if (copyCode) await Clipboard.setData(ClipboardData(text: code!));
      if (!mounted) return;
      if (!await launchUrl(
        Uri.https('github.com', path),
        mode: LaunchMode.externalApplication,
      )) {
        throw StateError('无法打开 GitHub，请检查默认浏览器后重试。');
      }
    } catch (e) {
      if (mounted) setState(() => error = readable(e));
    }
  }

  void showStep(_RepositoryStep next) => setState(() {
    step = next;
    error = null;
  });

  @override
  Widget build(BuildContext context) {
    final rows = repos ?? const <Json>[];
    final selected = rows.where((r) => r['id'] == selectedId).firstOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('连接 GitHub')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              if (!configured) ...[
                const Text('此安装包尚未配置 GitHub 登录。请向提供安装包的人获取已配置的版本。'),
              ] else if (tokens == null) ...[
                Text(
                  '在 GitHub 确认登录',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                if (code != null) ...[
                  const Text('复制下方设备码，在 GitHub 粘贴并授权，然后返回泊光相册。'),
                  const SizedBox(height: 16),
                  SelectableText(
                    code!,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () =>
                        openGitHub('/login/device', copyCode: true),
                    icon: const Icon(Icons.copy),
                    label: const Text('复制并前往 GitHub'),
                  ),
                  const Text('也可以手动打开 github.com/login/device 输入设备码。'),
                ] else if (!busy)
                  FilledButton(
                    onPressed: () => guard(authorize),
                    child: const Text('重新获取设备码'),
                  )
                else
                  const Text('正在获取设备码…'),
              ] else ...[
                if (user != null) Text("已登录 GitHub · ${user!['login']}"),
                const SizedBox(height: 12),
                if (step == _RepositoryStep.create) ...[
                  Text(
                    '创建私有相册',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const Text(
                    '在 GitHub 给仓库取个名字，选择 Private（私有），并开启 Add a README。建好后返回这里。',
                  ),
                  FilledButton(
                    onPressed: () => openGitHub('/new'),
                    child: const Text('前往 GitHub 创建私库'),
                  ),
                  OutlinedButton(
                    onPressed: () => showStep(_RepositoryStep.install),
                    child: const Text('已创建，继续授权'),
                  ),
                ] else if (step == _RepositoryStep.install) ...[
                  Text(
                    '允许泊光访问相册',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const Text(
                    '在 GitHub 选择 Only select repositories，只勾选照片私库，然后确认安装。',
                  ),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () {
                            refreshOnReturn = true;
                            openGitHub(
                              '/apps/${widget.appSlug}/installations/new',
                            );
                          },
                    child: const Text('前往 GitHub 选择私库'),
                  ),
                ] else if (selected != null) ...[
                  Text(
                    '使用这个私有相册？',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: Text(selected['full_name']),
                  ),
                  const Text('之后备份的照片会保存到这里。'),
                  FilledButton(
                    onPressed: busy ? null : () => guard(() => bind(selected)),
                    child: const Text('确认使用'),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            selectedId = null;
                            error = null;
                          }),
                    child: const Text('选择其他相册'),
                  ),
                ] else if (repos != null) ...[
                  Text(
                    '照片存在哪里？',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  for (final row in rows)
                    ListTile(
                      leading: const Icon(Icons.lock_outline),
                      title: Text(row['full_name']),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: busy
                          ? null
                          : () => setState(() {
                              selectedId = row['id'] as int;
                              error = null;
                            }),
                    ),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () => showStep(_RepositoryStep.create),
                    child: const Text('创建私有相册'),
                  ),
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => showStep(_RepositoryStep.install),
                    child: const Text('授权已有私库'),
                  ),
                ],
                if (step != _RepositoryStep.choose)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () {
                            refreshOnReturn = false;
                            showStep(_RepositoryStep.choose);
                          },
                    child: const Text('返回选择相册'),
                  ),
                if (step != _RepositoryStep.create &&
                    (selected == null || step == _RepositoryStep.install))
                  OutlinedButton(
                    onPressed: busy ? null : () => guard(list),
                    child: const Text('刷新可用仓库'),
                  ),
              ],
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(top: 18),
                  child: LinearProgressIndicator(),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SelectableText(error!),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
