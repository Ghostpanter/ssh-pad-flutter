import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/snippet_store.dart';

/// Quick commands under the terminal. Does not touch the hardware-key path.
class SnippetBar extends ConsumerWidget {
  const SnippetBar({super.key, required this.onSend, this.enabled = true});

  final ValueChanged<String> onSend;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snippets = ref.watch(snippetListProvider);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.65),
      child: SizedBox(
        height: 36,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          children: [
            for (final s in snippets)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                child: GestureDetector(
                  onLongPress: () =>
                      ref.read(snippetListProvider.notifier).remove(s.id),
                  child: ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(s.title, style: const TextStyle(fontSize: 12)),
                    onPressed: enabled ? () => onSend(s.body) : null,
                    tooltip: '点击发送，长按删除',
                  ),
                ),
              ),
            IconButton(
              tooltip: '添加快捷命令',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add, size: 18),
              onPressed: () => _add(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final title = TextEditingController();
    final body = TextEditingController();
    var sendEnter = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('快捷命令'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: title,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '名称',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: body,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: '发送内容',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('末尾回车'),
                    value: sendEnter,
                    onChanged: (v) => setLocal(() => sendEnter = v),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok == true && title.text.trim().isNotEmpty && body.text.isNotEmpty) {
      await ref.read(snippetListProvider.notifier).add(
            title.text,
            body.text,
            sendEnter: sendEnter,
          );
    }
    title.dispose();
    body.dispose();
  }
}
