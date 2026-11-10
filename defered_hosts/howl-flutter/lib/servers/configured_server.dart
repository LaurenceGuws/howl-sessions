import 'dart:convert';

/// A locally configured endpoint, not a Server occurrence or a Session.
final class ConfiguredServer {
  const ConfiguredServer({required this.name, required this.endpoint});

  final String name;
  final String endpoint;

  factory ConfiguredServer.fromJson(Object? json) {
    if (json case {'name': String name, 'endpoint': String endpoint}) {
      final server = ConfiguredServer(name: name, endpoint: endpoint);
      server.validate();
      return server;
    }
    throw const FormatException('Invalid saved Server endpoint');
  }

  static const maxNameScalars = 64;
  static const maxEndpointBytes = 1024;

  static String? nameError(String value) {
    if (value.trim().isEmpty) return 'Enter a server name';
    if (value.runes.length > maxNameScalars) return 'Use at most 64 characters';
    if (_hasControl(value)) return 'Control characters are not allowed';
    return null;
  }

  static String? endpointError(String value) {
    if (value.trim().isEmpty) return 'Enter an endpoint';
    if (utf8.encode(value).length > maxEndpointBytes) {
      return 'Endpoint exceeds 1024 UTF-8 bytes';
    }
    if (_hasControl(value)) return 'Control characters are not allowed';
    return null;
  }

  static bool _hasControl(String value) =>
      value.runes.any((c) => c < 32 || c == 127);

  void validate() {
    final error = nameError(name) ?? endpointError(endpoint);
    if (error != null || name != name.trim() || endpoint != endpoint.trim()) {
      throw FormatException(
        error ?? 'Saved endpoint has surrounding whitespace',
      );
    }
  }

  Map<String, String> toJson() => {'name': name, 'endpoint': endpoint};
}
