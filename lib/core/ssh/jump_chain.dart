import '../../data/host_profile.dart';

class JumpChainError implements Exception {
  JumpChainError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Hops from the outermost jump host through to [target], inclusive.
///
/// [byId] must already contain every hop, including [target].
List<HostProfile> resolveJumpChain(
  HostProfile target,
  Map<String, HostProfile> byId,
) {
  final backward = <HostProfile>[target];
  final seen = <String>{target.id};
  var cursor = target;
  while (true) {
    final nextId = cursor.jumpHostId?.trim() ?? '';
    if (nextId.isEmpty) break;
    if (!seen.add(nextId)) {
      throw JumpChainError('跳板成环：${cursor.name}');
    }
    final hop = byId[nextId];
    if (hop == null) {
      throw JumpChainError('找不到跳板主机');
    }
    if (hop.protocol != HostProtocol.ssh && hop.protocol != HostProtocol.sftp) {
      throw JumpChainError('跳板必须是 SSH/SFTP：${hop.name}');
    }
    backward.add(hop);
    cursor = hop;
  }
  return backward.reversed.toList();
}
