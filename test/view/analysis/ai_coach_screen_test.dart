import 'dart:async';
import 'dart:convert';

import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lichess_mobile/src/db/secure_storage.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_history.dart';
import 'package:lichess_mobile/src/model/analysis/analysis_controller.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/view/analysis/ai_coach_screen.dart';
import 'package:lichess_mobile/src/view/analysis/analysis_screen.dart';
import 'package:lichess_mobile/src/view/settings/ai_coach_settings_screen.dart';
import 'package:material_ui/material_ui.dart';

import '../../test_provider_scope.dart';

/// Scrolls the coach screen's list until [finder] is built. The list is lazy, so things far down
/// are not in the tree until then; the text fields have scrollables of their own, hence the
/// explicit one.
Future<void> scrollTo(WidgetTester tester, Finder finder) => tester.scrollUntilVisible(
  finder,
  300,
  scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first,
);

void main() {
  final savedHistory = jsonEncode([
    {
      'savedAt': '2026-10-17T00:00:00Z',
      'model': aiCoachDefaultModel,
      'evidence': 'FEN: saved position',
      'explanation': 'Protect your king before attacking.',
    },
  ]);

  testWidgets('shows progress while Stockfish analyses and offers Explain only afterwards', (
    tester,
  ) async {
    final completer = Completer<AiCoachRequest>();
    final app = await makeTestProviderScopeApp(
      tester,
      home: AiCoachScreen(prepare: (_) => completer.future),
    );
    await tester.pumpWidget(app);
    await tester.pump();
    expect(find.text('Analysing the position with Stockfish…'), findsOneWidget);
    expect(find.text('Explain'), findsNothing);
    completer.complete((evidence: 'FEN: later', allowedMoves: ISet<String>()));
    await tester.pumpAndSettle();
    expect(find.text('Analysing the position with Stockfish…'), findsNothing);
    expect(find.text('Explain'), findsOneWidget);
  });

  testWidgets('shows the error and a retry when the analysis fails', (tester) async {
    var calls = 0;
    final app = await makeTestProviderScopeApp(
      tester,
      home: AiCoachScreen(
        prepare: (_) async {
          calls++;
          if (calls == 1) throw const AiCoachException('Stockfish ran out of time.');
          return (evidence: 'FEN: second try', allowedMoves: ISet<String>());
        },
      ),
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    expect(find.text('Stockfish ran out of time.'), findsOneWidget);
    expect(find.text('Explain'), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Explain'), findsOneWidget);
    expect(find.text('Stockfish ran out of time.'), findsNothing);
  });

  testWidgets('reuses persistent explanation without needing an API key', (tester) async {
    final app = await makeTestProviderScopeApp(
      tester,
      home: AiCoachScreen(
        prepare: (_) async => (evidence: 'FEN: saved position', allowedMoves: ISet<String>()),
      ),
      defaultPreferences: {aiCoachHistoryStorageKey: savedHistory},
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Explain'));
    await tester.pumpAndSettle();
    expect(find.text('Protect your king before attacking.'), findsOneWidget);
    expect(find.textContaining('Add your OpenAI API key'), findsNothing);
  });

  testWidgets('history opens saved notes and asks before clearing', (tester) async {
    final app = await makeTestProviderScopeApp(
      tester,
      home: AiCoachScreen(
        prepare: (_) async => (evidence: 'FEN: saved position', allowedMoves: ISet<String>()),
      ),
      defaultPreferences: {aiCoachHistoryStorageKey: savedHistory},
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Explanation history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Protect your king before attacking.'));
    await tester.pumpAndSettle();
    expect(find.text('Saved explanation'), findsOneWidget);
    expect(find.text('Protect your king before attacking.'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Protect your king before attacking.'), findsOneWidget);
    await tester.tap(find.text('Clear history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('No saved explanations yet.'), findsOneWidget);
  });

  testWidgets('menu offers to explain the move when a move is displayed', (tester) async {
    final app = await makeTestProviderScopeApp(
      tester,
      home: const AnalysisScreen(
        options: AnalysisOptions.pgn(
          id: StringId('ai-coach-move-test'),
          pgn: '1. e4 e5',
          isComputerAnalysisAllowed: true,
          orientation: Side.white,
          variant: Variant.standard,
          initialMoveCursor: 2,
        ),
      ),
    );
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('Explain this move (AI)'), findsOneWidget);
    expect(find.text('Explain position (AI)'), findsNothing);
  });

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
      home: AiCoachScreen(
        prepare: (_) async => (evidence: 'FEN: example position', allowedMoves: ISet<String>()),
      ),
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
      home: AiCoachScreen(
        prepare: (_) async => (evidence: 'FEN: example position', allowedMoves: ISet<String>()),
      ),
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

  group('follow-up questions', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(AiCoachScreen)));

    Future<Widget> app(WidgetTester tester, {String? history, MockClient? client}) =>
        makeTestProviderScopeApp(
          tester,
          home: AiCoachScreen(
            prepare: (_) async => (evidence: 'FEN: saved position', allowedMoves: ISet<String>()),
          ),
          defaultPreferences: {aiCoachHistoryStorageKey: history ?? savedHistory},
          overrides: client == null
              ? null
              : {aiCoachProvider: aiCoachProvider.overrideWith((ref) => AiCoach(client))},
        );

    MockClient replying(String text, {List<Map<String, dynamic>>? bodies}) => MockClient((r) async {
      bodies?.add(jsonDecode(r.body) as Map<String, dynamic>);
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': text},
            },
          ],
        }),
        200,
      );
    });

    Future<void> openSaved(WidgetTester tester) async {
      await tester.pumpAndSettle();
      await tester.tap(find.text('Explain'));
      await tester.pumpAndSettle();
    }

    testWidgets('asks a typed question, shows the answer and saves it', (tester) async {
      final bodies = <Map<String, dynamic>>[];
      await tester.pumpWidget(await app(tester, client: replying('Castle early.', bodies: bodies)));
      await SecureStorage.instance.write(key: aiCoachKeyStorage, value: 'fake-widget-key');
      await openSaved(tester);

      await scrollTo(tester, find.widgetWithText(TextField, 'Ask a follow-up question'));

      await tester.enterText(find.widgetWithText(TextField, 'Ask a follow-up question'), 'Why?');
      await scrollTo(tester, find.text('Ask'));
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();

      expect(find.text('You: Why?'), findsOneWidget);
      expect(find.text('Castle early.'), findsOneWidget);
      // The input is cleared for the next question.
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Ask a follow-up question'))
            .controller!
            .text,
        isEmpty,
      );
      // The model was given the saved answer as context.
      final messages = (bodies.single['messages'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(messages.map((m) => m['content']), contains('Protect your king before attacking.'));
      expect(messages.last['content'], 'Why?');
      // And the conversation was saved with the explanation.
      final saved = containerOf(tester).read(aiCoachHistoryProvider).single;
      expect(saved.followUps.single.question, 'Why?');
      expect(saved.followUps.single.answer, 'Castle early.');
    });

    testWidgets('a quick button asks its own text', (tester) async {
      final bodies = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        await app(tester, client: replying('Simply: be safe.', bodies: bodies)),
      );
      await SecureStorage.instance.write(key: aiCoachKeyStorage, value: 'fake-widget-key');
      await openSaved(tester);

      await scrollTo(tester, find.text('Explain simpler'));
      await tester.tap(find.text('Explain simpler'));
      await tester.pumpAndSettle();

      expect(find.text('You: Explain simpler'), findsOneWidget);
      expect(find.text('Simply: be safe.'), findsOneWidget);
      final messages = (bodies.single['messages'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(messages.last['content'], 'Explain simpler');
    });

    testWidgets('earlier follow-ups are loaded from history and sent as context', (tester) async {
      final bodies = <Map<String, dynamic>>[];
      final withTurn = jsonEncode([
        {
          'savedAt': '2026-10-17T00:00:00Z',
          'model': aiCoachDefaultModel,
          'evidence': 'FEN: saved position',
          'explanation': 'Protect your king before attacking.',
          'followUps': [
            {'question': 'What is castling?', 'answer': 'A king safety move.'},
          ],
        },
      ]);
      await tester.pumpWidget(
        await app(
          tester,
          history: withTurn,
          client: replying('Next.', bodies: bodies),
        ),
      );
      await SecureStorage.instance.write(key: aiCoachKeyStorage, value: 'fake-widget-key');
      await openSaved(tester);

      expect(find.text('You: What is castling?'), findsOneWidget);
      expect(find.text('A king safety move.'), findsOneWidget);

      await scrollTo(tester, find.widgetWithText(TextField, 'Ask a follow-up question'));

      await tester.enterText(
        find.widgetWithText(TextField, 'Ask a follow-up question'),
        'And then?',
      );
      await scrollTo(tester, find.text('Ask'));
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();

      final messages = (bodies.single['messages'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(
        messages.map((m) => m['content']),
        containsAllInOrder(['What is castling?', 'A king safety move.', 'And then?']),
      );
      expect(find.text('You: And then?'), findsOneWidget);
    });

    testWidgets('a failure shows a message and keeps the question', (tester) async {
      await tester.pumpWidget(
        await app(tester, client: MockClient((_) async => http.Response('nope', 500))),
      );
      await SecureStorage.instance.write(key: aiCoachKeyStorage, value: 'fake-widget-key');
      await openSaved(tester);

      await scrollTo(tester, find.widgetWithText(TextField, 'Ask a follow-up question'));

      await tester.enterText(find.widgetWithText(TextField, 'Ask a follow-up question'), 'Why?');
      await scrollTo(tester, find.text('Ask'));
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();

      expect(find.textContaining('OpenAI request failed'), findsOneWidget);
      expect(find.text('Why?'), findsOneWidget);
      expect(find.textContaining('You:'), findsNothing);
      expect(containerOf(tester).read(aiCoachHistoryProvider).single.followUps, isEmpty);
    });

    testWidgets('an empty question asks nothing', (tester) async {
      var requests = 0;
      await tester.pumpWidget(
        await app(
          tester,
          client: MockClient((_) async {
            requests++;
            return http.Response('{}', 200);
          }),
        ),
      );
      await SecureStorage.instance.write(key: aiCoachKeyStorage, value: 'fake-widget-key');
      await openSaved(tester);
      await scrollTo(tester, find.text('Ask'));
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      expect(find.text('Type a question first.'), findsOneWidget);
      expect(requests, 0);
    });

    testWidgets('stops offering questions at the limit', (tester) async {
      final full = jsonEncode([
        {
          'savedAt': '2026-10-17T00:00:00Z',
          'model': aiCoachDefaultModel,
          'evidence': 'FEN: saved position',
          'explanation': 'Protect your king before attacking.',
          'followUps': [
            for (var i = 0; i < 6; i++) {'question': 'q$i', 'answer': 'a$i'},
          ],
        },
      ]);
      await tester.pumpWidget(await app(tester, history: full));
      await openSaved(tester);
      await scrollTo(tester, find.textContaining('most follow-up questions'));
      expect(find.textContaining('most follow-up questions'), findsOneWidget);
      expect(find.text('Ask'), findsNothing);
    });

    testWidgets('the history detail shows the saved conversation', (tester) async {
      final withTurn = jsonEncode([
        {
          'savedAt': '2026-10-17T00:00:00Z',
          'model': aiCoachDefaultModel,
          'evidence': 'FEN: saved position',
          'explanation': 'Protect your king before attacking.',
          'followUps': [
            {'question': 'What is castling?', 'answer': 'A king safety move.'},
          ],
        },
      ]);
      await tester.pumpWidget(await app(tester, history: withTurn));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Explanation history'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Protect your king before attacking.'));
      await tester.pumpAndSettle();
      expect(find.text('You: What is castling?'), findsOneWidget);
      expect(find.text('A king safety move.'), findsOneWidget);
    });
  });
}
