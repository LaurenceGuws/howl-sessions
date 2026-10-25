import 'package:flutter/material.dart';
import 'package:howl_server_client/howl_server_client.dart';

/// Instance selection is deliberately distinct from terminal observation.
/// The native dedicated attachment and render surface will live here.
final class InstanceView extends StatelessWidget {
  const InstanceView({
    super.key,
    this.session,
    this.instance,
    required this.onClose,
  });

  final SessionEntry? session;
  final InstanceEntry? instance;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    if (session == null || instance == null) {
      return const Center(child: Text('Choose an Instance from Sessions'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: Text(session!.name),
          subtitle: Text('Instance ${instance!.id}'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(instance!.running ? 'Running' : 'Exited'),
              IconButton(
                tooltip: 'Close instance',
                icon: const Icon(Icons.close),
                onPressed: onClose,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        const Expanded(
          child: Center(
            child: Text(
              'Native terminal attachment not installed in this host yet.',
            ),
          ),
        ),
      ],
    );
  }
}
