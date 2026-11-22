import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_pad_flutter/core/ssh/jump_chain.dart';
import 'package:ssh_pad_flutter/data/host_profile.dart';

HostProfile _host(
  String id, {
  String? jump,
  HostProtocol protocol = HostProtocol.ssh,
}) {
  return HostProfile(
    id: id,
    name: id,
    host: '$id.example',
    jumpHostId: jump,
    protocol: protocol,
  );
}

void main() {
  test('jump chain starts at the outermost hop', () {
    final a = _host('a');
    final b = _host('b', jump: 'a');
    final c = _host('c', jump: 'b');
    final chain = resolveJumpChain(c, {'a': a, 'b': b, 'c': c});
    expect(chain.map((e) => e.id).toList(), ['a', 'b', 'c']);
  });

  test('direct host is a chain of one', () {
    final a = _host('a');
    expect(resolveJumpChain(a, {'a': a}).single.id, 'a');
  });

  test('cycle is rejected', () {
    final a = _host('a', jump: 'b');
    final b = _host('b', jump: 'a');
    expect(
      () => resolveJumpChain(a, {'a': a, 'b': b}),
      throwsA(isA<JumpChainError>()),
    );
  });

  test('missing hop is rejected', () {
    final b = _host('b', jump: 'gone');
    expect(
      () => resolveJumpChain(b, {'b': b}),
      throwsA(isA<JumpChainError>()),
    );
  });

  test('telnet cannot be a jump', () {
    final a = _host('a', protocol: HostProtocol.telnet);
    final b = _host('b', jump: 'a');
    expect(
      () => resolveJumpChain(b, {'a': a, 'b': b}),
      throwsA(isA<JumpChainError>()),
    );
  });

  test('asSftp keeps jump, group, tags and forwards', () {
    final ssh = HostProfile(
      id: 't',
      name: 't',
      host: 'h',
      group: 'prod',
      tags: const ['db'],
      jumpHostId: 'bastion',
      forwards: const [
        ForwardSpec(kind: ForwardKind.socks, listenPort: 1080),
      ],
    );
    final sftp = ssh.asSftp();
    expect(sftp.protocol, HostProtocol.sftp);
    expect(sftp.jumpHostId, 'bastion');
    expect(sftp.group, 'prod');
    expect(sftp.tags, ['db']);
    expect(sftp.forwards.single.label, 'D 1080');
    final json = sftp.toJson();
    expect(json.containsKey('password'), isFalse);
    final restored = HostProfile.fromJson(json);
    expect(restored.jumpHostId, 'bastion');
    expect(restored.forwards.single.kind, ForwardKind.socks);
  });
}
