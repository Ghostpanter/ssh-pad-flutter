import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

/// Pointer kinds that should drag-select instead of scrolling.
///
/// xterm 4 only pans for [PointerDeviceKind.mouse]. Android keyboard
/// trackpads report trackpad / stylus / unknown, so a drag never starts a
/// selection. Touch keeps vertical scroll; long-press (here and in xterm)
/// selects.
const Set<PointerDeviceKind> kTerminalDragSelectKinds = {
  PointerDeviceKind.mouse,
  PointerDeviceKind.trackpad,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.unknown,
};

const Set<PointerDeviceKind> kTerminalLongPressKinds = {
  PointerDeviceKind.touch,
  PointerDeviceKind.mouse,
  PointerDeviceKind.trackpad,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.unknown,
};

/// Shortcuts on top of xterm defaults. Ctrl+C stays SIGINT (not registered).
Map<ShortcutActivator, Intent> terminalSelectionShortcuts() {
  return {
    ...defaultTerminalShortcuts,
    const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
        const PasteTextIntent(SelectionChangedCause.keyboard),
  };
}


/// Touch: mostly-horizontal drag selects (vertical drag keeps scrollback).
/// Mouse / trackpad / stylus: any drag selects.
bool _dragSelects(PointerDeviceKind kind, Offset delta) {
  if (delta.distance < kTouchSlop) return false;
  if (kTerminalDragSelectKinds.contains(kind)) return true;
  if (kind == PointerDeviceKind.touch) {
    return delta.dx.abs() + 4 >= delta.dy.abs();
  }
  return false;
}

String? selectedTerminalText(Terminal terminal, TerminalController controller) {
  final selection = controller.selection;
  if (selection == null) return null;
  final text = terminal.buffer.getText(selection);
  if (text.isEmpty) return null;
  return text;
}

Future<void> copyTerminalSelection(
  Terminal terminal,
  TerminalController controller,
) async {
  final text = selectedTerminalText(terminal, controller);
  if (text == null) return;
  await Clipboard.setData(ClipboardData(text: text));
}

Future<void> pasteClipboardToTerminal(Terminal terminal) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final text = data?.text;
  if (text == null || text.isEmpty) return;
  terminal.paste(text);
}

/// Hosts [TerminalView] and drives xterm's own selection for touch + trackpad.
class TerminalSelectionHost extends StatefulWidget {
  const TerminalSelectionHost({
    super.key,
    required this.terminal,
    required this.controller,
    required this.focusNode,
    required this.hardwareKeyboardOnly,
    this.onCopied,
    this.onPasted,
  });

  final Terminal terminal;
  final TerminalController controller;
  final FocusNode focusNode;
  final bool hardwareKeyboardOnly;
  final VoidCallback? onCopied;
  final VoidCallback? onPasted;

  @override
  State<TerminalSelectionHost> createState() => _TerminalSelectionHostState();
}

