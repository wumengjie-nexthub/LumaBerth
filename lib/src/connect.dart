import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'backup.dart';
import 'catalog.dart';
import 'github.dart';
import 'store.dart';

class ConnectPage extends StatefulWidget {
  const ConnectPage(this.store, {super.key});
  final Store store;
  @override
  State<ConnectPage> createState() => _ConnectState();
}

class _ConnectState extends State<ConnectPage> {
  final client = http.Client();
  final id = TextEditingController(
    text: const String.fromEnvironment('GITHUB_CLIENT_ID'),
  );
  final slug = TextEditingController(
    text: const String.fromEnvironment('GITHUB_APP_SLUG'),
  );
  String? code, error;
  bool busy = false;
  Json? tokens, user;
  List<Json>? repos;

  @override
  void dispose() {
    client.close();
    id.dispose();
    slug.dispose();
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
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> authorize() async {
    final clientId = id.text.trim();
    if (clientId.isEmpty) throw StateError('请输入 GitHub App 的公开 Client ID');
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
    await launchUrl(
      Uri.https('github.com', '/login/device'),
      mode: LaunchMode.externalApplication,
    );
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration(seconds: interval));
      if (!mounted) return;
      final response = await Github.oauth(client, '/login/oauth/access_token', {
        'client_id': clientId,
        'device_code': challenge['device_code'],
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      });
      if (response['error'] == 'authorization_pending') continue;
      if (response['error'] == 'slow_down') {
        interval += 5;
        continue;
      }
      if (response['access_token'] == null) {
        throw StateError('设备授权未完成：${response['error'] ?? '请重试'}');
      }
      tokens = response;
      await list();
      return;
    }
    throw StateError('设备码已过期，请重新连接');
  }

  Github get github =>
      Github(client, () async => tokens!['access_token'] as String);
  Future<void> list() async {
    final api = github;
    user = await api.json('GET', '/user') as Json;
    final rows = await api.repositories();
    if (mounted) {
      setState(() {
        repos = rows;
        code = null;
      });
    }
  }

  Future<void> bind(Json row) async {
    final repo = await github.verify(row);
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('绑定这个私有仓库？'),
        content: Text("${user!['login']}  /  ${repo['full_name']}\n\n$oneWay"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确认绑定'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.store.connect(repo, user!, tokens!, id.text.trim());
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('连接 GitHub')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              repos == null ? '连接你的私有相册' : '选择照片专用仓库',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 14),
            if (repos == null) ...[
              const Text('先将 GitHub App 安装到照片专用私有仓库，再到 GitHub 输入设备码。'),
              const SizedBox(height: 20),
              TextField(
                controller: id,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'GitHub App Client ID',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: slug,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'GitHub App 安装名（slug）',
                ),
              ),
            ],
            Wrap(
              spacing: 6,
              children: [
                TextButton(
                  onPressed: () => guardLink(),
                  child: const Text('安装到指定仓库'),
                ),
                TextButton(
                  onPressed: () => launchUrl(
                    Uri.https('github.com', '/new'),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: const Text('创建私有仓库'),
                ),
              ],
            ),
            if (repos == null)
              FilledButton.icon(
                onPressed: busy ? null : () => guard(authorize),
                icon: const Icon(Icons.key),
                label: const Text('获取设备码'),
              ),
            if (code != null)
              Card(
                child: ListTile(
                  title: SelectableText(
                    code!,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  subtitle: const Text('在 github.com/login/device 输入此码'),
                  trailing: IconButton(
                    icon: const Icon(Icons.copy),
                    tooltip: '复制设备码',
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: code!)),
                  ),
                ),
              ),
            if (repos != null) ...[
              Text('已授权账号  ${user!['login']}'),
              if (repos!.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Text(
                    '尚无可选仓库。请创建 Private 仓库并初始化 README，在 GitHub App 安装范围内勾选它，授予 Contents 读写权限。',
                  ),
                ),
              for (final r in repos!)
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: Text(r['full_name']),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: busy ? null : () => guard(() => bind(r)),
                ),
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
  Future<void> guardLink() async {
    final name = slug.text.trim();
    final uri = name.isEmpty
        ? Uri.https('github.com', '/settings/installations')
        : Uri.https('github.com', '/apps/$name/installations/new');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
