/// An owning text-only projection of one immutable terminal observation.
///
/// This is suitable for a transport/ABI canary and diagnostics, not a renderer:
/// colors, attributes, graphics and cell geometry remain in the native snapshot.
final class TerminalTextSnapshot {
  const TerminalTextSnapshot({
    required this.serverId,
    required this.sessionId,
    required this.instanceId,
    required this.clientId,
    required this.deliveryRevision,
    required this.terminalRevision,
    required this.rows,
    required this.columns,
    required this.cursorRow,
    required this.cursorColumn,
    required this.lines,
  });

  final BigInt serverId;
  final BigInt sessionId;
  final BigInt instanceId;
  final BigInt clientId;
  final BigInt deliveryRevision;
  final BigInt terminalRevision;
  final int rows;
  final int columns;
  final int cursorRow;
  final int cursorColumn;
  final List<String> lines;
}
