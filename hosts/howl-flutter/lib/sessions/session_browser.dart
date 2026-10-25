import 'package:flutter/material.dart';
import 'package:howl_server_client/howl_server_client.dart';

import '../instances/instance_view.dart';
import '../servers/configured_server.dart';
import 'session_catalog.dart';

/// Owns the selected Server catalog and short-lived management requests.
/// A terminal observation connection is never shared with these requests.
final class SessionBrowser extends StatefulWidget {
  const SessionBrowser({
    super.key,
    required this.servers,
    required this.selectedEndpoint,
    required this.onSelectServer,
    required this.onOpenSettings,
  });

  final List<ConfiguredServer> servers;
  final String? selectedEndpoint;
  final ValueChanged<String> onSelectServer;
  final VoidCallback onOpenSettings;

  @override
  State<SessionBrowser> createState() => _SessionBrowserState();
}

final class _SessionBrowserState extends State<SessionBrowser> {
  final _client = const ServerClient();
  SessionTree? _tree;
  SessionEntry? _selectedSession;
  InstanceEntry? _selectedInstance;
  String? _failure;
  bool _loading = false;
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh({BigInt? selectSession, BigInt? selectInstance}) async {
    final endpoint = widget.selectedEndpoint;
    if (endpoint == null) return;
    final generation = ++_requestGeneration;
    setState(() {
      _loading = true;
      _failure = null;
    });
    try {
      final tree = await _client.readTree(endpoint);
      if (!mounted || generation != _requestGeneration) return;
      final wanted = selectSession ?? _selectedSession?.id;
      SessionEntry? selected;
      for (final session in tree.sessions) {
        if (session.id == wanted) selected = session;
      }
      InstanceEntry? instance;
      for (final entry in selected?.instances ?? const <InstanceEntry>[]) {
        if (entry.id == (selectInstance ?? _selectedInstance?.id)) {
          instance = entry;
        }
      }
      setState(() {
        _tree = tree;
        _selectedSession = selected;
        _selectedInstance = instance;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _failure = error.toString();
        _loading = false;
      });
    }
  }

  Future<void> _createSession() async {
    final endpoint = widget.selectedEndpoint;
    if (endpoint == null) return;
    final name = await _askSessionName(context);
    if (name == null || !mounted) return;
    try {
      final identity = await _client.createSession(endpoint, name);
      if (mounted) await _refresh(selectSession: identity);
    } catch (error) {
      if (mounted) setState(() => _failure = error.toString());
    }
  }

  Future<void> _closeSession(SessionEntry session) async {
    final endpoint = widget.selectedEndpoint;
    if (endpoint == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Close ${session.name}?'),
        content: const Text(
          'Closes this Session and its running Instances on the Server.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await _client.closeSession(endpoint, session.id);
      if (mounted) await _refresh();
    } catch (error) {
      if (mounted) setState(() => _failure = error.toString());
    }
  }

  Future<void> _createInstance(SessionEntry session) async {
    final endpoint = widget.selectedEndpoint;
    if (endpoint == null) return;
    final shell = await _askShell(context);
    if (shell == null || !mounted) return;
    try {
      final id = await _client.createInstance(
        endpoint,
        InstanceLaunch(
          sessionId: session.id,
          shell: shell,
          rows: 24,
          columns: 80,
          historyRows: 1024,
        ),
      );
      if (mounted) {
        await _refresh(selectSession: session.id, selectInstance: id);
      }
    } catch (error) {
      if (mounted) setState(() => _failure = error.toString());
    }
  }

  Future<void> _closeInstance() async {
    final endpoint = widget.selectedEndpoint;
    final session = _selectedSession;
    final instance = _selectedInstance;
    if (endpoint == null || session == null || instance == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Close Instance ${instance.id}?'),
        content: const Text('Stops its process on the Server.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await _client.closeInstance(endpoint, session.id, instance.id);
      if (mounted) await _refresh();
    } catch (error) {
      if (mounted) setState(() => _failure = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = SessionCatalog(
      servers: widget.servers,
      selectedEndpoint: widget.selectedEndpoint,
      tree: _tree,
      loading: _loading,
      selectedInstanceId: _selectedInstance?.id,
      onSelectServer: widget.onSelectServer,
      onOpenSettings: widget.onOpenSettings,
      onRefresh: _refresh,
      onCreateSession: _createSession,
      onCloseSession: _closeSession,
      onCreateInstance: _createInstance,
      onSelectInstance: (session, instance) => setState(() {
        _selectedSession = session;
        _selectedInstance = instance;
      }),
    );
    final instance = InstanceView(
      key: ValueKey((
        widget.selectedEndpoint,
        _tree?.serverId,
        _selectedSession?.id,
        _selectedInstance?.id,
      )),
      endpoint: widget.selectedEndpoint,
      serverId: _tree?.serverId,
      session: _selectedSession,
      instance: _selectedInstance,
      onClose: _closeInstance,
    );
    return Column(
      children: [
        if (_failure != null)
          MaterialBanner(
            content: Text(_failure!),
            actions: [
              TextButton(onPressed: _refresh, child: const Text('Retry')),
            ],
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth >= 700
                ? Row(
                    children: [
                      SizedBox(width: 300, child: catalog),
                      const VerticalDivider(width: 1),
                      Expanded(child: instance),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(flex: 2, child: catalog),
                      const Divider(height: 1),
                      Expanded(flex: 3, child: instance),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

Future<String?> _askShell(BuildContext context) async {
  final shell = TextEditingController(text: '/bin/sh');
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('New Instance'),
          content: TextField(
            controller: shell,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Shell on the selected Server',
              helperText: 'Initial geometry: 24 × 80 cells',
            ),
            onChanged: (_) => update(() {}),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: shell.text.trim().isNotEmpty
                  ? () => Navigator.pop(context, shell.text.trim())
                  : null,
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  } finally {
    shell.dispose();
  }
}

Future<String?> _askSessionName(BuildContext context) async {
  final name = TextEditingController();
  final validName = RegExp(r'^[A-Za-z0-9._-]{1,64}$');
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('New Session'),
          content: TextField(
            controller: name,
            autofocus: true,
            maxLength: 64,
            decoration: const InputDecoration(
              labelText: 'Session name',
              helperText: 'Letters, numbers, dot, underscore, hyphen',
            ),
            onChanged: (_) => update(() {}),
            onSubmitted: (value) {
              if (validName.hasMatch(value)) Navigator.pop(context, value);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: validName.hasMatch(name.text)
                  ? () => Navigator.pop(context, name.text)
                  : null,
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  } finally {
    name.dispose();
  }
}
