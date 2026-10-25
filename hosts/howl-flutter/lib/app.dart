import 'package:flutter/material.dart';

import 'servers/configured_server.dart';
import 'servers/server_store.dart';
import 'servers/servers_settings.dart';
import 'sessions/session_browser.dart';

/// Flutter owns device configuration and presentation, not terminal semantics.
final class HowlSessionsApp extends StatelessWidget {
  const HowlSessionsApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Howl Sessions',
    theme: ThemeData.dark(useMaterial3: true),
    home: const _Home(),
  );
}

final class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

final class _HomeState extends State<_Home> {
  final _store = ServerStore();
  List<ConfiguredServer> _servers = const [];
  String? _selectedEndpoint;
  String? _settingsFailure;
  bool _ready = false;
  bool _settings = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final saved = await _store.load();
      if (!mounted) return;
      setState(() {
        _servers = saved;
        _selectedEndpoint = saved.firstOrNull?.endpoint;
        _ready = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _settingsFailure = error.toString();
        _ready = true;
        _settings = true;
      });
    }
  }

  Future<void> _save(List<ConfiguredServer> next) async {
    try {
      await _store.save(next);
      if (!mounted) return;
      setState(() {
        _servers = List.unmodifiable(next);
        if (!next.any((server) => server.endpoint == _selectedEndpoint)) {
          _selectedEndpoint = next.firstOrNull?.endpoint;
        }
        _settingsFailure = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _settingsFailure = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_settings ? 'Settings' : 'Howl Sessions'),
        actions: [
          IconButton(
            tooltip: _settings ? 'Sessions' : 'Settings',
            icon: Icon(_settings ? Icons.arrow_back : Icons.settings_outlined),
            onPressed: () => setState(() => _settings = !_settings),
          ),
        ],
      ),
      body: !_ready
          ? const Center(child: Text('Loading saved servers…'))
          : Column(
              children: [
                if (_settingsFailure != null)
                  MaterialBanner(
                    content: Text(
                      'Could not save or load settings: $_settingsFailure',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () =>
                            setState(() => _settingsFailure = null),
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ),
                Expanded(
                  child: _settings
                      ? ServersSettings(servers: _servers, onChanged: _save)
                      : SessionBrowser(
                          key: ValueKey(_selectedEndpoint),
                          servers: _servers,
                          selectedEndpoint: _selectedEndpoint,
                          onSelectServer: (endpoint) =>
                              setState(() => _selectedEndpoint = endpoint),
                          onOpenSettings: () =>
                              setState(() => _settings = true),
                        ),
                ),
              ],
            ),
    );
  }
}
