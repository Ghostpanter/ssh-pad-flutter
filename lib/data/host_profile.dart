/// Host connection profile (PadSSH / ServerBox-aligned fields).
library;

enum HostProtocol {
  ssh,
  sftp,
  telnet,
  ftp,
  serial,
  local,
  rlogin;

  /// Protocols shipped in the UI (connect enabled).
  bool get isMvp =>
      this == HostProtocol.ssh ||
      this == HostProtocol.sftp ||
      this == HostProtocol.telnet ||
      this == HostProtocol.ftp;

  /// Kept in the enum for future use / legacy JSON; never shown in the picker.
  bool get isDeferred => !isMvp;

  /// Only these appear in the protocol dropdown.
  static const List<HostProtocol> selectable = [
    HostProtocol.ssh,
    HostProtocol.sftp,
    HostProtocol.telnet,
    HostProtocol.ftp,
  ];

  bool get isTerminal =>
      this == HostProtocol.ssh || this == HostProtocol.telnet;

  bool get isFile =>
      this == HostProtocol.sftp || this == HostProtocol.ftp;

  String get label {
    switch (this) {
      case HostProtocol.ssh:
        return 'SSH';
      case HostProtocol.sftp:
        return 'SFTP';
      case HostProtocol.telnet:
        return 'TELNET';
      case HostProtocol.ftp:
        return 'FTP';
      case HostProtocol.serial:
        return 'SERIAL';
      case HostProtocol.local:
        return 'LOCAL';
      case HostProtocol.rlogin:
        return 'RLOGIN';
    }
  }

  int? get defaultPort {
    switch (this) {
      case HostProtocol.ssh:
      case HostProtocol.sftp:
        return 22;
      case HostProtocol.telnet:
        return 23;
      case HostProtocol.ftp:
        return 21;
      case HostProtocol.rlogin:
        return 513;
      case HostProtocol.serial:
      case HostProtocol.local:
        return null;
    }
  }

  static HostProtocol fromName(String name) {
    return HostProtocol.values.firstWhere(
      (e) => e.name == name,
      orElse: () => HostProtocol.ssh,
    );
  }
}

enum AuthMethod { password, key, keyboardInteractive }

enum FtpSecureMode { none, ftps, ftpes }

enum ForwardKind { local, remote, socks }

/// A port forward that starts with the host's SSH session.
///
/// [listenPort] is the bound port (device side for local/socks, remote side
/// for remote). [targetHost]/[targetPort] are the far end of an L/R forward.
class ForwardSpec {
  const ForwardSpec({
    required this.kind,
    required this.listenPort,
    this.targetHost = '127.0.0.1',
    this.targetPort = 0,
  });

  final ForwardKind kind;
  final int listenPort;
  final String targetHost;
  final int targetPort;

  String get label {
    switch (kind) {
      case ForwardKind.local:
        return 'L $listenPort → $targetHost:$targetPort';
      case ForwardKind.remote:
        return 'R $listenPort ← $targetHost:$targetPort';
      case ForwardKind.socks:
        return 'D $listenPort';
    }
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'listenPort': listenPort,
        'targetHost': targetHost,
        'targetPort': targetPort,
      };

  factory ForwardSpec.fromJson(Map<String, dynamic> json) {
    return ForwardSpec(
      kind: ForwardKind.values.firstWhere(
        (e) => e.name == (json['kind'] as String? ?? 'local'),
        orElse: () => ForwardKind.local,
      ),
      listenPort: (json['listenPort'] as num?)?.toInt() ?? 0,
      targetHost: json['targetHost'] as String? ?? '127.0.0.1',
      targetPort: (json['targetPort'] as num?)?.toInt() ?? 0,
    );
  }
}

class HostProfile {
  HostProfile({
    required this.id,
    required this.name,
    this.protocol = HostProtocol.ssh,
    this.host = '',
    int? port,
    this.username = '',
    this.auth = AuthMethod.password,
    this.password,
    this.privateKey,
    this.passphrase,
    this.ftpSecure = FtpSecureMode.none,
    this.ftpPassive = true,
    this.serialDeviceId,
    this.baudRate,
    this.saveSecret = false,
    this.group = '',
    this.tags = const [],
    this.jumpHostId,
    this.forwards = const [],
    this.forwardAgent = false,
  }) : port = port ?? protocol.defaultPort ?? 22;

  final String id;
  final String name;
  final HostProtocol protocol;
  final String host;
  final int port;
  final String username;
  final AuthMethod auth;
  final String? password;
  final String? privateKey;
  final String? passphrase;
  final FtpSecureMode ftpSecure;
  /// FTP passive mode (default true — friendlier with LAN NAT).
  final bool ftpPassive;
  final String? serialDeviceId;
  final int? baudRate;
  final bool saveSecret;

