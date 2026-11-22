import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'host_store.dart';

const _kSnippetsKey = 'motty_snippets_v1';

class Snippet {
  const Snippet({required this.id, required this.title, required this.body});

  final String id;
  final String title;
  final String body;

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'body': body};

  factory Snippet.fromJson(Map<String, dynamic> json) {
    return Snippet(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
    );
  }
}

class SnippetStore {
  SnippetStore(this._prefs);

  final SharedPreferences _prefs;

  List<Snippet> load() {
    final raw = _prefs.getString(_kSnippetsKey);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .whereType<Map>()
        .map((e) => Snippet.fromJson(Map<String, dynamic>.from(e)))
        .where((s) => s.title.isNotEmpty && s.body.isNotEmpty)
        .toList();
  }

  Future<void> save(List<Snippet> snippets) async {
    await _prefs.setString(
      _kSnippetsKey,
      jsonEncode(snippets.map((s) => s.toJson()).toList()),
    );
  }
}

final snippetStoreProvider = Provider<SnippetStore>((ref) {
  return SnippetStore(ref.watch(sharedPreferencesProvider));
});

final snippetListProvider =
    StateNotifierProvider<SnippetListNotifier, List<Snippet>>((ref) {
  return SnippetListNotifier(ref.watch(snippetStoreProvider));
});

class SnippetListNotifier extends StateNotifier<List<Snippet>> {
  SnippetListNotifier(this._store) : super(_store.load());

  final SnippetStore _store;

  Future<void> add(String title, String body, {bool sendEnter = true}) async {
    final text = body.replaceAll('\r\n', '\n');
    final payload = sendEnter && !text.endsWith('\n') ? '$text\n' : text;
    final next = [
      ...state,
      Snippet(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        title: title.trim(),
        body: payload,
      ),
    ];
    state = next;
    try {
      await _store.save(next);
    } catch (e, st) {
      debugPrint('snippet save failed: $e\n$st');
    }
  }

  Future<void> remove(String id) async {
    final next = state.where((s) => s.id != id).toList();
    state = next;
    await _store.save(next);
  }
}
