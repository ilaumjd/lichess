import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/view/analysis/ai_coach_position_screen.dart';
import 'package:lichess_mobile/src/view/more/more_tab_screen.dart';
import 'package:material_ui/material_ui.dart';

import '../../test_provider_scope.dart';

void main() {
  testWidgets('garbage input shows an error and does not open the coach', (tester) async {
    final app = await makeTestProviderScopeApp(tester, home: const AiCoachPositionScreen());
    await tester.pumpWidget(app);
    await tester.enterText(find.byType(TextField), 'not a position');
    await tester.tap(find.text('Analyse and explain'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not find'), findsOneWidget);
    expect(find.text('Explain position'), findsNothing);
  });

  testWidgets('empty input asks for a FEN or PGN', (tester) async {
    final app = await makeTestProviderScopeApp(tester, home: const AiCoachPositionScreen());
    await tester.pumpWidget(app);
    await tester.tap(find.text('Analyse and explain'));
    await tester.pumpAndSettle();
    expect(find.text('Paste a FEN or a PGN first.'), findsOneWidget);
  });

  testWidgets('a valid FEN is analysed and the coach waits for Explain', (tester) async {
    final app = await makeTestProviderScopeApp(tester, home: const AiCoachPositionScreen());
    await tester.pumpWidget(app);
    await tester.enterText(find.byType(TextField), kInitialFEN);
    await tester.tap(find.text('Analyse and explain'));
    // The threat search gives up after a few seconds when the (fake) engine says nothing. The
    // progress spinner animates forever, so pump until the screen is ready instead of settling.
    var pumps = 0;
    // The board is the first thing drawn once the position has been analysed.
    while (pumps < 300 && find.byType(StaticChessboard).evaluate().isEmpty) {
      await tester.pump(const Duration(milliseconds: 100));
      pumps++;
    }
    await tester.pumpAndSettle();
    // Analysed on the device (here from the fake cloud evaluation) and waiting for the user to
    // tap Explain: nothing has been sent anywhere.
    expect(find.text('Explain position'), findsOneWidget);
    expect(find.byType(StaticChessboard), findsOneWidget);
    // The board pushes the rest further down the lazily built list.
    await tester.scrollUntilVisible(
      find.text('Position and engine evidence'),
      300,
      scrollable: find
          .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
          .first,
    );
    expect(find.text('Position and engine evidence'), findsOneWidget);
  });

  testWidgets('clear button empties the field and the error', (tester) async {
    final app = await makeTestProviderScopeApp(tester, home: const AiCoachPositionScreen());
    await tester.pumpWidget(app);
    await tester.enterText(find.byType(TextField), 'nonsense');
    await tester.tap(find.text('Analyse and explain'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('nonsense'), findsNothing);
    expect(find.textContaining('Could not find'), findsNothing);
  });

  testWidgets('the More tab lists the AI coach', (tester) async {
    final app = await makeTestProviderScopeApp(tester, home: const MoreTabScreen());
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    expect(find.text('AI coach'), findsOneWidget);
  });
}
