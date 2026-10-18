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
import 'package:lichess_mobile/src/model/analysis/ai_coach_input.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_level.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';
import 'package:lichess_mobile/src/view/analysis/ai_coach_position_screen.dart';
import 'package:lichess_mobile/src/view/analysis/ai_coach_review_screen.dart';
import 'package:lichess_mobile/src/view/settings/ai_coach_settings_screen.dart';
import 'package:material_ui/material_ui.dart';

import '../../model/analysis/ai_coach_scan_support.dart';
import '../../test_provider_scope.dart';

const _pgn = '1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 *';

/// White blunders at half-move 2 and Black at half-move 5.
const _cps = [20, 20, 20, -400, -400, -380, 300];

/// An engine service for the review: quick evaluations come from [_cps], deeper ones answer
/// instantly with a legal line, and [hold] can make the quick scan wait.
class ReviewEngine(super.ref, final IList<AiCoachPly> plies, {final Completer<void>? hold})
    extends AiCoachEngine {
  int quickCalls = 0;

  @override
  Future<ClientEval?> evaluateQuick(
    Position position, {
    Duration timeout = kAiCoachScanTime,
  }) async {
    quickCalls++;
    if (hold != null && quickCalls == 2) await hold!.future;
    final scan = scanFrom(plies, _cps);
    return scan.firstWhere((e) => e?.position.fen == position.fen);
  }

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
        PvData(moves: IList(['${first.key.name}${first.value.squares.first.name}']), cp: 0),
      ]),
    );
  }
}

