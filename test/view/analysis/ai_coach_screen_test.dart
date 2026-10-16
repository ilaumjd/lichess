import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/db/secure_storage.dart';
import 'package:lichess_mobile/src/model/analysis/analysis_controller.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/view/analysis/ai_coach_screen.dart';
import 'package:lichess_mobile/src/view/analysis/analysis_screen.dart';
import 'package:lichess_mobile/src/view/settings/ai_coach_settings_screen.dart';
import 'package:material_ui/material_ui.dart';

import '../../test_provider_scope.dart';

void main() {
  for (final allowed in [false, true]) {
    testWidgets('analysis menu respects computer analysis permission: $allowed', (tester) async {
      final app = await makeTestProviderScopeApp(
        tester,
        home: AnalysisScreen(
          options: AnalysisOptions.pgn(
            id: const StringId('ai-coach-test'),
            pgn: '',
            isComputerAnalysisAllowed: allowed,
            orientation: Side.white,
            variant: Variant.standard,
          ),
        ),
      );
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      expect(find.text('Explain position (AI)'), allowed ? findsOneWidget : findsNothing);
    });
  }

  testWidgets('shows disclosure and evidence without automatically requesting an explanation', (
    tester,
  ) async {
    final app = await makeTestProviderScopeApp(
      tester,
      home: const AiCoachScreen(evidence: 'FEN: example position'),
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    expect(find.text('Explain'), findsOneWidget);
    expect(find.textContaining('Nothing is sent automatically'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('Position and engine evidence'));
    await tester.pumpAndSettle();
    expect(find.text('FEN: example position'), findsOneWidget);
  });

  testWidgets('missing API key gives settings guidance', (tester) async {
    final app = await makeTestProviderScopeApp(
      tester,
      home: const AiCoachScreen(evidence: 'FEN: example position'),
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Explain'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Add your OpenAI API key'), findsOneWidget);
  });

  testWidgets('settings save and remove the API key in secure storage', (tester) async {
    final app = await makeTestProviderScopeApp(tester, home: const AiCoachSettingsScreen());
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField).first).obscureText, isTrue);
    await tester.enterText(find.byType(TextField).first, 'fake-widget-test-key');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(await SecureStorage.instance.read(key: aiCoachKeyStorage), 'fake-widget-test-key');
    expect(await SecureStorage.instance.read(key: aiCoachModelStorage), aiCoachDefaultModel);
    await tester.tap(find.text('Remove API key'));
    await tester.pumpAndSettle();
    expect(await SecureStorage.instance.read(key: aiCoachKeyStorage), isNull);
    expect(find.text('API key removed.'), findsOneWidget);
  });
}
