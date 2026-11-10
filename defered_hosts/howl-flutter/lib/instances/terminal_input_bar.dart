import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:howl_server_client/howl_server_client.dart';

import 'terminal_input_events.dart';

/// Terminal input stays off the observation attachment. IME commits are text;
/// physical/special keys are semantic transitions, never fabricated escapes.
final class TerminalInputBar extends StatefulWidget {
  const TerminalInputBar({
    super.key,
    required this.endpoint,
    required this.serverId,
    required this.sessionId,
    required this.instanceId,
    required this.running,
  });

  final String endpoint;
  final BigInt serverId;
  final BigInt sessionId;
  final BigInt instanceId;
  final bool running;

  @override
  State<TerminalInputBar> createState() => _TerminalInputBarState();
}

final class _TerminalInputBarState extends State<TerminalInputBar>
    with TextInputClient, DeltaTextInputClient {
  final _ime = TerminalImeBuffer();
  TextInputConnection? _editingConnection;
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKeyEvent)
    ..addListener(_onFocusChanged);
  late final TerminalSoftwareRepeat _softwareRepeat = TerminalSoftwareRepeat(
    (key, action) => _named(key, action),
  );
  final _queue =
      Queue<({Future<void> Function(TerminalTextInput) send, int size})>();
  final _held =
      <LogicalKeyboardKey, ({PhysicalTerminalKey key, int modifiers})>{};
  TerminalTextInput? _input;
  String? _failure;
  int _generation = 0;
  int _queuedBytes = 0;
  bool _connecting = true;
  bool _draining = false;

  @override
  void initState() {
    super.initState();
    if (widget.running) unawaited(_connect());
  }

  @override
  void didUpdateWidget(covariant TerminalInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final identityChanged =
        widget.endpoint != oldWidget.endpoint ||
        widget.serverId != oldWidget.serverId ||
        widget.sessionId != oldWidget.sessionId ||
        widget.instanceId != oldWidget.instanceId;
    if (!widget.running && (oldWidget.running || identityChanged)) {
      _disconnect();
    } else if (widget.running && (!oldWidget.running || identityChanged)) {
      unawaited(_connect());
    }
  }

  void _disconnect() {
    ++_generation;
    final input = _input;
    _input = null;
    _connecting = true;
    _queue.clear();
    _queuedBytes = 0;
    _terminateHeldInput(sendRelease: false);
    _closeEditing();
    if (input != null) {
      unawaited(
        input.close().catchError((Object error) {
          debugPrint('Terminal input disable teardown: $error');
        }),
      );
    }
  }

  void _terminateHeldInput({bool sendRelease = true}) {
    _softwareRepeat.stop(sendRelease: sendRelease);
    final held = _held.values.toList(growable: false);
    _held.clear();
    if (!sendRelease) return;
    for (final key in held) {
      _dispatchPhysical(key.key, TerminalKeyAction.release, key.modifiers);
    }
  }

  Future<void> _connect() async {
    final generation = ++_generation;
    final previous = _input;
    _input = null;
    _queue.clear();
    _queuedBytes = 0;
    _terminateHeldInput(sendRelease: false);
    _closeEditing(); // Never replay ambiguous input after reconnect.
    TerminalTextInput? opening;
    setState(() {
      _connecting = true;
      _failure = null;
    });
    try {
      if (previous != null) await previous.close();
      if (!mounted || generation != _generation) return;
      opening = await const ServerClient().openTextInput(
        widget.endpoint,
        widget.serverId,
        widget.sessionId,
        widget.instanceId,
      );
      if (!mounted || generation != _generation) {
        await opening.close();
        return;
      }
      // Keep ownership visible to dispose/reconnect during native setup.
      _input = opening;
      await opening.ready;
      if (!mounted || generation != _generation) return;
      setState(() {
        _connecting = false;
      });
      _openEditing();
    } catch (error) {
      var message = error.toString();
      if (opening != null && identical(_input, opening)) {
        _input = null;
        try {
          await opening.close();
        } catch (cleanupError) {
          message = '$message; input cleanup: $cleanupError';
        }
      }
      if (mounted && generation == _generation) {
        setState(() {
          _connecting = false;
          _failure = message;
        });
      }
    }
  }

  void _openEditing() {
    if (!_enabled || !_focus.hasFocus) return;
    if (_editingConnection?.attached != true) {
      _ime.reset();
      _editingConnection = TextInput.attach(
        this,
        const TextInputConfiguration(
          enableDeltaModel: true,
          autocorrect: false,
          enableSuggestions: false,
          enableInteractiveSelection: false,
          enableIMEPersonalizedLearning: false,
          enableInlinePrediction: false,
          smartDashesType: SmartDashesType.disabled,
          smartQuotesType: SmartQuotesType.disabled,
          keyboardAppearance: Brightness.dark,
          inputAction: TextInputAction.send,
        ),
      );
      _editingConnection!.setEditingState(_ime.value);
    }
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      _editingConnection!.setEditableSizeAndTransform(
        box.size,
        box.getTransformTo(null),
      );
      _editingConnection!.setCaretRect(const Rect.fromLTWH(12, 4, 1, 20));
    }
    _editingConnection!.show();
  }

  void _closeEditing() {
    _editingConnection?.close();
    _editingConnection = null;
    _ime.reset();
  }

  @override
  TextEditingValue get currentTextEditingValue => _ime.value;
  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> deltas) {
    if (!_enabled || !_focus.hasFocus) return;
    try {
      if (deltas.length > 64) {
        throw const FormatException('Too many terminal IME edits');
      }
      for (final delta in deltas) {
        final action = _ime.updateDelta(delta);
        if (action?.text case final committed?) {
          if (!_enqueue(
            (input) => input.sendText(committed),
            committed.length * 4,
          )) {
            break;
          }
        } else if (action?.key case final key?) {
          _tapKey(key);
        }
      }
      _editingConnection?.setEditingState(_ime.value);
      setState(() {});
    } catch (error) {
      _closeEditing();
      _terminateHeldInput(sendRelease: false);
      setState(() => _failure = 'Terminal input stopped; reconnect: $error');
    }
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    // Full snapshots lose the edit identity when reset and typing race.
    _closeEditing();
    setState(() => _failure = 'Platform did not provide terminal input deltas');
  }

  @override
  void performAction(TextInputAction action) {
    if (action == TextInputAction.send ||
        action == TextInputAction.done ||
        action == TextInputAction.newline) {
      _tapKey(TerminalNamedKey.enter);
    }
  }

  @override
  void connectionClosed() {
    _editingConnection = null;
    _ime.reset();
    _terminateHeldInput();
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}
  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}
  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  bool get _enabled =>
      widget.running && !_connecting && _failure == null && _input != null;

  /// A bounded queue preserves event order without blocking the UI isolate.
  /// Failed/native-ambiguous sends are never replayed automatically.
  bool _enqueue(Future<void> Function(TerminalTextInput) send, int bytes) {
    if (!_enabled) return false;
    if (_queue.length >= 64 || bytes < 1 || _queuedBytes + bytes > 65535) {
      _terminateHeldInput(sendRelease: false);
      setState(
        () => _failure = 'Terminal input queue full; reconnect to resume',
      );
      return false;
    }
    _queue.add((send: send, size: bytes));
    _queuedBytes += bytes;
    if (!_draining) unawaited(_drain());
    return true;
  }

  Future<void> _drain() async {
    _draining = true;
    final generation = _generation;
    final input = _input!;
    try {
      while (_queue.isNotEmpty && generation == _generation) {
        final current = _queue.removeFirst();
        _queuedBytes -= current.size;
        await current.send(input);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        _queue.clear();
        _queuedBytes = 0;
        _terminateHeldInput(sendRelease: false);
        setState(
          () => _failure = 'Input failed; reconnect before retry: $error',
        );
      }
    } finally {
      _draining = false;
      // Reconnect may have replaced the queue while an old send was awaiting.
      if (_queue.isNotEmpty && _enabled) unawaited(_drain());
    }
  }

  void _onFocusChanged() {
    if (_focus.hasFocus) {
      _openEditing();
    } else {
      _closeEditing();
      _terminateHeldInput();
    }
    if (mounted) setState(() {});
  }

  void _named(
    TerminalNamedKey key,
    TerminalKeyAction action, [
    int modifiers = 0,
  ]) => _enqueue(
    (input) => input.sendNamedKey(key, action, modifiers: modifiers),
    1,
  );

  void _unicode(int scalar, TerminalKeyAction action, int modifiers) =>
      _enqueue(
        (input) => input.sendUnicodeKey(scalar, action, modifiers: modifiers),
        1,
      );

  void _tapKey(TerminalNamedKey key) {
    // The queue admits the pair together or neither, including under pressure.
    if (!_enabled || _queue.length > 62 || _queuedBytes > 65533) return;
    _named(key, TerminalKeyAction.press);
    _named(key, TerminalKeyAction.release);
  }

  void _ctrlC() {
    if (!_enabled || _queue.length > 62 || _queuedBytes > 65533) return;
    _unicode(0x63, TerminalKeyAction.press, TerminalModifiers.control);
    _unicode(0x63, TerminalKeyAction.release, TerminalModifiers.control);
  }

  int get _modifiers {
    final keyboard = HardwareKeyboard.instance;
    return (keyboard.isShiftPressed ? TerminalModifiers.shift : 0) |
        (keyboard.isAltPressed ? TerminalModifiers.alt : 0) |
        (keyboard.isControlPressed ? TerminalModifiers.control : 0) |
        (keyboard.isMetaPressed ? TerminalModifiers.superKey : 0);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!_enabled) return KeyEventResult.ignored;
    // During IME preedit arrows/backspace belong to the composition editor.
    final composing = _ime.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (event is KeyUpEvent) {
      final held = _held.remove(key);
      if (held == null) return KeyEventResult.ignored;
      _dispatchPhysical(held.key, TerminalKeyAction.release, held.modifiers);
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) {
      final held = _held[key];
      if (held == null) return KeyEventResult.ignored;
      _dispatchPhysical(held.key, TerminalKeyAction.repeat, held.modifiers);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final mapped = terminalPhysicalKey(key, _modifiers);
    if (mapped == null) return KeyEventResult.ignored;
    if (_held.containsKey(key)) return KeyEventResult.handled;
    _held[key] = (key: mapped, modifiers: _modifiers);
    _dispatchPhysical(mapped, TerminalKeyAction.press, _modifiers);
    return KeyEventResult.handled;
  }

  void _dispatchPhysical(
    PhysicalTerminalKey key,
    TerminalKeyAction action,
    int modifiers,
  ) {
    if (key.named case final named?) {
      _named(named, action, modifiers);
    } else if (key.scalar case final scalar?) {
      _unicode(scalar, action, modifiers);
    }
  }

  void _startRepeat(TerminalNamedKey key) {
    if (!_enabled) return;
    _softwareRepeat.start(key);
  }

  Widget _keyButton(String label, TerminalNamedKey key) => Tooltip(
    message: label,
    child: GestureDetector(
      onTap: _enabled ? () => _tapKey(key) : null,
      onLongPressStart: _enabled ? (_) => _startRepeat(key) : null,
      onLongPressEnd: _enabled ? (_) => _softwareRepeat.stop() : null,
      onLongPressCancel: _enabled ? () => _softwareRepeat.stop() : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Text(label),
      ),
    ),
  );

  @override
  void dispose() {
    _generation++;
    _queue.clear();
    _terminateHeldInput(sendRelease: false);
    final input = _input;
    if (input != null) {
      unawaited(
        input.close().catchError((Object error) {
          debugPrint('Terminal input teardown: $error');
        }),
      );
    }
    _closeEditing();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_failure != null)
            Text(
              'Input failed: $_failure',
              style: const TextStyle(color: Colors.orange),
            ),
          Row(
            children: [
              Expanded(
                child: Focus(
                  focusNode: _focus,
                  child: Semantics(
                    textField: true,
                    label: 'Terminal input',
                    child: InkWell(
                      onTap: !_enabled
                          ? null
                          : () {
                              _focus.requestFocus();
                              _openEditing();
                            },
                      child: InputDecorator(
                        isFocused: _focus.hasFocus,
                        decoration: InputDecoration(
                          isDense: true,
                          enabled: _enabled,
                          labelText: 'Terminal input',
                        ),
                        child: SizedBox(height: 24, child: Text(_ime.preedit)),
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Reconnect terminal input',
                icon: const Icon(Icons.refresh),
                onPressed: _connecting ? null : () => unawaited(_connect()),
              ),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _keyButton('Esc', TerminalNamedKey.escape),
                _keyButton('Tab', TerminalNamedKey.tab),
                _keyButton('←', TerminalNamedKey.left),
                _keyButton('↓', TerminalNamedKey.down),
                _keyButton('↑', TerminalNamedKey.up),
                _keyButton('→', TerminalNamedKey.right),
                _keyButton('⌫', TerminalNamedKey.backspace),
                _keyButton('Enter', TerminalNamedKey.enter),
                TextButton(
                  onPressed: _enabled ? _ctrlC : null,
                  child: const Text('Ctrl+C'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
