import 'dart:async';

import 'package:flutter/material.dart';
import 'package:howl_server_client/howl_server_client.dart';
import 'package:howl_server_client_render/howl_server_client_render.dart';

import 'render_surface.dart';
import 'terminal_geometry.dart';
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
  TerminalGeometryAttachment? _geometry;
  int _geometryGeneration = 0;
  bool _geometryConnecting = true;
  bool _geometryBusy = false;
  bool _isLeader = false;
  bool _leaderPresent = false;
  String? _geometryFailure;
  TerminalCellGeometry? _fit;
  TerminalCellGeometry? _appliedFit;
  int _cellWidth = 0;
  int _cellHeight = 0;
  Timer? _resizeDebounce;

  @override
  void initState() {
    super.initState();
    unawaited(_follow());
    unawaited(_connectGeometry());
  }

  @override
  void didUpdateWidget(covariant InstanceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.instance?.running != oldWidget.instance?.running ||
        widget.endpoint != oldWidget.endpoint ||
        widget.serverId != oldWidget.serverId ||
        widget.session?.id != oldWidget.session?.id ||
        widget.instance?.id != oldWidget.instance?.id) {
      unawaited(_connectGeometry());
    }
  }

  Future<void> _connectGeometry() async {
    final generation = ++_geometryGeneration;
    _resizeDebounce?.cancel();
    final previous = _geometry;
    _geometry = null;
    _isLeader = false;
    _leaderPresent = false;
    _appliedFit = null;
    _geometryBusy = false;
    setState(() {
      _geometryConnecting = true;
      _geometryFailure = null;
    });
    TerminalGeometryAttachment? opening;
    try {
      if (previous != null) await previous.close();
      final endpoint = widget.endpoint;
      final server = widget.serverId;
      final session = widget.session;
      final instance = widget.instance;
      if (!mounted ||
          generation != _geometryGeneration ||
          endpoint == null ||
          server == null ||
          session == null ||
          instance == null ||
          !instance.running) {
        if (mounted && generation == _geometryGeneration) {
          setState(() => _geometryConnecting = false);
        }
        return;
      }
      opening = await const ServerClient().openGeometry(
        endpoint,
        server,
        session.id,
        instance.id,
      );
      if (!mounted || generation != _geometryGeneration) {
        await opening.close();
        return;
      }
      _geometry = opening;
      final status = await opening.authority();
      if (!mounted || generation != _geometryGeneration) return;
      setState(() {
        _leaderPresent = status.leaderPresent;
        _isLeader = status.youAreLeader;
        _geometryConnecting = false;
      });
    } catch (error) {
      if (opening != null && identical(_geometry, opening)) {
        _geometry = null;
        await opening.close();
      }
      if (mounted && generation == _geometryGeneration) {
        setState(() {
          _geometryConnecting = false;
          _geometryFailure = error.toString();
        });
      }
    }
  }

  Future<void> _refreshGeometryAuthority() async {
    final geometry = _geometry;
    final generation = _geometryGeneration;
    if (geometry == null || _geometryBusy) return;
    _geometryBusy = true;
    try {
      final status = await geometry.authority();
      if (!mounted || generation != _geometryGeneration) return;
      setState(() {
        _isLeader = status.youAreLeader;
        _leaderPresent = status.leaderPresent;
        _geometryFailure = null;
      });
    } catch (error) {
      if (mounted && generation == _geometryGeneration) {
        setState(() => _geometryFailure = error.toString());
      }
    } finally {
      if (generation == _geometryGeneration) _geometryBusy = false;
    }
  }

  Future<void> _resize({required bool acquire}) async {
    final geometry = _geometry;
    final fit = _fit;
    final generation = _geometryGeneration;
    if (geometry == null ||
        fit == null ||
        _geometryBusy ||
        (!acquire && !_isLeader)) {
      return;
    }
    if (!acquire && fit == _appliedFit) return;
    _geometryBusy = true;
    try {
      await geometry.resize(
        fit.rows,
        fit.columns,
        acquireLeadership: acquire,
        cellPixelWidth: _cellWidth,
        cellPixelHeight: _cellHeight,
      );
      if (!mounted || generation != _geometryGeneration) return;
      setState(() {
        _isLeader = true;
        _leaderPresent = true;
        _appliedFit = fit;
        _geometryFailure = null;
      });
    } on ServerClientFailure catch (error) {
      if (!mounted || generation != _geometryGeneration) return;
      setState(() {
        if (error.status == 28) {
          _isLeader = false;
          _appliedFit = null;
          _geometryFailure = 'Another attachment controls terminal sizing';
        } else {
          _geometryFailure = error.toString();
        }
      });
    } catch (error) {
      if (mounted && generation == _geometryGeneration) {
        setState(() => _geometryFailure = error.toString());
      }
    } finally {
      if (generation == _geometryGeneration) _geometryBusy = false;
      // A viewport change during an in-flight resize must not be forgotten.
      if (mounted &&
          generation == _geometryGeneration &&
          _isLeader &&
          _fit != _appliedFit) {
        _scheduleResize();
      }
    }
  }

  void _scheduleResize() {
    _resizeDebounce?.cancel();
    if (!_isLeader || _fit == _appliedFit) return;
    _resizeDebounce = Timer(
      const Duration(milliseconds: 150),
      () => unawaited(_resize(acquire: false)),
    );
  }

  void _measureViewport(BoxConstraints constraints, RenderFrame? frame) {
    if (frame == null) return;
    _cellWidth = frame.cellWidth;
    _cellHeight = frame.cellHeight;
    final next = TerminalCellGeometry.fit(
      Size(constraints.maxWidth, constraints.maxHeight),
      cellWidth: frame.cellWidth,
      cellHeight: frame.cellHeight,
    );
    if (_fit == next) return;
    _fit = next;
    _scheduleResize();
    // The sizing action is above this LayoutBuilder in the same Column.
    // Its enabled state needs another frame after the first measurement.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _follow() async {
    final generation = ++_generation;
    final previous = _observer;
    final previousTextures = _textures;
    _observer = null;
    _textures = null;
    _fit = null;
    _resizeDebounce?.cancel();
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
    _geometryGeneration++;
    _resizeDebounce?.cancel();
    final geometry = _geometry;
    if (geometry != null) {
      unawaited(
        geometry.close().catchError((Object error) {
          debugPrint('Terminal geometry teardown: $error');
        }),
      );
    }
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _geometryFailure ??
                      (_geometryConnecting
                          ? 'Sizing: connecting (follower)'
                          : _isLeader
                          ? 'Sizing: this viewport controls geometry'
                          : _leaderPresent
                          ? 'Sizing: another viewport leads'
                          : 'Sizing: no leader'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: _geometry == null
                    ? 'Reconnect sizing attachment'
                    : 'Refresh sizing authority',
                icon: const Icon(Icons.sync),
                onPressed: _geometryConnecting
                    ? null
                    : () => unawaited(
                        _geometry == null
                            ? _connectGeometry()
                            : _refreshGeometryAuthority(),
                      ),
              ),
              TextButton(
                onPressed:
                    _geometryConnecting ||
                        _geometry == null ||
                        _fit == null ||
                        _isLeader
                    ? null
                    : () => unawaited(_resize(acquire: true)),
                child: const Text('Take sizing control'),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _measureViewport(constraints, _frame);
              return _failure != null
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
                  : RenderCanvas(frame: _frame!, textures: _textures!);
            },
          ),
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
