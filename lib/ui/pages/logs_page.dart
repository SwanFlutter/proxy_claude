import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/log_entry.dart';
import '../../state/controllers.dart';
import '../widgets/common.dart';

class LogsPage extends ConsumerStatefulWidget {
  const LogsPage({super.key});

  @override
  ConsumerState<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends ConsumerState<LogsPage> {
  LogCategory? _category;
  StreamSubscription<LogEntry>? _sub;
  List<LogEntry> _entries = [];

  @override
  void initState() {
    super.initState();
    final logs = ref.read(logServiceProvider);
    _entries = logs.entries;
    _sub = logs.stream.listen((e) {
      if (mounted) setState(() => _entries = logs.entries);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var shown = _category == null
        ? _entries
        : _entries.where((e) => e.category == _category).toList();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            for (final (label, cat) in const [
              ('All', null),
              ('Requests', LogCategory.request),
              ('Tunnel', LogCategory.tunnel),
              ('Sync', LogCategory.sync),
              ('System', LogCategory.system),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(label),
                  selected: _category == cat,
                  onSelected: (_) => setState(() => _category = cat),
                ),
              ),
            const Spacer(),
            IconButton(
              tooltip: 'Clear logs',
              onPressed: () =>
                  ref.read(logServiceProvider).clear(),
              icon: const Icon(Icons.clear_all, size: 18),
            ),
          ]),
          const SizedBox(height: 10),
          Expanded(
            child: shown.isEmpty
                ? Center(
                    child: Text('No log entries.',
                        style: theme.textTheme.bodyMedium))
                : Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: theme.colorScheme.outlineVariant
                              .withValues(alpha: 0.4)),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, i) {
                        final e = shown[i];
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 62,
                                child: Text(e.timeLabel,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.outline,
                                        fontFamily: 'monospace')),
                              ),
                              StatusDot(color: logColor(context, e.level), size: 8),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 66,
                                child: Text(e.category.name,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                        color: theme.colorScheme.outline)),
                              ),
                              Expanded(
                                child: Text(e.message,
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(fontFamily: 'monospace')),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
