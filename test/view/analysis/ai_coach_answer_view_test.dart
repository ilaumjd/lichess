import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_answer.dart';
import 'package:lichess_mobile/src/model/engine/practice_comment.dart';
import 'package:lichess_mobile/src/view/analysis/ai_coach_answer_view.dart';
import 'package:material_ui/material_ui.dart';

import '../../test_provider_scope.dart';

AiCoachAnswer answer({AiCoachCheckResult? check, List<String> unverified = const []}) =>
    AiCoachAnswer.tryParse(
      '{"headline": "Nf3 was a fine move.", "sections": [ '
      '{"title": "Why", "text": "It develops the knight and eyes e5, then Bb5 comes."}, '
      '{"title": "Lesson", "text": "Develop before attacking."} ]}',
    )!.withCheck(check, unverified: unverified);

void main() {
  Future<void> show(WidgetTester tester, String stored, {MoveVerdict? verdict}) async {
    await tester.pumpWidget(
      await makeTestProviderScopeApp(
        tester,
        home: Scaffold(
          body: SingleChildScrollView(
            child: AiCoachAnswerView(stored: stored, verdict: verdict),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a structured answer shows its headline and a card per section', (tester) async {
    await show(tester, answer().toStored());
    expect(find.text('Nf3 was a fine move.', findRichText: true), findsOneWidget);
    expect(find.text('WHY'), findsOneWidget);
    expect(find.text('LESSON'), findsOneWidget);
    expect(find.byType(Card), findsNWidgets(2));
    expect(find.textContaining('Develop before attacking.', findRichText: true), findsOneWidget);
  });

  testWidgets('the moves named in the text are highlighted', (tester) async {
    await show(tester, answer().toStored());
    final spans = <TextSpan>[];
    for (final selectable in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
      selectable.textSpan?.visitChildren((span) {
        if (span is TextSpan && span.style?.backgroundColor != null) spans.add(span);
        return true;
      });
    }
    // Nf3 in the headline, and Bb5 in the first section.
    expect(spans.map((s) => s.text), containsAll(['Nf3', 'Bb5']));
    expect(spans.map((s) => s.text), isNot(contains('knight')));
  });

  testWidgets('the verdict badge uses the verdict the app computed', (tester) async {
    await show(tester, answer().toStored(), verdict: MoveVerdict.blunder);
    expect(find.text('Blunder'), findsOneWidget);
    final chip = tester.widget<Chip>(find.byType(Chip));
    expect(chip.backgroundColor, const Color(0xFFC62828));
  });

  testWidgets('every verdict has its own colour', (tester) async {
    final colours = <Color?>{};
    for (final verdict in MoveVerdict.values) {
      await show(tester, answer().toStored(), verdict: verdict);
      expect(find.text(aiCoachVerdictLabel(verdict)), findsOneWidget);
      colours.add(tester.widget<Chip>(find.byType(Chip)).backgroundColor);
    }
    expect(colours, hasLength(MoveVerdict.values.length));
  });

  testWidgets('no badge without a verdict', (tester) async {
    await show(tester, answer().toStored());
    expect(find.byType(Chip), findsNothing);
  });

  testWidgets('a verified answer says its moves were checked', (tester) async {
    await show(tester, answer(check: AiCoachCheckResult.verified).toStored());
    expect(find.text("Moves checked against Stockfish's lines"), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
  });

  testWidgets('an unverified answer names the moves it could not check', (tester) async {
    await show(
      tester,
      answer(check: AiCoachCheckResult.unverified, unverified: ['Qh5', 'Ke4']).toStored(),
    );
    expect(find.textContaining('Could not verify'), findsOneWidget);
    expect(find.textContaining('Qh5, Ke4'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('an answer with no check shows no check line', (tester) async {
    await show(tester, answer().toStored());
    expect(find.textContaining('checked'), findsNothing);
    expect(find.textContaining('Could not verify'), findsNothing);
  });

  testWidgets('plain text, as saved before this layout, is shown as it is', (tester) async {
    await show(tester, "Play Nf3 now.\n\n✓ Moves checked against Stockfish's lines.");
    expect(find.byType(Card), findsNothing);
    expect(find.textContaining('Play Nf3 now.'), findsOneWidget);
    expect(find.textContaining('✓ Moves checked'), findsOneWidget);
  });

  testWidgets('a section without a title still shows its text', (tester) async {
    await show(tester, '{"headline": "", "sections": [{"title": "", "text": "Only text here."}]}');
    expect(find.textContaining('Only text here.', findRichText: true), findsOneWidget);
  });

  testWidgets('it fits a narrow screen', (tester) async {
    await tester.pumpWidget(
      await makeTestProviderScopeApp(
        tester,
        surfaceSize: const Size(320, 640),
        home: Scaffold(
          body: SingleChildScrollView(
            child: AiCoachAnswerView(
              stored: answer(check: AiCoachCheckResult.verified).toStored(),
              verdict: MoveVerdict.mistake,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
