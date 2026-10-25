import 'dart:async';

import 'package:flutter/material.dart';
import 'package:howl_server_client/howl_server_client.dart';

/// Explicit line-input canary. Native text is sent on its own attachment so
/// the separate observation long-poll never traps input behind its reply.
/// This is not a full terminal keyboard or physical-key translator.
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

final class _TerminalInputBarState extends State<TerminalInputBar> {
  final _text = TextEditingController();
  TerminalTextInput? _input;
  String? _failure;
  int _generation = 0;
  bool _connecting = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_connect());
  }

  Future<void> _connect() async {
    final generation = ++_generation;
    final previous = _input;
    _input = null;
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

  Future<void> _send() async {
    final input = _input;
    final value = _text.text;
    if (input == null ||
        _connecting ||
        _sending ||
        value.isEmpty ||
        !widget.running) {
      return;
    }
    final generation = _generation;
    setState(() {
      _sending = true;
      _failure = null;
    });
    try {
      await input.sendText('$value\n');
      if (mounted && generation == _generation) _text.clear();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _failure = error.toString());
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _sending = false);
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    final input = _input;
    if (input != null) {
      unawaited(
        input.close().catchError((Object error) {
          debugPrint('Terminal input teardown: $error');
        }),
      );
    }
    _text.dispose();
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
                child: TextField(
                  controller: _text,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLines: 1,
                  maxLength: 2000,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Send shell line (adds Enter)',
                    counterText: '',
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => unawaited(_send()),
                ),
              ),
              IconButton(
                tooltip: 'Reconnect terminal input',
                icon: const Icon(Icons.refresh),
                onPressed: _connecting || _sending
                    ? null
                    : () => unawaited(_connect()),
              ),
              IconButton(
                tooltip: 'Send line to Instance',
                icon: const Icon(Icons.send),
                onPressed:
                    _input == null ||
                        _connecting ||
                        _sending ||
                        !widget.running ||
                        _text.text.isEmpty
                    ? null
                    : () => unawaited(_send()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
