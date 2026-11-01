import 'package:flutter/material.dart';
import 'package:howl_server_client/howl_server_client.dart';

import '../servers/configured_server.dart';

/// Folder-like Server -> Session -> Instance browsing, with Session CRUD here.
final class SessionCatalog extends StatelessWidget {
  const SessionCatalog({
    super.key,
    required this.servers,
    required this.selectedEndpoint,
    required this.tree,
    required this.loading,
    this.busy = false,
    required this.selectedInstanceId,
    required this.onSelectServer,
    required this.onOpenSettings,
    required this.onRefresh,
    required this.onCreateSession,
    required this.onCloseSession,
    required this.onCreateInstance,
    required this.onSelectInstance,
  });

  final List<ConfiguredServer> servers;
  final String? selectedEndpoint;
  final SessionTree? tree;
  final bool loading;
  final bool busy;
  final BigInt? selectedInstanceId;
  final ValueChanged<String> onSelectServer;
  final VoidCallback onOpenSettings;
  final VoidCallback onRefresh;
  final VoidCallback onCreateSession;
  final ValueChanged<SessionEntry> onCloseSession;
  final ValueChanged<SessionEntry> onCreateInstance;
  final void Function(SessionEntry, InstanceEntry) onSelectInstance;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: DropdownButton<String>(
            isExpanded: true,
            value: selectedEndpoint,
            hint: const Text('Choose a server'),
            items: [
              for (final server in servers)
                DropdownMenuItem(
                  value: server.endpoint,
                  child: Text(server.name),
                ),
            ],
            onChanged: busy
                ? null
                : (endpoint) {
                    if (endpoint != null) onSelectServer(endpoint);
                  },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 8),
          child: Row(
            children: [
              const Expanded(
                child: Text('Sessions', style: TextStyle(fontSize: 18)),
              ),
              IconButton(
                tooltip: 'New session',
                icon: const Icon(Icons.add),
                onPressed:
                    selectedEndpoint == null ||
                        tree == null ||
                        loading ||
                        busy ||
                        tree!.sessions.length >= tree!.sessionCapacity
                    ? null
                    : onCreateSession,
              ),
              IconButton(
                tooltip: 'Refresh sessions',
                icon: const Icon(Icons.refresh),
                onPressed: selectedEndpoint == null || loading || busy
                    ? null
                    : onRefresh,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: selectedEndpoint == null
              ? Center(
                  child: TextButton.icon(
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Configure a server'),
                    onPressed: onOpenSettings,
                  ),
                )
              : tree == null
              ? Center(
                  child: Text(
                    loading ? 'Loading Sessions…' : 'No catalog loaded',
                  ),
                )
              : ListView(
                  children: [
                    if (tree!.sessions.isEmpty)
                      const ListTile(title: Text('No Sessions yet')),
                    for (final session in tree!.sessions)
                      ExpansionTile(
                        key: PageStorageKey('session-${session.id}'),
                        initiallyExpanded: true,
                        title: Text(session.name),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'New instance',
                              icon: const Icon(Icons.add),
                              onPressed:
                                  busy ||
                                      loading ||
                                      session.instances.length >=
                                          tree!.instancesPerSession
                                  ? null
                                  : () => onCreateInstance(session),
                            ),
                            PopupMenuButton<String>(
                              tooltip: 'Session actions',
                              enabled: !busy && !loading,
                              onSelected: (action) {
                                if (action == 'close') onCloseSession(session);
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                  value: 'close',
                                  child: Text('Close session'),
                                ),
                              ],
                            ),
                          ],
                        ),
                        children: [
                          for (final instance in session.instances)
                            ListTile(
                              selected: selectedInstanceId == instance.id,
                              contentPadding: const EdgeInsets.only(
                                left: 36,
                                right: 16,
                              ),
                              leading: Icon(
                                instance.running
                                    ? Icons.terminal
                                    : Icons.power_settings_new,
                                size: 20,
                              ),
                              title: Text('Instance ${instance.id}'),
                              subtitle: instance.running
                                  ? null
                                  : const Text('Exited'),
                              onTap: () => onSelectInstance(session, instance),
                            ),
                        ],
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
