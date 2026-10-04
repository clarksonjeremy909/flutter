// Windows implementation of the AFK backend using raw dart:ffi (no codegen).
//
// * SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED |
//   ES_DISPLAY_REQUIRED) is called from the Dart UI isolate's thread, which
//   lives for the whole app lifetime, so the state stays held until we call
//   SetThreadExecutionState(ES_CONTINUOUS) (release) or the process exits.
//   The scheduler re-asserts it every cycle for robustness.
// * SendInput injects a zero-distance relative mouse move and/or an F15
//   key down+up. Both reset GetLastInputInfo (Windows idle timer) and are
//   seen as user activity by games, but have no visible effect.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'afk_status.dart';
import 'keep_awake_backend.dart';

const int esSystemRequired = 0x00000001;
const int esDisplayRequired = 0x00000002;
const int esContinuous = 0x80000000;

const int _inputMouse = 0;
const int _inputKeyboard = 1;
const int _mouseeventfMove = 0x0001;
const int _keyeventfKeyup = 0x0002;
const int _vkF15 = 0x7E;

final class MOUSEINPUT extends Struct {
  @Int32()
  external int dx;
  @Int32()
  external int dy;
  @Uint32()
  external int mouseData;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int time;
  @IntPtr()
  external int dwExtraInfo;
}

final class KEYBDINPUT extends Struct {
  @Uint16()
  external int wVk;
  @Uint16()
  external int wScan;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int time;
  @IntPtr()
  external int dwExtraInfo;
}

final class InputUnion extends Union {
  external MOUSEINPUT mi;
  external KEYBDINPUT ki;
}

/// Mirrors the Win32 INPUT struct (40 bytes on x64, 28 on x86).
final class INPUT extends Struct {
  @Uint32()
  external int type;
  external InputUnion u;
}

typedef _SetThreadExecutionStateC = Uint32 Function(Uint32 esFlags);
typedef _SetThreadExecutionStateDart = int Function(int esFlags);
typedef _SendInputC = Uint32 Function(Uint32 cInputs, Pointer<INPUT> pInputs, Int32 cbSize);
typedef _SendInputDart = int Function(int cInputs, Pointer<INPUT> pInputs, int cbSize);
typedef _GetLastErrorC = Uint32 Function();
typedef _GetLastErrorDart = int Function();

class WindowsKeepAwakeBackend implements KeepAwakeBackend {
  WindowsKeepAwakeBackend() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final user32 = DynamicLibrary.open('user32.dll');
    _setThreadExecutionState = kernel32
        .lookupFunction<_SetThreadExecutionStateC, _SetThreadExecutionStateDart>(
            'SetThreadExecutionState');
    _getLastError =
        kernel32.lookupFunction<_GetLastErrorC, _GetLastErrorDart>('GetLastError');
    _sendInput = user32.lookupFunction<_SendInputC, _SendInputDart>('SendInput');
  }

  late final _SetThreadExecutionStateDart _setThreadExecutionState;
  late final _SendInputDart _sendInput;
  late final _GetLastErrorDart _getLastError;

  static bool get platformSupported => Platform.isWindows;

  @override
  String get name => 'Windows (SetThreadExecutionState + SendInput)';

  @override
  bool get isSupported => true;

  @override
  Future<void> acquire() async {
    final prev = _setThreadExecutionState(
        esContinuous | esSystemRequired | esDisplayRequired);
    if (prev == 0) {
      throw OSError('SetThreadExecutionState başarısız', _getLastError());
    }
  }

  @override
  Future<void> release() async {
    // Clearing back to ES_CONTINUOUS alone drops the system/display requirement.
    _setThreadExecutionState(esContinuous);
  }

  @override
  Future<void> sendKeepAliveInput(KeepAwakeMethod method) async {
    final count = switch (method) {
      KeepAwakeMethod.mouseJiggle => 1,
      KeepAwakeMethod.f15Key => 2,
      KeepAwakeMethod.both => 3,
    };
    final inputs = calloc<INPUT>(count);
    try {
      var i = 0;
      if (method != KeepAwakeMethod.f15Key) {
        final m = inputs[i++];
        m.type = _inputMouse;
        m.u.mi
          ..dx = 0
          ..dy = 0
          ..mouseData = 0
          ..dwFlags = _mouseeventfMove // relative, zero distance
          ..time = 0
          ..dwExtraInfo = 0;
      }
      if (method != KeepAwakeMethod.mouseJiggle) {
        for (final up in [false, true]) {
          final k = inputs[i++];
          k.type = _inputKeyboard;
          k.u.ki
            ..wVk = _vkF15
            ..wScan = 0
            ..dwFlags = up ? _keyeventfKeyup : 0
            ..time = 0
            ..dwExtraInfo = 0;
        }
      }
      final sent = _sendInput(count, inputs, sizeOf<INPUT>());
      if (sent != count) {
        // Typical cause: UIPI (target window runs elevated) or secure desktop
        // (lock screen / UAC prompt). Execution state is still held.
        throw OSError(
            'SendInput $sent/$count giriş gönderdi (UIPI/kilit ekranı?)',
            _getLastError());
      }
    } finally {
      calloc.free(inputs);
    }
  }
}
