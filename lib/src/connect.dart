import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import 'backup.dart';
import 'catalog.dart';
import 'github.dart';
import 'store.dart';

const _customClientId = String.fromEnvironment('GITHUB_CLIENT_ID');
const _customAppSlug = String.fromEnvironment('GITHUB_APP_SLUG');

enum _RepositoryStep { choose, create, install }

enum _SetupStep { intro, create, details }

class ConnectPage extends StatefulWidget {
  const ConnectPage(
    this.store, {
    super.key,
    this.clientId = _customClientId,
    this.appSlug = _customAppSlug,
  });
  final Store store;
  final String clientId, appSlug;
  @override
  State<ConnectPage> createState() => _ConnectState();
}

class _ConnectState extends State<ConnectPage> with WidgetsBindingObserver {
  final client = http.Client();
  late String clientId, appSlug;
  late final TextEditingController clientIdInput, appSlugInput;
  bool configuring = false;
  _SetupStep setupStep = _SetupStep.intro;
  _SetupStep detailsBack = _SetupStep.create;
  final appName =
      'yingge-${const Uuid().v4().replaceAll('-', '').substring(0, 12)}';
  bool get configured => clientId.isNotEmpty && appSlug.isNotEmpty;
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
    clientId = widget.clientId;
    appSlug = widget.appSlug;
    clientIdInput = TextEditingController(text: clientId);
    appSlugInput = TextEditingController(text: appSlug);
    if (configured) {
      unawaited(guard(authorize));
    } else {
      configuring = true;
      unawaited(guard(loadConfig));
    }
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
    clientIdInput.dispose();
    appSlugInput.dispose();
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

  Future<void> loadConfig() async {
    final saved = await widget.store.pref('githubApp') as Json?;
    if (!mounted || saved == null) return;
    clientIdInput.text = saved['clientId'] as String;
    appSlugInput.text = saved['appSlug'] as String;
    setState(() {
      setupStep = _SetupStep.details;
      detailsBack = _SetupStep.intro;
    });
  }

  Future<void> saveConfig() async {
    final id = clientIdInput.text.trim();
    var slug = appSlugInput.text.trim();
    final url = Uri.tryParse(slug);
    final parts = url?.pathSegments.where((part) => part.isNotEmpty).toList();
    if (url != null &&
        url.scheme == 'https' &&
        url.host.toLowerCase() == 'github.com' &&
        parts != null) {
      if (parts.length == 2 && parts.first == 'apps') {
        slug = parts[1];
      } else if (parts.length == 3 &&
          parts[0] == 'settings' &&
          parts[1] == 'apps') {
        slug = parts[2];
      }
    }
    if (id.isEmpty || slug.isEmpty) {
      throw StateError('请填写 Client ID 和 GitHub App 页面链接。');
    }
    if (slug.contains(RegExp(r'[/\\?#\s]'))) {
      throw StateError('请填写完整的 GitHub App 页面链接，或链接末尾的名称。');
    }
    await checkApp(slug);
    if (!mounted) return;
    setState(() {
      clientId = id;
      appSlug = slug;
      configuring = false;
    });
    await authorize(persist: true);
  }

