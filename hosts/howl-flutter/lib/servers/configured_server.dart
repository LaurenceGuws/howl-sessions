/// A locally configured endpoint, not a Server occurrence or a Session.
final class ConfiguredServer {
  const ConfiguredServer({required this.name, required this.endpoint});

  final String name;
  final String endpoint;

  factory ConfiguredServer.fromJson(Object? json) {
    if (json case {'name': String name, 'endpoint': String endpoint}) {
      if (name.isNotEmpty && endpoint.isNotEmpty) {
        return ConfiguredServer(name: name, endpoint: endpoint);
      }
    }
    throw const FormatException('Invalid saved Server endpoint');
  }

  Map<String, String> toJson() => {'name': name, 'endpoint': endpoint};
}
