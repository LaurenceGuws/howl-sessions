import 'package:flutter/material.dart';

import 'configured_server.dart';
import 'server_store.dart';

/// CRUD for host-local endpoint configurations. No Server is mutated here.
final class ServersSettings extends StatefulWidget {
  const ServersSettings({
    super.key,
    required this.servers,
    required this.onChanged,
    this.saving = false,
  });

  final bool saving;
  final List<ConfiguredServer> servers;
  final Future<void> Function(List<ConfiguredServer>) onChanged;

  @override
  State<ServersSettings> createState() => _ServersSettingsState();
}

final class _ServersSettingsState extends State<ServersSettings> {
  bool _editing = false;
  bool get _busy => _editing || widget.saving;

  Future<void> _edit(BuildContext context, [ConfiguredServer? existing]) async {
    if (_busy) return;
    setState(() => _editing = true);
    try {
      final updated = await _serverEditor(context, existing);
      if (updated == null || !context.mounted) return;
      final index = existing == null ? -1 : widget.servers.indexOf(existing);
      if (existing != null && index < 0) {
        throw StateError('Server changed while editing; open it again');
      }
      final duplicate = widget.servers.any(
        (server) => server.endpoint == updated.endpoint && server != existing,
      );
      if (duplicate) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That endpoint is already configured.')),
        );
        return;
      }
      final next = [...widget.servers];
      if (index == -1) {
        next.add(updated);
      } else {
        next[index] = updated;
      }
      await widget.onChanged(next);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<void> _remove(BuildContext context, ConfiguredServer server) async {
    if (_busy) return;
    setState(() => _editing = true);
    try {
      var submitted = false;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('Remove configured server?'),
          content: Text(
            'Remove ${server.name} from this device? Remote Sessions are unchanged.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (submitted) return;
                submitted = true;
                Navigator.pop(context, false);
              },
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (submitted) return;
                submitted = true;
                Navigator.pop(context, true);
              },
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (confirmed == true && context.mounted) {
        await widget.onChanged(
          widget.servers.where((entry) => entry != server).toList(),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _editing = false);
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
              onPressed:
                  _busy || widget.servers.length >= ServerStore.maxServers
                  ? null
                  : () => _edit(context),
              icon: const Icon(Icons.add),
              label: const Text('Add server'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (widget.saving) const Text('Saving server settings…'),
        if (widget.servers.isEmpty)
          const ListTile(
            title: Text('No servers configured'),
            subtitle: Text('Add an endpoint to browse its Sessions.'),
          ),
        for (final server in widget.servers)
          ListTile(
            title: Text(server.name),
            subtitle: Text(server.endpoint),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Edit server',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: _busy ? null : () => _edit(context, server),
                ),
                IconButton(
                  tooltip: 'Remove server',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _busy ? null : () => _remove(context, server),
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
  var submitted = false;
  final form = GlobalKey<FormState>();
  return showDialog<ConfiguredServer>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text(existing == null ? 'Add server' : 'Edit server'),
      content: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              initialValue: name,
              onChanged: (value) => name = value,
              autofocus: true,
              maxLength: 64,
              validator: (value) =>
                  ConfiguredServer.nameError(value?.trim() ?? ''),
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextFormField(
              initialValue: endpoint,
              onChanged: (value) => endpoint = value,
              maxLength: ConfiguredServer.maxEndpointBytes,
              validator: (value) =>
                  ConfiguredServer.endpointError(value?.trim() ?? ''),
              decoration: const InputDecoration(
                labelText: 'Endpoint',
                hintText: 'tcp://127.0.0.1:43150',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            if (submitted) return;
            submitted = true;
            Navigator.pop(context);
          },
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (submitted || !form.currentState!.validate()) return;
            submitted = true;
            final label = name.trim();
            final address = endpoint.trim();
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
