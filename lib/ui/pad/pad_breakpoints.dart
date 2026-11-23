import 'package:flutter/material.dart';

/// Layout breakpoints aligned with Material / Kotlin ssh-pad (≥600dp split).
abstract final class PadBreakpoints {
  /// Width at or above which the pad uses a dual-pane split + drag divider.
  static const double split = 600;

  /// Minimum left pane width when dragging.
  static const double leftMin = 220;

  /// Default left pane width (dp).
  static const double leftDefault = 300;

  /// Max left fraction of total width.
  static const double leftMaxFraction = 0.45;

  /// Right-content width at which terminal + files can sit side by side.
  static const double filesBeside = 700;

  /// Minimum files pane width when dragging.
  static const double filesPaneMin = 240;

  /// Default files pane width (dp).
  static const double filesPaneDefault = 340;

  /// Max files pane fraction of the terminal+files content width.
  static const double filesPaneMaxFraction = 0.5;

  /// Minimum width reserved for the terminal in a files-beside split.
  static const double terminalMin = 320;

  /// Minimum tappable control size (ssh-pad README / Material).
  static const double minTap = 48;

  /// Floor for status-bar / cutout top guard when insets report 0 (OEM quirk).
  static const double statusBarFloor = 40;

  static bool isSplit(BoxConstraints constraints) =>
      constraints.maxWidth >= split;

  static bool isSplitSize(Size size) => size.width >= split;

  /// Whether the terminal content area is wide enough for a files side pane.
  static bool canShowFilesBeside(double contentWidth) =>
      contentWidth >= filesBeside;

  /// Clamps the files pane width given the terminal+files content width.
  static double clampFilesPaneWidth(double pane, double contentWidth) {
    final min = filesPaneMin;
    final maxByFraction = contentWidth * filesPaneMaxFraction;
    final maxByTerminal = contentWidth - terminalMin;
    final max = maxByFraction < maxByTerminal ? maxByFraction : maxByTerminal;
    if (max <= min) return min;
    if (pane < min) return min;
    if (pane > max) return max;
    return pane;
  }
}
