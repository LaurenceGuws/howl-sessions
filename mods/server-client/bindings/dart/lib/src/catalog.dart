/// The server-assigned, live identity of an Instance within a Session.
final class InstanceEntry {
  const InstanceEntry({required this.id, required this.running});

  final BigInt id;
  final bool running;
}

/// Session identity, label and its current Instances from one Server snapshot.
final class SessionEntry {
  const SessionEntry({
    required this.id,
    required this.name,
    required this.instances,
  });

  final BigInt id;
  final String name;
  final List<InstanceEntry> instances;
}

/// Immutable, copied Server catalog; nothing here borrows a native pointer.
final class SessionTree {
  const SessionTree({
    required this.serverId,
    required this.revision,
    required this.sessionCapacity,
    required this.instancesPerSession,
    required this.sessions,
  });

  final BigInt serverId;
  final BigInt revision;
  final int sessionCapacity;
  final int instancesPerSession;
  final List<SessionEntry> sessions;
}

/// Native status codes are preserved so product hosts can handle rejection.
final class ServerClientFailure implements Exception {
  const ServerClientFailure(this.operation, this.status);

  final String operation;
  final int status;

  @override
  String toString() => 'Server $operation failed (status $status)';
}
