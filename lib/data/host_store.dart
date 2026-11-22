import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/security/secret_store.dart';
import 'host_profile.dart';

const _kHostsKey = 'host_profiles_v1';
const _kSecretsMigratedKey = 'secrets_migrated_v1';

class HostStore {
  HostStore(this._prefs, this._secrets);

  final SharedPreferences _prefs;
  final SecretStore _secrets;

  /// Sync metadata load (secrets may be missing until hydrate runs).
  List<HostProfile> loadAll() {
    final raw = _prefs.getString(_kHostsKey);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => HostProfile.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  HostProfile _meta(HostProfile h) => HostProfile(
        id: h.id,
        name: h.name,
        protocol: h.protocol,
        host: h.host,
        port: h.port,
        username: h.username,
        auth: h.auth,
        ftpSecure: h.ftpSecure,
        ftpPassive: h.ftpPassive,
        serialDeviceId: h.serialDeviceId,
        baudRate: h.baudRate,
        saveSecret: h.saveSecret,
        group: h.group,
        tags: h.tags,
        jumpHostId: h.jumpHostId,
        forwards: h.forwards,
      );

  HostProfile _withSecrets(
    HostProfile h, {
    String? password,
    String? privateKey,
    String? passphrase,
  }) =>
      HostProfile(
        id: h.id,
        name: h.name,
        protocol: h.protocol,
        host: h.host,
        port: h.port,
        username: h.username,
        auth: h.auth,
        password: password,
        privateKey: privateKey,
        passphrase: passphrase,
        ftpSecure: h.ftpSecure,
        ftpPassive: h.ftpPassive,
        serialDeviceId: h.serialDeviceId,
        baudRate: h.baudRate,
        saveSecret: h.saveSecret,
        group: h.group,
        tags: h.tags,
        jumpHostId: h.jumpHostId,
        forwards: h.forwards,
      );

  /// Migrate plaintext prefs secrets → secure storage, then hydrate.
  Future<List<HostProfile>> migrateAndHydrate() async {
    final rawList = loadAll();
    final hydrated = <HostProfile>[];

    for (final h in rawList) {
      var password = h.password;
      var privateKey = h.privateKey;
      var passphrase = h.passphrase;

      final hadPlaintext = (password != null && password.isNotEmpty) ||
          (privateKey != null && privateKey.isNotEmpty) ||
          (passphrase != null && passphrase.isNotEmpty);

      if (hadPlaintext && h.saveSecret) {
        await _secrets.writeSecrets(
          hostId: h.id,
          password: password,
          privateKey: privateKey,
          passphrase: passphrase,
        );
        debugPrint('Migrated secrets for host ${h.id} to secure storage');
      }

      if (h.saveSecret) {
        final s = await _secrets.readSecrets(h.id);
        password = (s.password != null && s.password!.isNotEmpty)
            ? s.password
            : password;
        privateKey = (s.privateKey != null && s.privateKey!.isNotEmpty)
            ? s.privateKey
            : privateKey;
        passphrase = (s.passphrase != null && s.passphrase!.isNotEmpty)
            ? s.passphrase
            : passphrase;
        hydrated.add(
          _withSecrets(
            h,
            password: password,
            privateKey: privateKey,
            passphrase: passphrase,
          ),
        );
      } else {
        if (hadPlaintext) {
          await _secrets.deleteAllForHost(h.id);
        }
        hydrated.add(_meta(h));
      }
    }

    await _persistMetadata(hydrated);
    await _prefs.setBool(_kSecretsMigratedKey, true);
    return hydrated;
  }

  Future<void> _persistMetadata(List<HostProfile> hosts) async {
    final encoded = jsonEncode(
      hosts.map((h) => h.toJson(includeSecrets: false)).toList(),
    );
    await _prefs.setString(_kHostsKey, encoded);
  }

  Future<void> saveAll(List<HostProfile> hosts) async {
    for (final h in hosts) {
      if (h.saveSecret) {
        await _secrets.writeSecrets(
          hostId: h.id,
          password: h.password,
          privateKey: h.privateKey,
          passphrase: h.passphrase,
        );
      } else {
        await _secrets.deleteAllForHost(h.id);
      }
    }
    await _persistMetadata(hosts);
  }

  Future<void> upsert(HostProfile host) async {
    final current = loadAll();
    final merged = <HostProfile>[];
    var replaced = false;
    for (final h in current) {
      if (h.id == host.id) {
        merged.add(host);
        replaced = true;
      } else {
        if (h.saveSecret) {
          final s = await _secrets.readSecrets(h.id);
          merged.add(
            _withSecrets(
              h,
              password: s.password,
              privateKey: s.privateKey,
              passphrase: s.passphrase,
            ),
          );
        } else {
          merged.add(_meta(h));
        }
      }
    }
    if (!replaced) merged.add(host);
    await saveAll(merged);
  }

  Future<void> delete(String id) async {
    await _secrets.deleteAllForHost(id);
    final all = loadAll()..removeWhere((h) => h.id == id);
    await _persistMetadata(all);
  }

  /// Always try secure storage so reconnect / 2nd shell gets credentials
  /// even if the in-memory [HostProfile] was stripped of secrets.
  Future<HostProfile> withSecrets(HostProfile host) async {
    final s = await _secrets.readSecrets(host.id);
    String? pick(String? stored, String? mem) =>
        (stored != null && stored.isNotEmpty) ? stored : mem;
    return _withSecrets(
      host,
      password: pick(s.password, host.password),
      privateKey: pick(s.privateKey, host.privateKey),
      passphrase: pick(s.passphrase, host.passphrase),
    );
  }
}

final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError('Override with SharedPreferences instance');
});

final secretStoreProvider = Provider<SecretStore>((ref) {
  return SecretStore();
});

final hostStoreProvider = Provider<HostStore>((ref) {
  return HostStore(
    ref.watch(sharedPreferencesProvider),
    ref.watch(secretStoreProvider),
  );
});

final hostListProvider =
    StateNotifierProvider<HostListNotifier, List<HostProfile>>((ref) {
  return HostListNotifier(ref.watch(hostStoreProvider));
});

class HostListNotifier extends StateNotifier<List<HostProfile>> {
  HostListNotifier(this._store) : super([]) {
    _init();
  }

  final HostStore _store;
  bool _ready = false;

  Future<void> _init() async {
    try {
      state = await _store.migrateAndHydrate();
    } catch (e, st) {
      debugPrint('HostListNotifier init failed: $e\n$st');
      state = _store.loadAll();
    }
    _ready = true;
  }

  bool get ready => _ready;

  Future<void> upsert(HostProfile host) async {
    await _store.upsert(host);
    state = await _store.migrateAndHydrate();
  }

  Future<void> delete(String id) async {
    await _store.delete(id);
    state = await _store.migrateAndHydrate();
  }

  Future<void> reload() async {
    state = await _store.migrateAndHydrate();
  }
}
