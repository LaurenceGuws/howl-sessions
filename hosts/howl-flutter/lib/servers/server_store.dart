import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'configured_server.dart';

/// Stores only host-owned endpoint preferences, never server catalogs.
final class ServerStore {
  static const _key = 'howl.sessions.servers.v1';

  final _preferences = SharedPreferencesAsync();

  Future<List<ConfiguredServer>> load() async {
    final raw = await _preferences.getString(_key);
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Invalid saved Servers list');
    }
    final servers = decoded.map(ConfiguredServer.fromJson).toList();
    if (servers.map((server) => server.endpoint).toSet().length !=
        servers.length) {
      throw const FormatException('Duplicate saved Server endpoints');
    }
    return List.unmodifiable(servers);
  }

  Future<void> save(List<ConfiguredServer> servers) => _preferences.setString(
    _key,
    jsonEncode(servers.map((server) => server.toJson()).toList()),
  );
}