void main() {
  final input = parseAiCoachInput(_pgn);

  Future<Widget> app(
    WidgetTester tester, {
    AiCoachInput? reviewInput,
    Side? side,
    MockClient? client,
    Completer<void>? hold,
  }) => makeTestProviderScopeApp(
    tester,
    home: AiCoachReviewScreen(input: reviewInput ?? input, side: side),
    overrides: {
      aiCoachEngineProvider: aiCoachEngineProvider.overrideWith(
        (ref) => ReviewEngine(ref, (reviewInput ?? input).plies, hold: hold),
      ),
      if (client != null) aiCoachProvider: aiCoachProvider.overrideWith((ref) => AiCoach(client)),
    },
  );

  Future<void> scan(WidgetTester tester) async {
    await tester.tap(find.text('Start the scan'));
    var pumps = 0;
    while (pumps < 100 && find.textContaining('Key moments').evaluate().isEmpty) {
      await tester.pump(const Duration(milliseconds: 100));
      pumps++;
    }
    await tester.pumpAndSettle();
  }

  /// Scrolls the review list until [finder] is on screen: the boards make the key moments tall, so
  /// what comes after them is below the fold, and the list only builds what is near the screen.
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find
          .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
          .first,
    );
    // Something built a little below the edge is not scrolled to by the above.
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  Finder explainButton(int requests) =>
      find.text('Explain these moments and summarise ($requests requests to OpenAI)');

  MockClient replying({List<String>? tasks}) => MockClient((request) async {
    final messages =
        ((jsonDecode(request.body) as Map<String, dynamic>)['messages'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
    final user = messages.last['content'] as String;
    tasks?.add(user.split('\n').first);
    final text = user.startsWith('Task: review the whole game')
        ? 'Overall: you blundered twice. Practise: checking threats.'
        : 'Explanation of a key moment.';
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

  testWidgets('starts with a description, the side to review and an estimate', (tester) async {
    await tester.pumpWidget(await app(tester));
    expect(find.text('Game review'), findsOneWidget);
    expect(find.textContaining('Nothing is sent to OpenAI'), findsOneWidget);
    expect(find.text('Review for'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Both'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Both')).selected, isTrue);
    expect(find.textContaining('6 half-moves'), findsOneWidget);
    expect(find.text('Start the scan'), findsOneWidget);
  });

  testWidgets('the side that was playing is preselected', (tester) async {
    await tester.pumpWidget(await app(tester, side: Side.black));
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Black')).selected, isTrue);
  });

  testWidgets('the scan finds the key moments locally and sends nothing', (tester) async {
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
    await scan(tester);

    expect(find.textContaining('moves judged'), findsOneWidget);
    expect(find.textContaining('2 blunders'), findsOneWidget);
    expect(find.textContaining('2.Nf3: blunder'), findsOneWidget);
    expect(find.textContaining('3...Bc5: blunder'), findsOneWidget);
    expect(explainButton(3), findsOneWidget);
    expect(requests, 0);
  });

  testWidgets('every key moment has a small board of the position before the move', (tester) async {
    await tester.pumpWidget(await app(tester));
    await scan(tester);

    final boards = tester.widgetList<StaticChessboard>(find.byType(StaticChessboard)).toList();
    expect(boards, hasLength(2));
    // Half-moves 2 and 5, in game order: each shows the position before that move, with the
    // engine's preferred move and the move played drawn as arrows.
    expect(boards[0].fen, input.plies[2].before.fen);
    expect(boards[1].fen, input.plies[5].before.fen);
    expect(boards[1].orientation, Side.black);
    for (final board in boards) {
      expect(board.shapes.whereType<Arrow>(), hasLength(2));
    }
    expect(find.textContaining('green arrow'), findsOneWidget);
  });

  testWidgets('reviewing one side shows only its boards', (tester) async {
    await tester.pumpWidget(await app(tester, side: Side.white));
    await scan(tester);
    expect(find.byType(StaticChessboard), findsOneWidget);
  });

  testWidgets('a game with no mistakes shows no boards', (tester) async {
    final quiet = parseAiCoachInput(_pgn);
    await tester.pumpWidget(
      await makeTestProviderScopeApp(
        tester,
        home: AiCoachReviewScreen(input: quiet),
        overrides: {
          aiCoachEngineProvider: aiCoachEngineProvider.overrideWith(
            (ref) => _QuietEngine(ref, quiet.plies),
          ),
        },
      ),
    );
    await scan(tester);
    expect(find.byType(StaticChessboard), findsNothing);
  });

  testWidgets('reviewing one side lists only its moments and needs fewer requests', (tester) async {
    await tester.pumpWidget(await app(tester, side: Side.white));
    await scan(tester);
    expect(find.textContaining('2.Nf3'), findsOneWidget);
    expect(find.textContaining('3...Bc5'), findsNothing);
    expect(explainButton(2), findsOneWidget);
  });

  testWidgets('explains each moment, then the game, and saves everything', (tester) async {
    final tasks = <String>[];
    await tester.pumpWidget(await app(tester, client: replying(tasks: tasks)));
    await SecureStorage.instance.write(key: aiCoachKeyStorage, value: 'fake-widget-key');
    await scan(tester);

    await reveal(tester, explainButton(3));
    await tester.tap(explainButton(3));
    await tester.pumpAndSettle();

    expect(tasks.where((t) => t.contains('review the whole game')), hasLength(1));
    expect(tasks.where((t) => t.contains('explain the move that was played')), hasLength(2));
    await reveal(tester, find.text('Summary'));
    expect(find.text('Summary'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('Overall: you blundered twice'),
      200,
      scrollable: find
          .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
          .first,
    );
    expect(find.textContaining('Overall: you blundered twice'), findsOneWidget);
    expect(find.textContaining('Explanation of a key moment.'), findsNWidgets(2));
    // Two moment explanations and the summary are in the history.
    final container = ProviderScope.containerOf(tester.element(find.byType(AiCoachReviewScreen)));
    expect(container.read(aiCoachHistoryProvider), hasLength(3));
  });

  testWidgets('without an API key it says so and can be tried again', (tester) async {
    await tester.pumpWidget(await app(tester, client: replying()));
    await scan(tester);
    await reveal(tester, explainButton(3));
    await tester.tap(explainButton(3));
    await tester.pumpAndSettle();
    await reveal(tester, find.textContaining('Add your OpenAI API key'));
    expect(find.textContaining('Add your OpenAI API key'), findsOneWidget);
    expect(explainButton(3), findsOneWidget);
    expect(find.text('Summary'), findsNothing);
  });

  testWidgets('a retry only asks for what is still missing', (tester) async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      // The second request (the second moment) fails once.
      if (calls == 2) return http.Response('no', 500);
      final user =
          (((jsonDecode(request.body) as Map<String, dynamic>)['messages'] as List<dynamic>).last
                  as Map<String, dynamic>)['content']
              as String;
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content': user.startsWith('Task: review')
                    ? 'Overall: ok.'
                    : 'Explanation of a key moment.',
              },
            },
          ],
        }),
        200,
      );
    });
    await tester.pumpWidget(await app(tester, client: client));
    await SecureStorage.instance.write(key: aiCoachKeyStorage, value: 'fake-widget-key');
    await scan(tester);

    await reveal(tester, explainButton(3));
    await tester.tap(explainButton(3));
    await tester.pumpAndSettle();
    await reveal(tester, find.textContaining('OpenAI request failed'));
    expect(find.textContaining('OpenAI request failed'), findsOneWidget);
    expect(calls, 2);

    await reveal(tester, explainButton(3));
    await tester.tap(explainButton(3));
    await tester.pumpAndSettle();
    // The first moment was kept; only the second moment and the summary were asked for.
    expect(calls, 4);
    await reveal(tester, find.text('Summary'));
    expect(find.text('Summary'), findsOneWidget);
  });

  testWidgets('cancelling the scan goes back to the start', (tester) async {
    final hold = Completer<void>();
    await tester.pumpWidget(await app(tester, hold: hold));
    await tester.tap(find.text('Start the scan'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('Analysing position'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    hold.complete();
    await tester.pumpAndSettle();
    expect(find.text('Start the scan'), findsOneWidget);
    expect(find.textContaining('Key moments'), findsNothing);
  });

  testWidgets('a position without moves cannot be reviewed', (tester) async {
    await tester.pumpWidget(await app(tester, reviewInput: parseAiCoachInput(kInitialFEN)));
    await tester.tap(find.text('Start the scan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('no game to review'), findsOneWidget);
  });

  testWidgets('a quiet game reports no mistakes and offers only the summary', (tester) async {
    final quiet = parseAiCoachInput(_pgn);
    await tester.pumpWidget(
      await makeTestProviderScopeApp(
        tester,
        home: AiCoachReviewScreen(input: quiet),
        overrides: {
          aiCoachEngineProvider: aiCoachEngineProvider.overrideWith(
            (ref) => _QuietEngine(ref, quiet.plies),
          ),
        },
      ),
    );
    await scan(tester);
    expect(find.text('No clear mistakes were found in this game.'), findsOneWidget);
    expect(find.text('Summarise the game (1 request to OpenAI)'), findsOneWidget);
  });

  group('entry points', () {
    testWidgets('the paste screen offers a whole-game review', (tester) async {
      await tester.pumpWidget(
        await makeTestProviderScopeApp(tester, home: const AiCoachPositionScreen()),
      );
      await tester.enterText(find.byType(TextField), _pgn);
      await tester.tap(find.text('Review the whole game'));
      await tester.pumpAndSettle();
      expect(find.text('Game review'), findsOneWidget);
      expect(find.text('Start the scan'), findsOneWidget);
    });

    testWidgets('the paste screen refuses a bare position', (tester) async {
      await tester.pumpWidget(
        await makeTestProviderScopeApp(tester, home: const AiCoachPositionScreen()),
      );
      await tester.enterText(find.byType(TextField), kInitialFEN);
      await tester.tap(find.text('Review the whole game'));
      await tester.pumpAndSettle();
      expect(find.textContaining('no game to review'), findsOneWidget);
      expect(find.text('Game review'), findsNothing);
    });

    testWidgets('the helper used by the result dialogs opens the review', (tester) async {
      await tester.pumpWidget(
        await makeTestProviderScopeApp(
          tester,
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => openAiCoachReviewForPgn(context, _pgn, side: Side.white),
                child: const Text('Open review'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open review'));
      await tester.pumpAndSettle();
      expect(find.text('Game review'), findsOneWidget);
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'White')).selected, isTrue);
    });

    testWidgets('the helper shows a message for an unreadable game', (tester) async {
      await tester.pumpWidget(
        await makeTestProviderScopeApp(
          tester,
          home: Builder(
            builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () => openAiCoachReviewForPgn(context, '1. e4 e5 2. Ke4 *'),
                child: const Text('Open review'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open review'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Illegal or unreadable move'), findsOneWidget);
      expect(find.text('Game review'), findsNothing);
    });
  });
}

/// An engine that sees nothing wrong with any move.
class _QuietEngine(super.ref, super.plies) extends ReviewEngine {
  @override
  Future<ClientEval?> evaluateQuick(
    Position position, {
    Duration timeout = kAiCoachScanTime,
  }) async {
    final scan = scanFrom(plies, List.filled(7, 10));
    return scan.firstWhere((e) => e?.position.fen == position.fen);
  }
}
