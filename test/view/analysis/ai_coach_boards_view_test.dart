import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/view/analysis/ai_coach_boards_view.dart';
import 'package:material_ui/material_ui.dart';

import '../../test_helpers.dart';
import '../../test_provider_scope.dart';

void main() {
  const start = Chess.initial;
  final e4 = Move.parse('e2e4')!;
  final afterE4 = start.play(e4);

  Future<void> show(
    WidgetTester tester,
    AiCoachBoards boards, {
    Size surfaceSize = kTestSurfaceSize,
  }) async {
    await tester.pumpWidget(
      await makeTestProviderScopeApp(
        tester,
        surfaceSize: surfaceSize,
        home: Scaffold(
          body: Center(child: AiCoachBoardsView(boards: boards)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Iterable<Arrow> arrows(StaticChessboard board) => board.shapes.whereType<Arrow>();

  testWidgets('a move shows two boards: before with arrows, after with the move highlighted', (
    tester,
  ) async {
    await show(tester, (
      before: start,
      position: afterE4,
      played: e4,
      best: Move.parse('d2d4'),
      orientation: Side.white,
    ));

    final boards = tester.widgetList<StaticChessboard>(find.byType(StaticChessboard)).toList();
    expect(boards, hasLength(2));
    expect(find.text('Before the move'), findsOneWidget);
    expect(find.text('After the move'), findsOneWidget);

    final before = boards[0];
    final after = boards[1];
    expect(before.fen, start.fen);
    expect(after.fen, afterE4.fen);
    // Two arrows before the move: the best move and, since it differs, the move played.
    expect(
      arrows(before).map((a) => (a.orig, a.dest)),
      containsAll([(Square.d2, Square.d4), (Square.e2, Square.e4)]),
    );
    expect(arrows(before), hasLength(2));
    // The board after the move highlights it and draws no arrows.
    expect(after.lastMove, e4);
    expect(arrows(after), isEmpty);
    expect(find.textContaining('Green arrow'), findsOneWidget);
    expect(find.textContaining('Red arrow: the move played'), findsOneWidget);
  });

  testWidgets('one arrow and no red legend when the move played was the best one', (tester) async {
    await show(tester, (
      before: start,
      position: afterE4,
      played: e4,
      best: e4,
      orientation: Side.white,
    ));
    final before = tester.widgetList<StaticChessboard>(find.byType(StaticChessboard)).first;
    expect(arrows(before), hasLength(1));
    expect(find.textContaining('Red arrow'), findsNothing);
    expect(find.textContaining('Green arrow'), findsOneWidget);
  });

  testWidgets('a position shows one board with the engine move', (tester) async {
    await show(tester, (
      before: null,
      position: start,
      played: null,
      best: Move.parse('g1f3'),
      orientation: Side.white,
    ));
    final boards = tester.widgetList<StaticChessboard>(find.byType(StaticChessboard)).toList();
    expect(boards, hasLength(1));
    expect(find.text('The position'), findsOneWidget);
    expect(arrows(boards.single).single.orig, Square.g1);
    expect(find.textContaining('Red arrow'), findsNothing);
  });

  testWidgets('the boards are turned to the side that moved', (tester) async {
    await show(tester, (
      before: afterE4,
      position: afterE4.play(Move.parse('e7e5')!),
      played: Move.parse('e7e5'),
      best: Move.parse('c7c5'),
      orientation: Side.black,
    ));
    for (final board in tester.widgetList<StaticChessboard>(find.byType(StaticChessboard))) {
      expect(board.orientation, Side.black);
    }
  });

  testWidgets('with no moves to show there is no legend', (tester) async {
    await show(tester, (
      before: null,
      position: start,
      played: null,
      best: null,
      orientation: Side.white,
    ));
    expect(find.byType(StaticChessboard), findsOneWidget);
    expect(find.textContaining('arrow'), findsNothing);
  });

  testWidgets('the boards fit on a narrow phone screen', (tester) async {
    await show(tester, (
      before: start,
      position: afterE4,
      played: e4,
      best: Move.parse('d2d4'),
      orientation: Side.white,
    ), surfaceSize: const Size(320, 640));
    for (final board in tester.widgetList<StaticChessboard>(find.byType(StaticChessboard))) {
      expect(tester.getSize(find.byWidget(board)).width, lessThanOrEqualTo((320 - 12) / 2));
    }
    expect(tester.takeException(), isNull);
  });
}
