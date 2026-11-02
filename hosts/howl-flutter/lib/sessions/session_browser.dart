import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:howl_server_client/howl_server_client.dart';

import '../instances/instance_view.dart';
import '../servers/configured_server.dart';
import 'session_catalog.dart';
import 'session_workspace.dart';

/// Owns the selected Server catalog and short-lived management requests.
/// A terminal observation connection is never shared with these requests.
final class SessionBrowser extends StatefulWidget {
  const SessionBrowser({
    super.key,
    required this.servers,
    required this.selectedEndpoint,
    required this.onSelectServer,
    required this.onOpenSettings,
    this.client = const ServerClient(),
  });

  final ServerManagement client;
  final List<ConfiguredServer> servers;
  final String? selectedEndpoint;
  final ValueChanged<String> onSelectServer;
  final VoidCallback onOpenSettings;

  @override
  State<SessionBrowser> createState() => _SessionBrowserState();
}

final class _SessionBrowserState extends State<SessionBrowser> {
  ServerManagement get _client => widget.client;
  bool _busy = false;
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

  @override
  void didUpdateWidget(covariant SessionBrowser oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedEndpoint != oldWidget.selectedEndpoint ||
        widget.client != oldWidget.client) {
      ++_requestGeneration;
      _tree = null;
      _loading = false;
      _failure = null;
      _selectedSession = null;
      _selectedInstance = null;
      _refresh();
    }
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
      // Numeric IDs are meaningful only within the catalog incarnation.
      final sameServer = _tree?.serverId == tree.serverId;
      final wanted = sameServer
          ? (selectSession ?? _selectedSession?.id)
          : null;
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
    final tree = _tree;
    final client = _client;
    if (_busy || _loading || tree == null) return;
    setState(() => _busy = true);
    try {
      final endpoint = widget.selectedEndpoint;
      if (endpoint == null) return;
      final name = await _askSessionName(context);
      if (name == null ||
          !mounted ||
          endpoint != widget.selectedEndpoint ||
          !identical(client, _client) ||
          tree.serverId != _tree?.serverId) {
        return;
      }
      try {
        final identity = await client.createSession(
          endpoint,
          name,
          serverId: tree.serverId,
        );
        if (mounted && endpoint == widget.selectedEndpoint) {
          await _refresh(selectSession: identity);
        }
      } catch (error) {
        if (mounted && endpoint == widget.selectedEndpoint) {
          setState(() => _failure = error.toString());
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _closeSession(SessionEntry session) async {
    final tree = _tree;
    final client = _client;
    if (_busy || _loading || tree == null) return;
    setState(() => _busy = true);
    try {
      final endpoint = widget.selectedEndpoint;
      if (endpoint == null) return;
      final confirmed = await _confirmClose(
        context,
        title: 'Close ${session.name}?',
        message: 'Closes this Session and its running Instances on the Server.',
      );
      if (!mounted ||
          confirmed != true ||
          endpoint != widget.selectedEndpoint ||
          !identical(client, _client) ||
          tree.serverId != _tree?.serverId) {
        return;
      }
      try {
        await client.closeSession(
          endpoint,
          session.id,
          serverId: tree.serverId,
        );
        if (mounted && endpoint == widget.selectedEndpoint) await _refresh();
      } catch (error) {
        if (mounted && endpoint == widget.selectedEndpoint) {
          setState(() => _failure = error.toString());
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createInstance(SessionEntry session) async {
    final tree = _tree;
    final client = _client;
    if (_busy || _loading || tree == null) return;
    setState(() => _busy = true);
    try {
      final endpoint = widget.selectedEndpoint;
      if (endpoint == null) return;
      final shell = await _askShell(context);
      if (shell == null ||
          !mounted ||
          endpoint != widget.selectedEndpoint ||
          !identical(client, _client) ||
          tree.serverId != _tree?.serverId) {
        return;
      }
      try {
        final id = await client.createInstance(
          endpoint,
          InstanceLaunch(
            sessionId: session.id,
            shell: shell,
            rows: 24,
            columns: 80,
            historyRows: 1024,
          ),
          serverId: tree.serverId,
        );
        if (mounted && endpoint == widget.selectedEndpoint) {
          await _refresh(selectSession: session.id, selectInstance: id);
        }
      } catch (error) {
        if (mounted && endpoint == widget.selectedEndpoint) {
          setState(() => _failure = error.toString());
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _closeInstance() async {
    final tree = _tree;
    final client = _client;
    if (_busy || _loading || tree == null) return;
    setState(() => _busy = true);
    try {
      final endpoint = widget.selectedEndpoint;
      final session = _selectedSession;
      final instance = _selectedInstance;
      if (endpoint == null || session == null || instance == null) return;
      final confirmed = await _confirmClose(
        context,
        title: 'Close Instance ${instance.id}?',
        message: 'Stops its process on the Server.',
      );
      if (!mounted ||
          confirmed != true ||
          endpoint != widget.selectedEndpoint ||
          !identical(client, _client) ||
          tree.serverId != _tree?.serverId) {
        return;
      }
      try {
        await client.closeInstance(
          endpoint,
          session.id,
          instance.id,
          serverId: tree.serverId,
        );
        if (mounted && endpoint == widget.selectedEndpoint) await _refresh();
      } catch (error) {
        if (mounted && endpoint == widget.selectedEndpoint) {
          setState(() => _failure = error.toString());
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = SessionCatalog(
      servers: widget.servers,
      selectedEndpoint: widget.selectedEndpoint,
      tree: _tree,
      loading: _loading,
      busy: _busy,
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
              TextButton(
                onPressed: _busy || _loading ? null : _refresh,
                child: const Text('Refresh catalog'),
              ),
            ],
          ),
        Expanded(
          child: SessionWorkspace(
            catalog: catalog,
            terminal: instance,
            hasSelection: _selectedInstance != null,
            onBack: () => setState(() {
              _selectedInstance = null;
            }),
          ),
        ),
      ],
    );
  }
}

Future<String?> _askShell(BuildContext context) => showDialog<String>(
  context: context,
  builder: (context) => const _CreateDialog(shell: true),
);

Future<String?> _askSessionName(BuildContext context) => showDialog<String>(
  context: context,
  builder: (context) => const _CreateDialog(shell: false),
);

final class _CreateDialog extends StatefulWidget {
  const _CreateDialog({required this.shell});
  final bool shell;

  @override
  State<_CreateDialog> createState() => _CreateDialogState();
}

final class _CreateDialogState extends State<_CreateDialog> {
  late String _value = widget.shell ? '/bin/sh' : '';
  bool _submitted = false;

  bool get _valid => widget.shell
      ? _value.trim().isNotEmpty &&
            !_value.contains('\x00') &&
            utf8.encode(_value.trim()).length <= 1024
      : RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(_value);

  void _submit() {
    if (_submitted || !_valid) return;
    _submitted = true;
    Navigator.pop(context, widget.shell ? _value.trim() : _value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.shell ? 'New Instance' : 'New Session'),
    content: TextFormField(
      initialValue: _value,
      autofocus: true,
      maxLength: widget.shell ? 1024 : 64,
      decoration: InputDecoration(
        labelText: widget.shell
            ? 'Shell on the selected Server'
            : 'Session name',
        helperText: widget.shell
            ? 'Initial geometry: 24 × 80 cells'
            : 'Letters, numbers, dot, underscore, hyphen',
      ),
      onChanged: (value) => setState(() => _value = value),
      onFieldSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () {
          if (_submitted) return;
          _submitted = true;
          Navigator.pop(context);
        },
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _valid && !_submitted ? _submit : null,
        child: const Text('Create'),
      ),
    ],
  );
}

Future<bool?> _confirmClose(
  BuildContext context, {
  required String title,
  required String message,
}) {
  var submitted = false;
  return showDialog<bool>(
    context: context,
    builder: (context) {
      void finish(bool confirmed) {
        if (submitted) return;
        submitted = true;
        Navigator.pop(context, confirmed);
      }

      return AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => finish(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => finish(true),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
