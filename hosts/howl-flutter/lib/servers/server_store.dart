import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'configured_server.dart';

/// Stores only host-owned endpoint preferences, never server catalogs.
final class ServerStore {
  static const maxServers = 32;
  static const maxEncodedBytes = 65536;
  static const _key = 'howl.sessions.servers.v1';

  final _preferences = SharedPreferencesAsync();

  Future<List<ConfiguredServer>> load() async {
    final raw = await _preferences.getString(_key);
    if (raw == null) return const [];
    if (utf8.encode(raw).length > maxEncodedBytes) {
      throw const FormatException('Saved Servers exceed 64 KiB');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Invalid saved Servers list');
    }
    if (decoded.length > maxServers) {
      throw const FormatException('At most 32 Servers may be saved');
    }
    final servers = decoded.map(ConfiguredServer.fromJson).toList();
    if (servers.map((server) => server.endpoint).toSet().length !=
        servers.length) {
      throw const FormatException('Duplicate saved Server endpoints');
    }
    return List.unmodifiable(servers);
  }

  Future<void> save(List<ConfiguredServer> servers) async {
    if (servers.length > maxServers) {
      throw const FormatException('At most 32 Servers may be saved');
    }
    for (final server in servers) {
      server.validate();
    }
    if (servers.map((server) => server.endpoint).toSet().length !=
        servers.length) {
      throw const FormatException('Duplicate saved Server endpoints');
    }
    final encoded = jsonEncode(
      servers.map((server) => server.toJson()).toList(),
    );
    if (utf8.encode(encoded).length > maxEncodedBytes) {
      throw const FormatException('Saved Servers exceed 64 KiB');
    }
    await _preferences.setString(_key, encoded);
  }
}
