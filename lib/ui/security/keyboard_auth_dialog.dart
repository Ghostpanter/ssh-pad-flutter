import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

import '../../data/host_profile.dart';

/// Keyboard-interactive prompt. Cancel returns null so dartssh2 skips the method.
Future<List<String>?> showKeyboardAuthDialog(
  BuildContext context,
  HostProfile profile,
  SSHUserInfoRequest request,
) {
  if (request.prompts.isEmpty) return Future.value(const <String>[]);
  final controllers = [
    for (final _ in request.prompts) TextEditingController(),
  ];
  final title = request.name.trim().isEmpty
      ? '身份验证'
      : request.name.trim();
  final where = profile.name.isEmpty ? profile.host : profile.name;
  return showDialog<List<String>>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      return AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                where,
                style: Theme.of(ctx).textTheme.labelMedium,
              ),
              if (request.instruction.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(request.instruction.trim()),
              ],
              for (var i = 0; i < request.prompts.length; i++) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: controllers[i],
                  autofocus: i == 0,
                  obscureText: !request.prompts[i].echo,
                  decoration: InputDecoration(
                    labelText: request.prompts[i].promptText,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: i == request.prompts.length - 1
                      ? (_) => Navigator.of(ctx).pop(
                            [for (final c in controllers) c.text],
                          )
                      : null,
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(
              [for (final c in controllers) c.text],
            ),
            child: const Text('继续'),
          ),
        ],
      );
    },
  ).whenComplete(() {
    for (final c in controllers) {
      c.dispose();
    }
  });
}
