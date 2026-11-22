import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/session/session_manager.dart';
import '../data/host_profile.dart';
import '../data/host_store.dart';
import 'files/files_page.dart';
import 'terminal/terminal_page.dart';

class HostEditorPage extends ConsumerStatefulWidget {
  const HostEditorPage({super.key, this.existing});

  final HostProfile? existing;

  @override
  ConsumerState<HostEditorPage> createState() => _HostEditorPageState();
}

class _HostEditorPageState extends ConsumerState<HostEditorPage> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _privateKey;
  late final TextEditingController _group;
  late final TextEditingController _tags;
  late final List<ForwardSpec> _forwards;
  late HostProtocol _protocol;
  late AuthMethod _auth;
  late FtpSecureMode _ftpSecure;
  late bool _ftpPassive;
  late bool _saveSecret;
  String? _jumpHostId;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    final initial = e?.protocol ?? HostProtocol.ssh;
    _protocol = initial.isMvp ? initial : HostProtocol.ssh;
    _auth = e?.auth ?? AuthMethod.password;
    _ftpSecure = e?.ftpSecure ?? FtpSecureMode.none;
    _ftpPassive = e?.ftpPassive ?? true;
    _saveSecret = e?.saveSecret ?? false;
    _name = TextEditingController(text: e?.name ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(
      text: (e?.port ?? _protocol.defaultPort ?? 22).toString(),
    );
    _username = TextEditingController(text: e?.username ?? '');
    _password = TextEditingController(text: e?.password ?? e?.passphrase ?? '');
    _privateKey = TextEditingController(text: e?.privateKey ?? '');
    _group = TextEditingController(text: e?.group ?? '');
    _tags = TextEditingController(text: e?.tags.join(', ') ?? '');
    _forwards = [...?e?.forwards];
    _jumpHostId = e?.jumpHostId;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _privateKey.dispose();
    _group.dispose();
    _tags.dispose();
    super.dispose();
  }

  void _onProtocolChanged(HostProtocol? value) {
    if (value == null) return;
    setState(() {
      _protocol = value;
      final def = value.defaultPort;
      if (def != null) {
        _port.text = def.toString();
      }
    });
  }

  Future<void> _pickKeyFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final f = result.files.single;
    final bytes = f.bytes;
    if (bytes != null) {
      _privateKey.text = String.fromCharCodes(bytes);
      setState(() {});
    }
  }

  HostProfile _buildProfile() {
    final port = int.tryParse(_port.text.trim()) ??
        _protocol.defaultPort ??
        22;
    final pwd = _password.text.isEmpty ? null : _password.text;
    final tags = _tags.text
        .split(RegExp(r'[,，]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final known = ref.read(hostListProvider).map((h) => h.id).toSet();
    final selfId = widget.existing?.id;
    final jump = _jumpHostId;
    return HostProfile(
      id: widget.existing?.id ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      name: _name.text.trim().isEmpty ? _host.text.trim() : _name.text.trim(),
      protocol: _protocol,
      host: _host.text.trim(),
      port: port,
      username: _username.text.trim(),
      auth: _auth,
      password: _auth == AuthMethod.password ? pwd : null,
      privateKey: _auth == AuthMethod.key && _privateKey.text.trim().isNotEmpty
          ? _privateKey.text
          : widget.existing?.privateKey,
      passphrase: _auth == AuthMethod.key ? pwd : null,
      ftpSecure: _ftpSecure,
      ftpPassive: _ftpPassive,
      saveSecret: _saveSecret,
      group: _group.text.trim(),
      tags: tags,
      jumpHostId: jump != null &&
              jump.isNotEmpty &&
              jump != selfId &&
              known.contains(jump)
          ? jump
          : null,
      forwards: _protocol == HostProtocol.ssh || _protocol == HostProtocol.sftp
          ? List<ForwardSpec>.from(_forwards)
          : const [],
    );
  }

  Future<void> _save({bool connect = false}) async {
    final profile = _buildProfile();
    await ref.read(hostListProvider.notifier).upsert(profile);
    if (!mounted) return;
    if (!connect) {
      Navigator.of(context).pop();
      return;
    }
    if (_protocol == HostProtocol.sftp || _protocol == HostProtocol.ftp) {
      Navigator.of(context).pop();
      await openFileBrowser(context, ref, profile);
      return;
    }
    if (_protocol == HostProtocol.telnet) {
      final mgr = ref.read(sessionManagerProvider);
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/terminal'),
          builder: (_) => const TerminalPage(),
        ),
      );
      await mgr.openTerminal(profile);
      return;
    }
    // SSH — navigate then open so connect output shows on the terminal page.
    final mgr = ref.read(sessionManagerProvider);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        settings: const RouteSettings(name: '/terminal'),
        builder: (_) => const TerminalPage(),
      ),
    );
    await mgr.open(profile);
  }

  Widget _jumpField() {
    final hosts = ref.watch(hostListProvider);
    final selfId = widget.existing?.id;
    final options = hosts.where((h) {
      if (h.id == selfId) return false;
      return h.protocol == HostProtocol.ssh || h.protocol == HostProtocol.sftp;
    }).toList();
    final selected =
        options.any((h) => h.id == _jumpHostId) ? _jumpHostId : null;
    return DropdownButtonFormField<String?>(
      // ignore: deprecated_member_use
      value: selected,
      decoration: const InputDecoration(
        labelText: '跳板',
        border: OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem<String?>(
          value: null,
          child: Text('直接连接'),
        ),
        for (final h in options)
          DropdownMenuItem<String?>(
            value: h.id,
            child: Text(
              h.name.isEmpty ? '${h.host}:${h.port}' : h.name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (v) => setState(() => _jumpHostId = v),
    );
  }

  Widget _forwardSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('端口转发', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          '只监听本机 127.0.0.1，随这条 SSH 会话启动和关闭。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        for (var i = 0; i < _forwards.length; i++)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(_forwards[i].label),
            trailing: IconButton(
              tooltip: '删除',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _forwards.removeAt(i)),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _addForward,
            icon: const Icon(Icons.add),
            label: const Text('添加转发'),
          ),
        ),
      ],
    );
  }

  Future<void> _addForward() async {
    var kind = ForwardKind.local;
    final listen = TextEditingController();
    final targetHost = TextEditingController(text: '127.0.0.1');
    final targetPort = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final needsTarget = kind != ForwardKind.socks;
            return AlertDialog(
              title: const Text('端口转发'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<ForwardKind>(
                    // ignore: deprecated_member_use
                    value: kind,
                    decoration: const InputDecoration(
                      labelText: '类型',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: ForwardKind.local,
                        child: Text('本地 -L'),
                      ),
                      DropdownMenuItem(
                        value: ForwardKind.remote,
                        child: Text('远端 -R'),
                      ),
                      DropdownMenuItem(
                        value: ForwardKind.socks,
                        child: Text('SOCKS -D'),
                      ),
                    ],
                    onChanged: (v) => setLocal(() => kind = v ?? kind),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: listen,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '监听端口',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (needsTarget) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: targetHost,
                      decoration: InputDecoration(
                        labelText: kind == ForwardKind.local ? '远端主机' : '本机主机',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: targetPort,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: kind == ForwardKind.local ? '远端端口' : '本机端口',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('添加'),
                ),
              ],
            );
          },
        );
      },
    );
    final listenPort = int.tryParse(listen.text.trim()) ?? 0;
    final destPort = int.tryParse(targetPort.text.trim()) ?? 0;
    if (ok == true && listenPort > 0 && listenPort < 65536) {
      if (kind == ForwardKind.socks || (destPort > 0 && destPort < 65536)) {
        setState(() {
          _forwards.add(
            ForwardSpec(
              kind: kind,
              listenPort: listenPort,
              targetHost: targetHost.text.trim().isEmpty
                  ? '127.0.0.1'
                  : targetHost.text.trim(),
              targetPort: kind == ForwardKind.socks ? 0 : destPort,
            ),
          );
        });
      }
    }
    listen.dispose();
    targetHost.dispose();
    targetPort.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? '添加主机' : '编辑主机'),
        actions: [
          TextButton(
            onPressed: () => _save(connect: false),
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<HostProtocol>(
            // ignore: deprecated_member_use
            value: _protocol,
            decoration: const InputDecoration(
              labelText: '协议',
              border: OutlineInputBorder(),
            ),
            items: HostProtocol.selectable.map((p) {
              return DropdownMenuItem(value: p, child: Text(p.label));
            }).toList(),
            onChanged: _onProtocolChanged,
          ),
          if (_protocol == HostProtocol.telnet ||
              _protocol == HostProtocol.ftp) ...[
            const SizedBox(height: 8),
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  '警告：TELNET / FTP 为明文凭据与会话。'
                  '生产环境请优先使用 SSH / SFTP / FTPS。',
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: '名称',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _host,
            decoration: const InputDecoration(
              labelText: '主机',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _port,
            decoration: const InputDecoration(
              labelText: '端口',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            enabled: _protocol.defaultPort != null,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _username,
            decoration: const InputDecoration(
              labelText: '用户名',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          if (_protocol == HostProtocol.ssh ||
              _protocol == HostProtocol.sftp) ...[
            DropdownButtonFormField<AuthMethod>(
              // ignore: deprecated_member_use
              value: _auth,
              decoration: const InputDecoration(
                labelText: '认证方式',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: AuthMethod.password, child: Text('密码')),
                DropdownMenuItem(value: AuthMethod.key, child: Text('私钥')),
                DropdownMenuItem(
                  value: AuthMethod.keyboardInteractive,
                  child: Text('键盘交互'),
                ),
              ],
              onChanged: (v) => setState(() => _auth = v ?? AuthMethod.password),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _password,
            obscureText: true,
            enabled: _auth != AuthMethod.keyboardInteractive,
            decoration: InputDecoration(
              labelText: _auth == AuthMethod.key
                  ? '私钥口令（可选）'
                  : _auth == AuthMethod.keyboardInteractive
                      ? '不用填，连接时再输入'
                      : '密码',
              border: const OutlineInputBorder(),
            ),
          ),
          if (_auth == AuthMethod.key &&
              (_protocol == HostProtocol.ssh ||
                  _protocol == HostProtocol.sftp)) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _privateKey,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: '私钥 PEM',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
                hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _pickKeyFile,
                icon: const Icon(Icons.upload_file),
                label: const Text('从文件导入私钥'),
              ),
            ),
          ],
          if (_protocol == HostProtocol.ftp) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<FtpSecureMode>(
              // ignore: deprecated_member_use
              value: _ftpSecure,
              decoration: const InputDecoration(
                labelText: 'FTP 安全',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: FtpSecureMode.none, child: Text('明文 FTP')),
                DropdownMenuItem(value: FtpSecureMode.ftps, child: Text('FTPS')),
                DropdownMenuItem(value: FtpSecureMode.ftpes, child: Text('FTPES')),
              ],
              onChanged: (v) =>
                  setState(() => _ftpSecure = v ?? FtpSecureMode.none),
            ),
          ],
          const SizedBox(height: 8),

          if (_protocol == HostProtocol.ftp) ...[
            SwitchListTile(
              title: const Text('被动模式 (PASV)'),
              subtitle: const Text('局域网 NAT 建议开启'),
              value: _ftpPassive,
              onChanged: (v) => setState(() => _ftpPassive = v),
            ),
          ],
          SwitchListTile(
            title: const Text('保存密钥 / 密码（本地）'),
            subtitle: const Text('使用 flutter_secure_storage 加密保存'),
            value: _saveSecret,
            onChanged: (v) => setState(() => _saveSecret = v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _group,
            decoration: const InputDecoration(
              labelText: '分组',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tags,
            decoration: const InputDecoration(
              labelText: '标签',
              hintText: '用逗号分隔',
              border: OutlineInputBorder(),
            ),
          ),
          if (_protocol == HostProtocol.ssh ||
              _protocol == HostProtocol.sftp) ...[
            const SizedBox(height: 12),
            _jumpField(),
            const SizedBox(height: 12),
            _forwardSection(),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => _save(connect: true),
            icon: const Icon(Icons.play_arrow),
            label: const Text('保存并连接'),
          ),
        ],
      ),
    );
  }
}
