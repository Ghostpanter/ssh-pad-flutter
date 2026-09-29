import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Android IME helpers: restartInput, show soft keyboard, hardware detect.
class ImeController {
  ImeController();

  static const _channel = MethodChannel('com.sshtab.ssh_pad_flutter/ime');

  /// Force InputMethodManager.restartInput so stale composition is dropped.
  Future<void> restartInput() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('restartInput');
    } on MissingPluginException {
      // Desktop / tests.
    } catch (e) {
      debugPrint('ImeController.restartInput: $e');
    }
  }

  /// Ask Android to show the system soft keyboard on the focused view.
  Future<bool> showSoftInput() async {
    if (!Platform.isAndroid) return false;
    try {
      final v = await _channel.invokeMethod<bool>('showSoftInput');
      return v ?? false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('ImeController.showSoftInput: $e');
      return false;
    }
  }

  /// True when a real physical / Bluetooth full keyboard is attached.
  ///
  /// Android side enumerates InputDevices (non-virtual SOURCE_KEYBOARD with
  /// KEYBOARD_TYPE_ALPHABETIC). Configuration.keyboard alone is unreliable on
  /// OnePlus/ColorOS tablets (often QWERTY with no BT keyboard).
  Future<bool> hasHardwareKeyboard() async {
    if (!Platform.isAndroid) {
      // Desktop / sim: treat as hardware keyboard present for ExtraKeys hide tests.
      if (kIsWeb) return false;
      return Platform.isLinux || Platform.isWindows || Platform.isMacOS;
    }
    try {
      final v = await _channel.invokeMethod<bool>('hasHardwareKeyboard');
      return v ?? false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('ImeController.hasHardwareKeyboard: $e');
      return false;
    }
  }
}

final imeControllerProvider = Provider<ImeController>((ref) => ImeController());