class _TerminalSelectionHostState extends State<TerminalSelectionHost> {
  final GlobalKey<TerminalViewState> _viewKey = GlobalKey<TerminalViewState>();
  Offset? _downGlobal;
  Offset? _downLocal;
  int _pointers = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
  }

  @override
  void didUpdateWidget(covariant TerminalSelectionHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    super.dispose();
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  bool get _hasSelection => widget.controller.selection != null;

  void _selectChars(Offset fromLocal, Offset toLocal) {
    final state = _viewKey.currentState;
    if (state == null) return;
    try {
      final dynamic render = state.renderTerminal;
      render.selectCharacters(fromLocal, toLocal);
    } catch (_) {}
  }

  void _selectWord(Offset local) {
    final state = _viewKey.currentState;
    if (state == null) return;
    try {
      final dynamic render = state.renderTerminal;
      render.selectWord(local);
    } catch (_) {}
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointers++;
    _downGlobal = event.position;
    final state = _viewKey.currentState;
    if (state == null) return;
    try {
      final dynamic render = state.renderTerminal;
      _downLocal = render.globalToLocal(event.position) as Offset;
    } catch (_) {
      _downLocal = null;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    final origin = _downGlobal;
    final originLocal = _downLocal;
    if (origin == null || originLocal == null) return;
    if (_pointers > 1) return;
    final delta = event.position - origin;
    if (!_dragSelects(event.kind, delta)) return;
    final state = _viewKey.currentState;
    if (state == null) return;
    try {
      final dynamic render = state.renderTerminal;
      final local = render.globalToLocal(event.position) as Offset;
      render.selectCharacters(originLocal, local);
    } catch (_) {}
  }

  void _onPointerUp(PointerUpEvent event) {
    _pointers = (_pointers - 1).clamp(0, 10);
    if (_pointers == 0) {
      _downGlobal = null;
      _downLocal = null;
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointers = (_pointers - 1).clamp(0, 10);
    _downGlobal = null;
    _downLocal = null;
  }

  Future<void> _copy() async {
    await copyTerminalSelection(widget.terminal, widget.controller);
    widget.controller.clearSelection();
    widget.onCopied?.call();
  }

  Future<void> _paste() async {
    await pasteClipboardToTerminal(widget.terminal);
    widget.controller.clearSelection();
    widget.onPasted?.call();
  }

  Future<void> _onSecondary(TapUpDetails details) async {
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) {
      if (_hasSelection) {
        await _copy();
      } else {
        await _paste();
      }
      return;
    }
    final pos = details.globalPosition;
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(pos.dx, pos.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (_hasSelection)
          const PopupMenuItem(value: 'copy', child: Text('复制')),
        const PopupMenuItem(value: 'paste', child: Text('粘贴')),
        if (_hasSelection)
          const PopupMenuItem(value: 'clear', child: Text('取消选择')),
      ],
    );
    if (!mounted) return;
    if (value == 'copy') await _copy();
    if (value == 'paste') await _paste();
    if (value == 'clear') widget.controller.clearSelection();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ScrollConfiguration(
      // Trackpad one-finger drag must not be stolen by the inner Scrollable.
      behavior: const MaterialScrollBehavior().copyWith(
        dragDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
        },
      ),
      child: Stack(
        children: [
          Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            child: RawGestureDetector(
              behavior: HitTestBehavior.translucent,
              gestures: <Type, GestureRecognizerFactory>{
                LongPressGestureRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                        LongPressGestureRecognizer>(
                  () => LongPressGestureRecognizer(
                    debugOwner: this,
                    duration: const Duration(milliseconds: 350),
                    supportedDevices: kTerminalLongPressKinds,
                  ),
                  (LongPressGestureRecognizer instance) {
                    instance.onLongPressStart = (details) {
                      _selectWord(details.localPosition);
                    };
                    instance.onLongPressMoveUpdate = (details) {
                      final origin = _downLocal;
                      if (origin == null) {
                        _selectWord(details.localPosition);
                        return;
                      }
                      _selectChars(origin, details.localPosition);
                    };
                  },
                ),
              },
              child: TerminalView(
                widget.terminal,
                key: _viewKey,
                controller: widget.controller,
                focusNode: widget.focusNode,
                autofocus: true,
                backgroundOpacity: 1,
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                keyboardType: TextInputType.visiblePassword,
                deleteDetection: true,
                hardwareKeyboardOnly: widget.hardwareKeyboardOnly,
                shortcuts: terminalSelectionShortcuts(),
                onSecondaryTapUp: (details, _) => _onSecondary(details),
                onSecondaryTapDown: (_, _) {},
              ),
            ),
          ),
          if (_hasSelection)
            Positioned(
              right: 8,
              bottom: 8,
              child: Material(
                elevation: 3,
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: _copy,
                      child: const Text('复制'),
                    ),
                    TextButton(
                      onPressed: _paste,
                      child: const Text('粘贴'),
                    ),
                    IconButton(
                      tooltip: '取消选择',
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.controller.clearSelection,
                      icon: const Icon(Icons.close, size: 16),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

