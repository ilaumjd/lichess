import 'dart:async';
import 'dart:convert';

import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lichess_mobile/src/db/secure_storage.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_engine.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_history.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_level.dart';
import 'package:lichess_mobile/src/model/analysis/analysis_controller.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/view/analysis/ai_coach_history_screen.dart';
import 'package:lichess_mobile/src/view/analysis/ai_coach_screen.dart';
import 'package:lichess_mobile/src/view/analysis/analysis_screen.dart';
import 'package:lichess_mobile/src/view/settings/ai_coach_settings_screen.dart';
import 'package:material_ui/material_ui.dart';

import '../../binding.dart';
import '../../test_provider_scope.dart';

/// An engine service that answers instantly, for the screen to compare moves with.
class FakeCoachEngine(super.ref) extends AiCoachEngine {
  @override
  Future<ClientEval?> evaluate(
    Position position, {
    Duration? timeout,
    AiCoachLevel level = AiCoachLevel.beginner,
  }) async {
    final first = position.legalMoves.entries.firstWhere((e) => e.value.isNotEmpty);
    return CloudEval(
      position: position,
      depth: 16,
      nodes: 1,
      pvs: IList([
        PvData(moves: IList(['${first.key.name}${first.value.squares.first.name}']), cp: -50),
      ]),
    );
  }
}

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
      home: AiCoachScreen(prepare: (_, _) => completer.future),
    );
    await tester.pumpWidget(app);
    await tester.pump();
    expect(find.text('Analysing the position with Stockfish…'), findsOneWidget);
    expect(find.text('Explain'), findsNothing);
    completer.complete(AiCoachRequest(evidence: 'FEN: later', allowedMoves: ISet<String>()));
    await tester.pumpAndSettle();
    expect(find.text('Analysing the position with Stockfish…'), findsNothing);
    expect(find.text('Explain'), findsOneWidget);
  });

  testWidgets('shows the error and a retry when the analysis fails', (tester) async {
    var calls = 0;
    final app = await makeTestProviderScopeApp(
      tester,
      home: AiCoachScreen(
        prepare: (_, _) async {
          calls++;
          if (calls == 1) throw const AiCoachException('Stockfish ran out of time.');
          return AiCoachRequest(evidence: 'FEN: second try', allowedMoves: ISet<String>());
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
        prepare: (_, _) async =>
            AiCoachRequest(evidence: 'FEN: saved position', allowedMoves: ISet<String>()),
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
        prepare: (_, _) async =>
            AiCoachRequest(evidence: 'FEN: saved position', allowedMoves: ISet<String>()),
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
        prepare: (_, _) async =>
            AiCoachRequest(evidence: 'FEN: example position', allowedMoves: ISet<String>()),
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
        prepare: (_, _) async =>
            AiCoachRequest(evidence: 'FEN: example position', allowedMoves: ISet<String>()),
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
    await scrollTo(tester, find.text('Save'));
    await tester.ensureVisible(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(await SecureStorage.instance.read(key: aiCoachKeyStorage), 'fake-widget-test-key');
    expect(await SecureStorage.instance.read(key: aiCoachModelStorage), aiCoachDefaultModel);
    await scrollTo(tester, find.text('Remove API key'));
    await tester.ensureVisible(find.text('Remove API key'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove API key'));
    await tester.pumpAndSettle();
    expect(await SecureStorage.instance.read(key: aiCoachKeyStorage), isNull);
    await scrollTo(tester, find.text('API key removed.'));
    expect(find.text('API key removed.'), findsOneWidget);
  });

  group('follow-up questions', () {
    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(AiCoachScreen)));

    Future<Widget> app(
      WidgetTester tester, {
      String? history,
      MockClient? client,
      AiCoachDecision? decision,
    }) => makeTestProviderScopeApp(
      tester,
      home: AiCoachScreen(
        prepare: (_, _) async => AiCoachRequest(
          evidence: 'FEN: saved position',
          allowedMoves: ISet<String>(),
          decision: decision,
        ),
      ),
      defaultPreferences: {aiCoachHistoryStorageKey: history ?? savedHistory},
      overrides: {
        if (client != null) aiCoachProvider: aiCoachProvider.overrideWith((ref) => AiCoach(client)),
        if (decision != null)
          aiCoachEngineProvider: aiCoachEngineProvider.overrideWith((ref) => FakeCoachEngine(ref)),
      },
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
    group('why not this move', () {
      AiCoachDecision decision() => (
        position: Chess.initial,
        eval: CloudEval(
          position: Chess.initial,
          depth: 16,
          nodes: 1,
          pvs: IList([
            PvData(moves: IList(const ['e2e4', 'e7e5']), cp: 30),
          ]),
        ),
      );

      const moveField = 'Compare a move (for example Nf3 or e2e4)';

      Future<void> compare(WidgetTester tester, String move) async {
        await scrollTo(tester, find.widgetWithText(TextField, moveField));
        await tester.enterText(find.widgetWithText(TextField, moveField), move);
        await scrollTo(tester, find.text('Why not this move?'));
        await tester.tap(find.text('Why not this move?'));
        await tester.pumpAndSettle();
      }

      testWidgets('evaluates the named move and asks the coach to compare it', (tester) async {
        final bodies = <Map<String, dynamic>>[];
        await tester.pumpWidget(
          await app(
            tester,
            decision: decision(),
            client: replying('Nf3 is fine but e4 grabs more space.', bodies: bodies),
          ),
        );
        await SecureStorage.instance.write(key: aiCoachKeyStorage, value: 'fake-widget-key');
        await openSaved(tester);

        await compare(tester, 'nf3');

        expect(find.text('You: Why not Nf3?'), findsOneWidget);
        // The answer is drawn: the position before with both arrows, and the position after Nf3.
        await scrollTo(tester, find.text('After the move'));
        final drawn = tester.widgetList<StaticChessboard>(find.byType(StaticChessboard)).toList();
        expect(drawn, hasLength(2));
        expect(drawn[0].fen, Chess.initial.fen);
        expect(drawn[1].fen, Chess.initial.play(Move.parse('g1f3')!).fen);
        expect(drawn[1].lastMove, Move.parse('g1f3'));
        expect(find.textContaining('Red arrow: the move you asked about'), findsOneWidget);
        // Nf3 came from the comparison evidence, so the answer passes the move check.
        expect(find.textContaining('Nf3 is fine but e4 grabs more space.'), findsOneWidget);
        expect(find.textContaining('Moves checked against'), findsOneWidget);
        final last = (bodies.single['messages'] as List<dynamic>).last as Map<String, dynamic>;
        expect(last['content'], startsWith('Why not Nf3?'));
        expect(last['content'], contains('Extra engine evidence for this question:'));
        expect(last['content'], contains('why not play Nf3 instead?'));
        expect(last['content'], contains("The engine's preferred move: e4"));
        // Saved with the explanation under its clean question, and the move box is cleared.
        final saved = containerOf(tester).read(aiCoachHistoryProvider).single;
        expect(saved.followUps.single.question, 'Why not Nf3?');
        // The list grew, so go back up to the move box (it is built lazily).
        await tester.drag(find.byType(ListView).first, const Offset(0, 3000));
        await tester.pumpAndSettle();
        await scrollTo(tester, find.widgetWithText(TextField, moveField));
        final field = tester.widget<TextField>(find.widgetWithText(TextField, moveField));
        expect(field.controller!.text, isEmpty);
      });

      testWidgets('a saved "Why not" comes back with its board', (tester) async {
        final withTurn = jsonEncode([
          {
            'savedAt': '2026-10-17T00:00:00Z',
            'model': aiCoachDefaultModel,
            'evidence': 'FEN: saved position',
            'explanation': 'Protect your king before attacking.',
            'followUps': [
              {'question': 'Why not Nf3?', 'answer': 'Slower than e4.'},
              {'question': 'Explain simpler', 'answer': 'Be safe.'},
            ],
          },
        ]);
        await tester.pumpWidget(await app(tester, history: withTurn, decision: decision()));
        await openSaved(tester);

        expect(find.text('You: Why not Nf3?'), findsOneWidget);
        await scrollTo(tester, find.text('After the move'));
        // One drawn board pair: for the "Why not", not for "Explain simpler".
        expect(find.byType(StaticChessboard), findsNWidgets(2));
      });

      testWidgets('a question that names an illegal move draws nothing', (tester) async {
        final withTurn = jsonEncode([
          {
            'savedAt': '2026-10-17T00:00:00Z',
            'model': aiCoachDefaultModel,
            'evidence': 'FEN: saved position',
            'explanation': 'Protect your king before attacking.',
            'followUps': [
              {'question': 'Why not Ke4?', 'answer': 'Not possible.'},
            ],
          },
        ]);
        await tester.pumpWidget(await app(tester, history: withTurn, decision: decision()));
        await openSaved(tester);
        expect(find.text('You: Why not Ke4?'), findsOneWidget);
        expect(find.byType(StaticChessboard), findsNothing);
      });

      testWidgets('an illegal move shows why and sends nothing', (tester) async {
        var requests = 0;
        await tester.pumpWidget(
          await app(
            tester,
            decision: decision(),
            client: MockClient((_) async {
              requests++;
              return http.Response('{}', 200);
            }),
          ),
        );
        await SecureStorage.instance.write(key: aiCoachKeyStorage, value: 'fake-widget-key');
        await openSaved(tester);

        await compare(tester, 'Ke4');

        expect(find.textContaining('not a legal move'), findsOneWidget);
        expect(find.textContaining('You:'), findsNothing);
        expect(requests, 0);
        expect(containerOf(tester).read(aiCoachHistoryProvider).single.followUps, isEmpty);
      });

      testWidgets('is not offered when the explanation has no decision position', (tester) async {
        await tester.pumpWidget(await app(tester));
        await openSaved(tester);
        await scrollTo(tester, find.text('Ask'));
        expect(find.text('Why not this move?'), findsNothing);
      });
    });
  });

  group('opening the coach from a finished game', () {
    Future<Widget> hostApp(WidgetTester tester, String pgn) => makeTestProviderScopeApp(
      tester,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => openAiCoachForPgn(context, pgn),
              child: const Text('Open coach'),
            ),
          ),
        ),
      ),
      overrides: {aiCoachEngineProvider: aiCoachEngineProvider.overrideWith(FakeCoachEngine.new)},
    );

    testWidgets('a readable game opens the coach on its last move', (tester) async {
      await tester.pumpWidget(await hostApp(tester, '1. f3 e5 2. g4 Qh4# 0-1'));
      await tester.tap(find.text('Open coach'));
      var pumps = 0;
      while (pumps < 300 && find.text('Position and engine evidence').evaluate().isEmpty) {
        await tester.pump(const Duration(milliseconds: 100));
        pumps++;
      }
      expect(find.text('Explain position'), findsOneWidget);
      await tester.tap(find.text('Position and engine evidence'));
      await tester.pumpAndSettle();
      expect(find.textContaining('This move gives checkmate'), findsOneWidget);
      expect(find.textContaining('Move played: Qh4#'), findsOneWidget);
    });

    testWidgets("losing as White: Black's mating move is the opponent's, seen from White", (
      tester,
    ) async {
      await tester.pumpWidget(
        await makeTestProviderScopeApp(
          tester,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () =>
                      openAiCoachForPgn(context, '1. f3 e5 2. g4 Qh4# 0-1', side: Side.white),
                  child: const Text('Open coach'),
                ),
              ),
            ),
          ),
          overrides: {
            aiCoachEngineProvider: aiCoachEngineProvider.overrideWith(FakeCoachEngine.new),
          },
        ),
      );
      await tester.tap(find.text('Open coach'));
      var pumps = 0;
      while (pumps < 300 && find.byType(StaticChessboard).evaluate().isEmpty) {
        await tester.pump(const Duration(milliseconds: 100));
        pumps++;
      }
      await tester.pumpAndSettle();

      // Both boards are turned to the side the user plays, although Black made the move.
      final boards = tester.widgetList<StaticChessboard>(find.byType(StaticChessboard)).toList();
      expect(boards, hasLength(2));
      for (final board in boards) {
        expect(board.orientation, Side.white);
      }
      await tester.scrollUntilVisible(
        find.text('Position and engine evidence'),
        300,
        scrollable: find
            .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
            .first,
      );
      await tester.tap(find.text('Position and engine evidence'));
      await tester.pumpAndSettle();
      expect(find.textContaining('The user is playing White.'), findsOneWidget);
      expect(find.textContaining("Side that moved: Black (the user's opponent)"), findsOneWidget);
    });

    testWidgets('without a known side the boards follow the side that moved', (tester) async {
      await tester.pumpWidget(await hostApp(tester, '1. f3 e5 2. g4 Qh4# 0-1'));
      await tester.tap(find.text('Open coach'));
      var pumps = 0;
      while (pumps < 300 && find.byType(StaticChessboard).evaluate().isEmpty) {
        await tester.pump(const Duration(milliseconds: 100));
        pumps++;
      }
      await tester.pumpAndSettle();
      for (final board in tester.widgetList<StaticChessboard>(find.byType(StaticChessboard))) {
        expect(board.orientation, Side.black);
      }
    });

    testWidgets('an unreadable game shows a message and does not open the coach', (tester) async {
      await tester.pumpWidget(await hostApp(tester, '1. e4 e5 2. Ke4 *'));
      await tester.tap(find.text('Open coach'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Illegal or unreadable move'), findsOneWidget);
      expect(find.text('Explain position'), findsNothing);
    });

    testWidgets('a variant game is refused', (tester) async {
      await tester.pumpWidget(await hostApp(tester, '[Variant "Atomic"]\n\n1. e4 e5 *'));
      await tester.tap(find.text('Open coach'));
      await tester.pumpAndSettle();
      expect(find.textContaining('only explains standard chess'), findsOneWidget);
    });
  });

  group('coach level', () {
    testWidgets('settings offer the three levels, describe the chosen one and save it', (
      tester,
    ) async {
      await tester.pumpWidget(
        await makeTestProviderScopeApp(tester, home: const AiCoachSettingsScreen()),
      );
      await tester.pumpAndSettle();

      for (final level in AiCoachLevel.values) {
        expect(find.widgetWithText(ChoiceChip, level.label), findsOneWidget);
      }
      // Beginner is the default.
      expect(find.text(AiCoachLevel.beginner.description), findsOneWidget);
      expect(
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Beginner')).selected,
        isTrue,
      );

      await tester.tap(find.widgetWithText(ChoiceChip, 'Advanced'));
      await tester.pumpAndSettle();

      expect(find.text(AiCoachLevel.advanced.description), findsOneWidget);
      expect(find.text(AiCoachLevel.beginner.description), findsNothing);
      expect(
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Advanced')).selected,
        isTrue,
      );
      expect(testBinding.sharedPreferences.getString(aiCoachLevelStorageKey), 'advanced');
    });

    testWidgets('the coach is prepared for the saved level and says which', (tester) async {
      final levels = <AiCoachLevel>[];
      await tester.pumpWidget(
        await makeTestProviderScopeApp(
          tester,
          home: AiCoachScreen(
            prepare: (_, level) async {
              levels.add(level);
              return AiCoachRequest(evidence: 'FEN: x', allowedMoves: ISet<String>());
            },
          ),
          defaultPreferences: {aiCoachLevelStorageKey: 'advanced'},
        ),
      );
      await tester.pumpAndSettle();
      expect(levels, [AiCoachLevel.advanced]);
      expect(find.text('Coach level: Advanced'), findsOneWidget);
    });

    testWidgets('changing the level in settings analyses again for the new level', (tester) async {
      final levels = <AiCoachLevel>[];
      await tester.pumpWidget(
        await makeTestProviderScopeApp(
          tester,
          home: AiCoachScreen(
            prepare: (_, level) async {
              levels.add(level);
              return AiCoachRequest(evidence: 'FEN: ${level.name}', allowedMoves: ISet<String>());
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(levels, [AiCoachLevel.beginner]);
      expect(find.text('Coach level: Beginner'), findsOneWidget);

      await tester.tap(find.text('AI coach settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Club player'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(levels, [AiCoachLevel.beginner, AiCoachLevel.club]);
      expect(find.text('Coach level: Club player'), findsOneWidget);
    });

    testWidgets('leaving the level alone does not analyse again', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        await makeTestProviderScopeApp(
          tester,
          home: AiCoachScreen(
            prepare: (_, _) async {
              calls++;
              return AiCoachRequest(evidence: 'FEN: x', allowedMoves: ISet<String>());
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('AI coach settings'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(calls, 1);
    });
  });

  group('boards beside the explanation', () {
    const start = Chess.initial;
    final e4 = Move.parse('e2e4')!;

    Future<Widget> screen(WidgetTester tester, AiCoachBoards? boards) => makeTestProviderScopeApp(
      tester,
      home: AiCoachScreen(
        prepare: (_, _) async =>
            AiCoachRequest(evidence: 'FEN: x', allowedMoves: ISet<String>(), boards: boards),
      ),
    );

    testWidgets('a move explanation shows the position before and after the move', (tester) async {
      await tester.pumpWidget(
        await screen(tester, (
          before: start,
          position: start.play(e4),
          played: e4,
          best: Move.parse('d2d4'),
          orientation: Side.white,
        )),
      );
      await tester.pumpAndSettle();
      expect(find.byType(StaticChessboard), findsNWidgets(2));
      expect(find.text('Before the move'), findsOneWidget);
      expect(find.text('After the move'), findsOneWidget);
    });

    testWidgets('a position explanation shows one board', (tester) async {
      await tester.pumpWidget(
        await screen(tester, (
          before: null,
          position: start,
          played: null,
          best: Move.parse('g1f3'),
          orientation: Side.white,
        )),
      );
      await tester.pumpAndSettle();
      expect(find.byType(StaticChessboard), findsOneWidget);
    });

    testWidgets('no board is drawn when there is nothing to show, and nothing else changes', (
      tester,
    ) async {
      await tester.pumpWidget(await screen(tester, null));
      await tester.pumpAndSettle();
      expect(find.byType(StaticChessboard), findsNothing);
      expect(find.text('Explain'), findsOneWidget);
    });

    testWidgets('no board while the position is still being analysed', (tester) async {
      final never = Completer<AiCoachRequest>();
      await tester.pumpWidget(
        await makeTestProviderScopeApp(
          tester,
          home: AiCoachScreen(prepare: (_, _) => never.future),
        ),
      );
      await tester.pump();
      expect(find.byType(StaticChessboard), findsNothing);
    });

    testWidgets('a saved "Why not" is drawn in the history too', (tester) async {
      final history = jsonEncode([
        {
          'savedAt': '2026-10-17T00:00:00Z',
          'model': aiCoachDefaultModel,
          'evidence':
              'Task: explain the move that was played, not only the position.\n'
              'Position before the move (FEN): ${start.fen}\n'
              'Move played: e4\n'
              "The engine's first choice was d4.\n",
          'explanation': 'A saved move explanation.',
          'followUps': [
            {'question': 'Why not Nf3?', 'answer': 'Slower than the engine move.'},
          ],
        },
      ]);
      await tester.pumpWidget(
        await makeTestProviderScopeApp(
          tester,
          home: const AiCoachHistoryScreen(),
          defaultPreferences: {aiCoachHistoryStorageKey: history},
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('A saved move explanation.'));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('Slower than the engine move.'));
      // The move explanation has two boards and the "Why not" another two.
      expect(find.byType(StaticChessboard), findsNWidgets(4));
    });

    testWidgets('a saved explanation shows its board in the history', (tester) async {
      final history = jsonEncode([
        {
          'savedAt': '2026-10-17T00:00:00Z',
          'model': aiCoachDefaultModel,
          'evidence':
              'Task: explain the move that was played, not only the position.\n'
              'Coach level: Beginner\n'
              'Position before the move (FEN): ${start.fen}\n'
              'Side that moved: White\n'
              'Move played: e4\n'
              "The engine's first choice was d4.\n",
          'explanation': 'A saved move explanation.',
        },
        {
          'savedAt': '2026-10-16T00:00:00Z',
          'model': aiCoachDefaultModel,
          'evidence': 'FEN: not something a board can be built from',
          'explanation': 'An old note.',
        },
      ]);
      await tester.pumpWidget(
        await makeTestProviderScopeApp(
          tester,
          home: const AiCoachHistoryScreen(),
          defaultPreferences: {aiCoachHistoryStorageKey: history},
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('A saved move explanation.'));
      await tester.pumpAndSettle();
      expect(find.byType(StaticChessboard), findsNWidgets(2));
      expect(find.text('A saved move explanation.'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('An old note.'));
      await tester.pumpAndSettle();
      expect(find.byType(StaticChessboard), findsNothing);
      expect(find.text('An old note.'), findsOneWidget);
    });
  });
}
