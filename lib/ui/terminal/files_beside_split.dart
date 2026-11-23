import 'package:flutter/material.dart';

import '../pad/drag_divider.dart';
import '../pad/pad_breakpoints.dart';

/// Terminal on the left, files pane on the right, with a drag splitter.
///
/// Caller decides whether to show this (wide enough + pane open). The
/// divider grows the terminal when dragged right (files pane shrinks).
class FilesBesideSplit extends StatelessWidget {
  const FilesBesideSplit({
    super.key,
    required this.contentWidth,
    required this.paneWidth,
    required this.terminal,
    required this.files,
    required this.onPaneDrag,
    this.onPaneDragEnd,
  });

  final double contentWidth;
  final double paneWidth;
  final Widget terminal;
  final Widget files;
  final ValueChanged<double> onPaneDrag;
  final VoidCallback? onPaneDragEnd;

  @override
  Widget build(BuildContext context) {
    final width = PadBreakpoints.clampFilesPaneWidth(paneWidth, contentWidth);
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(child: terminal),
        DragDivider(
          onDrag: (dx) => onPaneDrag(-dx),
          onDragEnd: onPaneDragEnd,
        ),
        SizedBox(
          width: width,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface,
              border: Border(
                left: BorderSide(color: scheme.outline.withValues(alpha: 0.35)),
              ),
            ),
            child: files,
          ),
        ),
      ],
    );
  }
}
