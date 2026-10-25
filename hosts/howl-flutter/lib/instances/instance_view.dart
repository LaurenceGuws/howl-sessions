import 'dart:async';

import 'package:flutter/material.dart';
import 'package:howl_server_client/howl_server_client.dart';

/// One retained, cancellable Instance observer. The text projection is only
/// diagnostic until a proper terminal cell renderer consumes the native facts.
final class InstanceView extends StatefulWidget {
  const InstanceView({
    super.key,
    required this.endpoint,
    required this.serverId,
    this.session,
    this.instance,
    required this.onClose,
  });

  final String? endpoint;
  final BigInt? serverId;
  final SessionEntry? session;
  final InstanceEntry? instance;
  final VoidCallback onClose;

  @override
  State<InstanceView> createState() => _InstanceViewState();
}

final class _InstanceViewState extends State<InstanceView> {
  TerminalTextObserver? _observer;
  TerminalTextSnapshot? _frame;
  String? _failure;
  bool _connecting = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_follow());
  }

  Future<void> _follow() async {
    final generation = ++_generation;
    final previous = _observer;
    _observer = null;
    setState(() {
      _frame = null;
      _failure = null;
      _connecting = true;
    });
    if (previous != null) {
      try {
        await previous.close();
      } catch (error) {
        if (mounted && generation == _generation) {
          setState(() {
            _connecting = false;
            _failure = 'Previous observation teardown: $error';
          });
        }
        return;
      }
    }

    final endpoint = widget.endpoint;
    final serverId = widget.serverId;
    final session = widget.session;
    final instance = widget.instance;
    if (endpoint == null ||
        serverId == null ||
        session == null ||
        instance == null ||
        !mounted ||
        generation != _generation) {
      if (mounted && generation == _generation) {
        setState(() => _connecting = false);
      }
      return;
    }

    TerminalTextObserver? observer;
    try {
      observer = await const ServerClient().followText(
        endpoint,
        serverId,
        session.id,
        instance.id,
      );
      if (!mounted || generation != _generation) return;
      _observer = observer;
      while (mounted && generation == _generation) {
        final frame = await observer.next();
        if (!mounted || generation != _generation) break;
        setState(() {
          _frame = frame;
          _connecting = false;
        });
        // Pull one next cut only after painting the previous one.
        await WidgetsBinding.instance.endOfFrame;
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _connecting = false;
          _failure = error.toString();
        });
      }
    } finally {
      if (observer != null) {
        try {
          await observer.close();
        } catch (error) {
          if (mounted && generation == _generation) {
            setState(() => _failure = 'Observation teardown: $error');
          }
        }
      }
      if (identical(_observer, observer)) _observer = null;
    }
  }

  @override
  void dispose() {
    _generation++;
    final observer = _observer;
    if (observer != null) {
      unawaited(
        observer.close().catchError((Object error) {
          debugPrint('Terminal observation teardown: $error');
        }),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final instance = widget.instance;
    if (session == null || instance == null) {
      return const Center(child: Text('Choose an Instance from Sessions'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text(session.name),
          subtitle: Text('Instance ${instance.id}'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(instance.running ? 'Running' : 'Exited'),
              IconButton(
                tooltip: 'Close instance',
                icon: const Icon(Icons.close),
                onPressed: widget.onClose,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              const Expanded(
                child: Text('Live text · read-only, without terminal styling'),
              ),
              IconButton(
                tooltip: 'Reconnect terminal observation',
                icon: const Icon(Icons.refresh),
                onPressed: _connecting ? null : () => unawaited(_follow()),
              ),
            ],
          ),
        ),
        Expanded(
          child: _failure != null
              ? Center(child: Text('Observation failed: $_failure'))
              : _frame == null
              ? Center(
                  child: Text(
                    _connecting
                        ? 'Attaching to Instance…'
                        : 'No terminal observation',
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.all(8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SingleChildScrollView(
                      child: SelectableText(
                        _frame!.lines.join('\n'),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          height: 1.15,
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
