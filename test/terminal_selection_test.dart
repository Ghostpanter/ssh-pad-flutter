import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_pad_flutter/ui/terminal/terminal_selection.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('trackpad and mouse are drag-select devices; touch is long-press', () {
    expect(kTerminalDragSelectKinds, contains(PointerDeviceKind.trackpad));
    expect(kTerminalDragSelectKinds, contains(PointerDeviceKind.mouse));
    expect(kTerminalDragSelectKinds, isNot(contains(PointerDeviceKind.touch)));
    expect(kTerminalLongPressKinds, contains(PointerDeviceKind.touch));
    expect(kTerminalLongPressKinds, contains(PointerDeviceKind.trackpad));
  });

  test('shortcuts keep Ctrl+Shift+C copy and add Ctrl+Shift+V paste', () {
    final shortcuts = terminalSelectionShortcuts();
    String desc(ShortcutActivator k) => k.toString();
    expect(
      shortcuts.values.whereType<CopySelectionTextIntent>(),
      isNotEmpty,
    );
    expect(
      shortcuts.values.whereType<PasteTextIntent>().length,
      greaterThanOrEqualTo(2),
    );
    expect(
      shortcuts.keys.any((k) {
        final s = desc(k);
        return s.contains('Key C') && s.contains('Shift');
      }),
      isTrue,
    );
    expect(
      shortcuts.keys.any((k) {
        final s = desc(k);
        return s.contains('Key V') && s.contains('Shift');
      }),
      isTrue,
    );
    expect(
      shortcuts.keys.any((k) {
        final s = desc(k);
        return s.contains('Key C') && !s.contains('Shift');
      }),
      isFalse,
    );
  });

  test('selectedTerminalText reads xterm buffer selection', () {
    final term = Terminal();
    term.resize(80, 24);
    term.write('hello world');
    final controller = TerminalController();
    controller.setSelection(
      term.buffer.createAnchor(0, 0),
      term.buffer.createAnchor(5, 0),
    );
    expect(selectedTerminalText(term, controller), 'hello');
    controller.clearSelection();
    expect(selectedTerminalText(term, controller), isNull);
  });
}
