import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:howl_sessions/instances/terminal_geometry.dart';

void main() {
  test('viewport fit uses actual native cell metrics', () {
    final fit = TerminalCellGeometry.fit(
      const Size(365, 197),
      cellWidth: 9,
      cellHeight: 19,
    );
    expect(fit?.columns, 40);
    expect(fit?.rows, 10);
    expect(fit, TerminalCellGeometry(10, 40));
    expect(fit.hashCode, TerminalCellGeometry(10, 40).hashCode);
  });

  test('insets change rows without claiming sizing authority', () {
    final full = TerminalCellGeometry.fit(
      const Size(360, 420),
      cellWidth: 10,
      cellHeight: 20,
    );
    final withIme = TerminalCellGeometry.fit(
      const Size(360, 240),
      cellWidth: 10,
      cellHeight: 20,
    );
    expect(full, TerminalCellGeometry(21, 36));
    expect(withIme, TerminalCellGeometry(12, 36));
  });

  test('no resize intent for unusable or invalid drawable rectangles', () {
    expect(
      TerminalCellGeometry.fit(
        const Size(5, 100),
        cellWidth: 10,
        cellHeight: 20,
      ),
      isNull,
    );
    expect(
      TerminalCellGeometry.fit(
        const Size(100, 5),
        cellWidth: 10,
        cellHeight: 20,
      ),
      isNull,
    );
    expect(
      TerminalCellGeometry.fit(
        const Size(100, 100),
        cellWidth: 0,
        cellHeight: 20,
      ),
      isNull,
    );
    expect(
      TerminalCellGeometry.fit(
        const Size(double.infinity, 100),
        cellWidth: 10,
        cellHeight: 20,
      ),
      isNull,
    );
  });

  test('large viewports stay within native u16 cell bounds', () {
    expect(
      TerminalCellGeometry.fit(
        const Size(100000, 100000),
        cellWidth: 1,
        cellHeight: 1,
      ),
      TerminalCellGeometry(65535, 65535),
    );
  });
}
