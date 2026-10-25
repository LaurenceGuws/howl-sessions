import 'package:flutter/material.dart';

import 'configured_server.dart';

/// CRUD for host-local endpoint configurations. No Server is mutated here.
final class ServersSettings extends StatelessWidget {
  const ServersSettings({
    super.key,
    required this.servers,
    required this.onChanged,
  });

  final List<ConfiguredServer> servers;
  final Future<void> Function(List<ConfiguredServer>) onChanged;

  Future<void> _edit(BuildContext context, [ConfiguredServer? existing]) async {
    final updated = await _serverEditor(context, existing);
    if (updated == null || !context.mounted) return;
    final index = existing == null ? -1 : servers.indexOf(existing);
    final duplicate = servers.any(
      (server) => server.endpoint == updated.endpoint && server != existing,
    );
    if (duplicate) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That endpoint is already configured.')),
      );
      return;
    }
    final next = [...servers];
    if (index == -1) {
      next.add(updated);
    } else {
      next[index] = updated;
    }
    await onChanged(next);
  }

  Future<void> _remove(BuildContext context, ConfiguredServer server) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove configured server?'),
        content: Text(
          'Remove ${server.name} from this device? Remote Sessions are unchanged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await onChanged(servers.where((entry) => entry != server).toList());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Servers', style: TextStyle(fontSize: 22)),
            ),
            FilledButton.icon(
              onPressed: () => _edit(context),
              icon: const Icon(Icons.add),
              label: const Text('Add server'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (servers.isEmpty)
          const ListTile(
            title: Text('No servers configured'),
            subtitle: Text('Add an endpoint to browse its Sessions.'),
          ),
        for (final server in servers)
          ListTile(
            title: Text(server.name),
            subtitle: Text(server.endpoint),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Edit server',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => _edit(context, server),
                ),
                IconButton(
                  tooltip: 'Remove server',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _remove(context, server),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

Future<ConfiguredServer?> _serverEditor(
  BuildContext context,
  ConfiguredServer? existing,
) async {
  var name = existing?.name ?? '';
  var endpoint = existing?.endpoint ?? '';
  return showDialog<ConfiguredServer>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(existing == null ? 'Add server' : 'Edit server'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            initialValue: name,
            onChanged: (value) => name = value,
            autofocus: true,
            maxLength: 64,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          TextFormField(
            initialValue: endpoint,
            onChanged: (value) => endpoint = value,
            decoration: const InputDecoration(
              labelText: 'Endpoint',
              hintText: 'tcp://127.0.0.1:43150',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final label = name.trim();
            final address = endpoint.trim();
            if (label.isEmpty || address.isEmpty) return;
            Navigator.pop(
              context,
              ConfiguredServer(name: label, endpoint: address),
            );
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}
