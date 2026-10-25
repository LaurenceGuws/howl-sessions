import 'dart:async';

import 'package:flutter/material.dart';
import 'package:howl_server_client/howl_server_client.dart';
import 'package:howl_server_client_render/howl_server_client_render.dart';

import 'render_surface.dart';
import 'terminal_input_bar.dart';
import 'terminal_fonts.dart';

/// One retained, cancellable Instance observer and canonical Render Canvas.
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
  RenderObserver? _observer;
  RenderFrame? _frame;
  RenderTextures? _textures;
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
    final previousTextures = _textures;
    _observer = null;
    _textures = null;
    setState(() {
      _frame = null;
      _failure = null;
      _connecting = true;
    });
    try {
      if (previous != null) {
        await previous.close();
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _connecting = false;
          _failure = 'Previous observation teardown: $error';
        });
      }
      return;
    } finally {
      if (previousTextures != null) {
        await WidgetsBinding.instance.endOfFrame;
        previousTextures.close();
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

    RenderObserver? observer;
    RenderTextures? textures;
    try {
      final fonts = await terminalFonts();
      observer = await RenderObserver.start(
        endpoint,
        serverId,
        session.id,
        instance.id,
        fontPath: fonts.$1,
        fallbackPaths: fonts.$2,
      );
      if (!mounted || generation != _generation) return;
      textures = RenderTextures();
      _observer = observer;
      _textures = textures;
      while (mounted && generation == _generation) {
        final frame = await observer.next(resident: textures.resident);
        if (!mounted || generation != _generation) break;
        await textures.apply(frame);
        if (!mounted || generation != _generation) break;
        setState(() {
          _frame = frame;
          _connecting = false;
        });
        // Only the finished canvas frame establishes backend residency.
        await WidgetsBinding.instance.endOfFrame;
        textures.finishFrame();
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
      if (identical(_textures, textures)) _textures = null;
      textures?.close();
    }
  }

  @override
  void dispose() {
    _generation++;
    final observer = _observer;
    _textures?.close();
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
              const Expanded(child: Text('Native Canvas · input below')),
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
              : _textures == null
              ? const Center(child: Text('Native Canvas unavailable'))
              : RenderCanvas(frame: _frame!, textures: _textures!),
        ),
        if (widget.endpoint != null && widget.serverId != null)
          SafeArea(
            top: false,
            child: TerminalInputBar(
              endpoint: widget.endpoint!,
              serverId: widget.serverId!,
              sessionId: session.id,
              instanceId: instance.id,
              running: instance.running,
            ),
          ),
      ],
    );
  }
}