  /// Empty means ungrouped.
  final String group;
  final List<String> tags;

  /// Another saved host used as the first SSH hop. Empty/null is a direct dial.
  final String? jumpHostId;
  final List<ForwardSpec> forwards;

  /// Offer this host's private key to the remote via `auth-agent-req` (`ssh -A`).
  /// Off unless the user turns it on. Password sessions ignore it.
  final bool forwardAgent;

  HostProfile copyWith({
    String? id,
    String? name,
    HostProtocol? protocol,
    String? host,
    int? port,
    String? username,
    AuthMethod? auth,
    String? password,
    String? privateKey,
    String? passphrase,
    FtpSecureMode? ftpSecure,
    bool? ftpPassive,
    String? serialDeviceId,
    int? baudRate,
    bool? saveSecret,
    String? group,
    List<String>? tags,
    String? jumpHostId,
    bool clearJump = false,
    List<ForwardSpec>? forwards,
    bool? forwardAgent,
  }) {
    return HostProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      protocol: protocol ?? this.protocol,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      auth: auth ?? this.auth,
      password: password ?? this.password,
      privateKey: privateKey ?? this.privateKey,
      passphrase: passphrase ?? this.passphrase,
      ftpSecure: ftpSecure ?? this.ftpSecure,
      ftpPassive: ftpPassive ?? this.ftpPassive,
      serialDeviceId: serialDeviceId ?? this.serialDeviceId,
      baudRate: baudRate ?? this.baudRate,
      saveSecret: saveSecret ?? this.saveSecret,
      group: group ?? this.group,
      tags: tags ?? this.tags,
      jumpHostId: clearJump ? null : (jumpHostId ?? this.jumpHostId),
      forwards: forwards ?? this.forwards,
      forwardAgent: forwardAgent ?? this.forwardAgent,
    );
  }

  /// Clone as SFTP host (for "Files" from an SSH session).
  HostProfile asSftp() => copyWith(protocol: HostProtocol.sftp);

  /// Metadata for SharedPreferences. Secrets go to [SecretStore] when
  /// [includeSecrets] is false (default).
  Map<String, dynamic> toJson({bool includeSecrets = false}) => {
        'id': id,
        'name': name,
        'protocol': protocol.name,
        'host': host,
        'port': port,
        'username': username,
        'auth': auth.name,
        if (includeSecrets && password != null) 'password': password,
        if (includeSecrets && privateKey != null) 'privateKey': privateKey,
        if (includeSecrets && passphrase != null) 'passphrase': passphrase,
        'ftpSecure': ftpSecure.name,
        'ftpPassive': ftpPassive,
        if (serialDeviceId != null) 'serialDeviceId': serialDeviceId,
        if (baudRate != null) 'baudRate': baudRate,
        'saveSecret': saveSecret,
        if (group.trim().isNotEmpty) 'group': group,
        if (tags.isNotEmpty) 'tags': tags,
        if (jumpHostId != null && jumpHostId!.isNotEmpty)
          'jumpHostId': jumpHostId,
        if (forwards.isNotEmpty)
          'forwards': forwards.map((f) => f.toJson()).toList(),
        if (forwardAgent) 'forwardAgent': true,
        // Marker: secrets live in flutter_secure_storage when saveSecret.
        'secretsInSecureStore': true,
      };

  factory HostProfile.fromJson(Map<String, dynamic> json) {
    final protocol = HostProtocol.fromName(json['protocol'] as String? ?? 'ssh');
    return HostProfile(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      protocol: protocol,
      host: json['host'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? protocol.defaultPort ?? 22,
      username: json['username'] as String? ?? '',
      auth: AuthMethod.values.firstWhere(
        (e) => e.name == (json['auth'] as String? ?? 'password'),
        orElse: () => AuthMethod.password,
      ),
      password: json['password'] as String?,
      privateKey: json['privateKey'] as String?,
      passphrase: json['passphrase'] as String?,
      ftpSecure: FtpSecureMode.values.firstWhere(
        (e) => e.name == (json['ftpSecure'] as String? ?? 'none'),
        orElse: () => FtpSecureMode.none,
      ),
      ftpPassive: json['ftpPassive'] as bool? ?? true,
      serialDeviceId: json['serialDeviceId'] as String?,
      baudRate: (json['baudRate'] as num?)?.toInt(),
      saveSecret: json['saveSecret'] as bool? ?? false,
      group: json['group'] as String? ?? '',
      tags: (json['tags'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .where((e) => e.trim().isNotEmpty)
          .toList(),
      jumpHostId: json['jumpHostId'] as String?,
      forwards: (json['forwards'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => ForwardSpec.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      forwardAgent: json['forwardAgent'] as bool? ?? false,
    );
  }
}
