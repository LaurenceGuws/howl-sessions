/// A request to create one real remote Instance, not a viewport or Session.
final class InstanceLaunch {
  const InstanceLaunch({
    required this.sessionId,
    required this.shell,
    required this.rows,
    required this.columns,
    required this.historyRows,
    this.command,
    this.cwd,
  });

  final BigInt sessionId;
  final String shell;
  final int rows;
  final int columns;
  final int historyRows;
  final String? command;
  final String? cwd;
}
