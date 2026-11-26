import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:proxy_claude/models/provider_config.dart';
import 'package:proxy_claude/services/settings_service.dart';
import 'package:proxy_claude/state/controllers.dart';
import 'package:proxy_claude/ui/pages/providers_page.dart';

class _StubSync extends SyncController {
  _StubSync(this._state);
  final SyncState _state;

  @override
  SyncState build() => _state;
}

Widget makePage({List<ProviderConfig> providers = const []}) {
  final svc = SettingsService()..providers = providers;
  return ProviderScope(
    overrides: [
      settingsServiceProvider.overrideWithValue(svc),
      syncControllerProvider.overrideWith(() => _StubSync(const SyncState.initial())),
    ],
    child: const MaterialApp(home: Scaffold(body: ProvidersPage())),
  );
}

void main() {
  testWidgets('catalog shows featured providers and expands the rest',
      (tester) async {
    await tester.pumpWidget(makePage());
    await tester.pumpAndSettle();

    expect(find.text('POPULAR PROVIDERS'), findsOneWidget);
    expect(find.text('OpenRouter'), findsOneWidget);
    expect(find.text('Google Gemini'), findsOneWidget);
    expect(find.text('Groq'), findsOneWidget);
    // Hidden behind "Show more providers".
    expect(find.text('DeepSeek'), findsNothing);
    expect(find.text('Show more providers'), findsOneWidget);

    await tester.tap(find.text('Show more providers'));
    await tester.pumpAndSettle();

    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('Custom Provider'), findsOneWidget);
    expect(find.text('FREE TIER'), findsWidgets);
  });

  testWidgets('connect dialog opens with key field and key source hint',
      (tester) async {
    await tester.pumpWidget(makePage());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Connect').first);
    await tester.pumpAndSettle();

    expect(find.text('Connect OpenRouter'), findsOneWidget);
    expect(find.text('API key'), findsOneWidget);
    expect(find.text('Get your key at openrouter.ai/settings/keys'),
        findsOneWidget);
    expect(find.text('Test connection'), findsOneWidget);
    expect(find.text('Advanced options'), findsOneWidget);
  });

  testWidgets('configured provider shows Connected chip and Manage button',
      (tester) async {
    final groq = ProviderConfig.defaultFor(ProviderPreset.groq)
        .copyWith(enabled: true, apiKey: 'test-key');
    await tester.pumpWidget(makePage(providers: [groq]));
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Manage'), findsOneWidget);
    expect(find.text('CONFIGURED'), findsOneWidget);
    // Other (unconfigured) catalog rows still offer Connect.
    expect(find.text('Connect'), findsNWidgets(3));
  });

  testWidgets('a disabled provider offers a one-tap Enable all', (tester) async {
    final disabled = ProviderConfig.defaultFor(ProviderPreset.groq)
        .copyWith(enabled: false, apiKey: 'test-key');
    await tester.pumpWidget(makePage(providers: [disabled]));
    await tester.pumpAndSettle();

    expect(find.text('Disabled'), findsOneWidget);
    expect(find.text('Enable all'), findsOneWidget);
  });

  testWidgets('a keyless provider says it is not used for routing',
      (tester) async {
    final keyless = ProviderConfig.defaultFor(ProviderPreset.googleGemini)
        .copyWith(enabled: true);
    await tester.pumpWidget(makePage(providers: [keyless]));
    await tester.pumpAndSettle();

    // The Configured section sits below the catalog in a lazy ListView.
    await tester.scrollUntilVisible(
        find.textContaining('API key required'), 240,
        scrollable: find.byType(Scrollable).first);
    expect(
        find.textContaining('API key required — not used for routing'),
        findsOneWidget);
  });

  testWidgets('custom provider form matches the Zed-style layout',
      (tester) async {
    await tester.pumpWidget(makePage());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Show more providers'));
    await tester.pumpAndSettle();
    // Custom is the last catalog row — bring it into the viewport first.
    await tester.ensureVisible(find.text('Custom Provider'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect').last);
    await tester.pumpAndSettle();

    expect(find.text('Provider ID'), findsOneWidget);
    expect(find.text('Display name'), findsOneWidget);
    expect(find.text('Provider API'), findsOneWidget);
    expect(find.text('OpenAI Compatible'), findsOneWidget);
    expect(find.text('Base URL'), findsOneWidget);
    // 'API key' matches the field label and the field's hint text.
    expect(find.text('API key'), findsNWidgets(2));
    expect(find.text('Optional. Leave empty if you manage auth via headers.'),
        findsOneWidget);
    expect(find.text('Models'), findsOneWidget);
    expect(find.text('Fetch models'), findsOneWidget);
    expect(find.text('ID'), findsOneWidget);
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Add model'), findsOneWidget);
  });
}
