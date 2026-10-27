import 'dart:ui';

/// Only an actual drawable rectangle and native font cell metrics decide fit.
/// Zoom and pan do not participate in the terminal's canonical geometry.
final class TerminalCellGeometry {
  const TerminalCellGeometry(this.rows, this.columns);

  final int rows;
  final int columns;

  static TerminalCellGeometry? fit(
    Size drawable, {
    required int cellWidth,
    required int cellHeight,
  }) {
    if (!drawable.width.isFinite ||
        !drawable.height.isFinite ||
        cellWidth <= 0 ||
        cellHeight <= 0 ||
        drawable.width < cellWidth ||
        drawable.height < cellHeight) {
      return null;
    }
    return TerminalCellGeometry(
      (drawable.height ~/ cellHeight).clamp(1, 65535),
      (drawable.width ~/ cellWidth).clamp(1, 65535),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TerminalCellGeometry &&
      rows == other.rows &&
      columns == other.columns;

  @override
  int get hashCode => Object.hash(rows, columns);
}
