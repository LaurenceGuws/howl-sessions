import 'package:flutter/material.dart';

/// Phones open one terminal at a time. Back detaches the view, never the process.
/// Wide windows retain the catalog alongside the terminal.
final class SessionWorkspace extends StatelessWidget {
  const SessionWorkspace({
    super.key,
    required this.catalog,
    required this.terminal,
    required this.hasSelection,
    required this.onBack,
  });

  final Widget catalog;
  final Widget terminal;
  final bool hasSelection;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth >= 700) {
        return Row(
          children: [
            SizedBox(width: 300, child: catalog),
            const VerticalDivider(width: 1),
            Expanded(child: terminal),
          ],
        );
      }
      if (!hasSelection) return catalog;
      return PopScope<Object?>(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) onBack();
        },
        child: Column(
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
                label: const Text('Sessions'),
              ),
            ),
            Expanded(child: terminal),
          ],
        ),
      );
    },
  );
}
