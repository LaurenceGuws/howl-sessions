import 'package:flutter/material.dart';
import 'package:howl_server_client/howl_server_client.dart';

/// One explicitly requested text-only diagnostic snapshot, never live output.
/// A future retained attachment will own actual terminal following and input.
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
  Future<TerminalTextSnapshot>? _preview;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    final endpoint = widget.endpoint;
    final serverId = widget.serverId;
    final session = widget.session;
    final instance = widget.instance;
    if (endpoint == null ||
        serverId == null ||
        session == null ||
        instance == null) {
      return;
    }
    setState(() {
      _preview = const ServerClient().readTextPreview(
        endpoint,
        serverId,
        session.id,
        instance.id,
      );
    });
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
                child: Text('Text preview · not live terminal output'),
              ),
              IconButton(
                tooltip: 'Refresh terminal preview',
                icon: const Icon(Icons.refresh),
                onPressed: _refresh,
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<TerminalTextSnapshot>(
            future: _preview,
            builder: (context, result) {
              if (result.hasError) {
                return Center(child: Text('Snapshot failed: ${result.error}'));
              }
              if (!result.hasData) {
                return const Center(child: Text('Reading terminal snapshot…'));
              }
              final frame = result.requireData;
              return Padding(
                padding: const EdgeInsets.all(8),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SingleChildScrollView(
                    child: SelectableText(
                      frame.lines.join('\n'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        height: 1.15,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
