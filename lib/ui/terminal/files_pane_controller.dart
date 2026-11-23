import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../pad/pad_breakpoints.dart';

/// Visibility and width of the Motty-style files pane beside the terminal.
class FilesPaneController extends ChangeNotifier {
  FilesPaneController({
    bool open = false,
    double width = PadBreakpoints.filesPaneDefault,
  }) : this._init(open, width);

  FilesPaneController._init(this._open, this._width);

  static const openKey = 'term_files_pane_open_v1';
  static const widthKey = 'term_files_pane_width_v1';

  bool _open;
  double _width;

  bool get open => _open;
  double get width => _width;

  /// True when the user wants the pane and the content area is wide enough.
  bool isVisibleAt(double contentWidth) =>
      _open && PadBreakpoints.canShowFilesBeside(contentWidth);

  void setOpen(bool value) {
    if (_open == value) return;
    _open = value;
    notifyListeners();
  }

  void toggle() => setOpen(!_open);

  void setWidth(double value, double contentWidth) {
    final next = PadBreakpoints.clampFilesPaneWidth(value, contentWidth);
    if (next == _width) return;
    _width = next;
    notifyListeners();
  }

  void loadFrom(SharedPreferences prefs) {
    _open = prefs.getBool(openKey) ?? false;
    _width = prefs.getDouble(widthKey) ?? PadBreakpoints.filesPaneDefault;
    notifyListeners();
  }

  Future<void> persistTo(SharedPreferences prefs) async {
    await prefs.setBool(openKey, _open);
    await prefs.setDouble(widthKey, _width);
  }
}