  Future<void> checkApp(String slug) async {
    final response = await client
        .get(
          Uri.https('api.github.com', '/apps/${Uri.encodeComponent(slug)}'),
          headers: {'Accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 404) {
      throw StateError(
        'GitHub 上没有找到这个 App。请检查链接末尾的名称，'
        '例如 https://github.com/settings/apps/你的App名称。',
      );
    }
  }

  Future<void> authorize({bool persist = false}) async {
    final Json challenge;
    try {
      challenge = await Github.oauth(client, '/login/device/code', {
        'client_id': clientId,
      });
    } on ApiError catch (e) {
      if (e.status != 400 && e.status != 404) rethrow;
      if (mounted) {
        setState(() {
          configuring = true;
          setupStep = _SetupStep.details;
          detailsBack = _SetupStep.intro;
        });
      }
      throw StateError(
        e.status == 400
            ? '请在 GitHub App 设置页勾选 Enable Device Flow，并确认 Client ID 正确。'
            : 'GitHub 没有识别这个 Client ID。请从 App 设置页复制 Client ID，注意不是 App ID。',
      );
    }
    if (challenge['user_code'] == null) {
      if (mounted) {
        setState(() {
          configuring = true;
          setupStep = _SetupStep.details;
          detailsBack = _SetupStep.intro;
        });
      }
      throw StateError('请检查 Client ID，并确认 GitHub App 已勾选 Enable Device Flow。');
    }
    if (persist) {
      if (!mounted) return;
      final saved = await widget.store.pref('githubApp') as Json?;
      if (saved == null ||
          saved['clientId'] != clientId ||
          saved['appSlug'] != appSlug) {
        await widget.store.set('githubApp', {
          'clientId': clientId,
          'appSlug': appSlug,
        });
      }
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
    await widget.store.connect(repo, user!, tokens!, clientId);
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> openGitHub(
    String path, {
    bool copyCode = false,
    Map<String, String>? query,
  }) async {
    try {
      if (copyCode) await Clipboard.setData(ClipboardData(text: code!));
      if (!mounted) return;
      if (!await launchUrl(
        Uri.https('github.com', path, query),
        mode: LaunchMode.externalApplication,
      )) {
        throw StateError('无法打开 GitHub，请检查默认浏览器后重试。');
      }
    } catch (e) {
      if (mounted) setState(() => error = readable(e));
    }
  }

  void clearConfigError() {
    if (error != null) setState(() => error = null);
  }

  Future<void> paste(TextEditingController controller) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (mounted && text != null) {
      controller.text = text;
      clearConfigError();
    }
  }

  void showDetails({required _SetupStep back}) => setState(() {
    setupStep = _SetupStep.details;
    detailsBack = back;
    error = null;
  });

  void showStep(_RepositoryStep next) => setState(() {
    step = next;
    error = null;
  });

  @override
  Widget build(BuildContext context) {
    final rows = repos ?? const <Json>[];
    final selected = rows.where((r) => r['id'] == selectedId).firstOrNull;
    return PopScope(
      canPop: !configuring || setupStep == _SetupStep.intro,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || !configuring) return;
        setState(() {
          setupStep = setupStep == _SetupStep.details
              ? detailsBack
              : _SetupStep.intro;
          error = null;
        });
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('连接 GitHub')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (configuring) ...[
                  if (setupStep == _SetupStep.intro) ...[
                    Text(
                      '连接你的私人相册',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 12),
                    const Text('使用自己的 GitHub 账号保存照片。还没有账号？打开 GitHub 后可以先注册。'),
                    const SizedBox(height: 24),
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(child: Text('1')),
                      title: Text('创建专属连接'),
                      subtitle: Text('我们会帮你预填大部分设置'),
                    ),
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(child: Text('2')),
                      title: Text('回到映格填写连接信息'),
                      subtitle: Text('只需复制两项公开信息'),
                    ),
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(child: Text('3')),
                      title: Text('登录并选择照片仓库'),
                      subtitle: Text('只授权你选择的私有仓库'),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () => setState(() => setupStep = _SetupStep.create),
                      child: const Text('开始设置'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => showDetails(back: _SetupStep.intro),
                      child: const Text('我已经创建过 GitHub App'),
                    ),
                  ] else if (setupStep == _SetupStep.create) ...[
                    Text(
                      '第 1 步：创建专属连接',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '打开 GitHub 后，请先登录自己的账号。'
                      '名称、主页和仓库权限会预先填好。',
                    ),
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('在 GitHub 页面勾选这一项'),
                          const SizedBox(height: 6),
                          Text(
                            'Enable Device Flow',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            '位于 Identifying and authorizing users 区域。',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '保留其他预填设置，滑到页面底部点击 Create GitHub App。'
                      '如果名称已被占用，换一个名称即可。',
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () => openGitHub(
                              '/settings/apps/new',
                              query: {
                                'name': appName,
                                'url': 'https://github.com/wumengjie-nexthub/LumaBerth',
                                'contents': 'write',
                                'public': 'false',
                                'webhook_active': 'false',
                                'request_oauth_on_install': 'false',
                              },
                            ),
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: const Text('打开 GitHub 创建页面'),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => showDetails(back: _SetupStep.create),
                      child: const Text('我已创建，继续'),
                    ),
                  ] else ...[
                    Text(
                      '第 2 步：填写连接信息',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '1. 在刚创建的 GitHub App 设置页找到 Client ID 并复制。\n'
                      '2. 再复制浏览器地址栏中的页面链接。\n'
                      '3. 分别粘贴到下面的输入框。',
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: busy
                            ? null
                            : () => openGitHub('/settings/apps'),
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: const Text('找不到？打开 GitHub App 列表'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: clientIdInput,
                      onChanged: (_) => clearConfigError(),
                      enabled: !busy,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'Client ID',
                        hintText: '在 GitHub App 设置页查找',
                        suffixIcon: IconButton(
                          tooltip: '粘贴 Client ID',
                          onPressed: busy ? null : () => paste(clientIdInput),
                          icon: const Icon(Icons.content_paste_rounded),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: appSlugInput,
                      onChanged: (_) => clearConfigError(),
                      enabled: !busy,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'GitHub App 设置页链接',
                        hintText: '复制浏览器地址栏的链接',
                        suffixIcon: IconButton(
                          tooltip: '粘贴页面链接',
                          onPressed: busy ? null : () => paste(appSlugInput),
                          icon: const Icon(Icons.content_paste_rounded),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Client ID 不是 App ID。请勿输入 Client Secret 或私钥。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      SelectableText(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: busy ? null : () => guard(saveConfig),
                      child: const Text('保存并继续'),
                    ),
                  ],
                ] else if (tokens == null) ...[
                  Text(
                    '在 GitHub 确认登录',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 12),
                  if (code != null) ...[
                    const Text('复制下方设备码，在 GitHub 粘贴并授权，然后返回映格。'),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 18,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: SelectableText(
                        code!,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer,
                              letterSpacing: 1.5,
                            ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () =>
                          openGitHub('/login/device', copyCode: true),
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('复制并前往 GitHub'),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '也可以手动打开 github.com/login/device 输入设备码。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ] else if (!busy) ...[
                    FilledButton(
                      onPressed: () => guard(authorize),
                      child: const Text('重新获取设备码'),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        configuring = true;
                        setupStep = _SetupStep.details;
                        detailsBack = _SetupStep.intro;
                        error = null;
                      }),
                      child: const Text('修改 GitHub App'),
                    ),
                  ] else
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
                      '允许 App 访问相册',
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
                              openGitHub('/apps/$appSlug/installations/new');
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
                      onPressed: busy
                          ? null
                          : () => guard(() => bind(selected)),
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
                if (error != null &&
                    !(configuring && setupStep == _SetupStep.details))
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: SelectableText(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
