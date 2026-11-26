import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/log_entry.dart';

/// Small colored status dot.
class StatusDot extends StatelessWidget {
  final Color color;
  final double size;

  const StatusDot({super.key, required this.color, this.size = 10});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
}

/// Card with a compact section header.
class SectionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget? trailing;
  final Widget child;

  const SectionCard({
    super.key,
    required this.icon,
    required this.title,
    this.trailing,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const Spacer(),
                ?trailing,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

/// FREE badge chip.
class FreeBadge extends StatelessWidget {
  const FreeBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.green.withValues(alpha: 0.5)),
      ),
      child: const Text(
        'FREE',
        style: TextStyle(
            fontSize: 10, fontWeight: FontWeight.w700, color: Colors.green),
      ),
    );
  }
}

void showSnack(BuildContext context, String message,
    {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message),
    behavior: SnackBarBehavior.floating,
    width: 420,
    backgroundColor: error
        ? Theme.of(context).colorScheme.errorContainer
        : null,
  ));
}

void copyToClipboard(BuildContext context, String text, String label) {
  Clipboard.setData(ClipboardData(text: text));
  showSnack(context, '$label copied to clipboard');
}

Color logColor(BuildContext context, LogLevel level) => switch (level) {
      LogLevel.debug => Theme.of(context).colorScheme.outline,
      LogLevel.info => Colors.green,
      LogLevel.warn => Colors.orange,
      LogLevel.error => Theme.of(context).colorScheme.error,
    };
