import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_move.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';

CloudEval eval(Position position, List<String> pv, {int cp = 0, int depth = 16}) => CloudEval(
  position: position,
  depth: depth,
  nodes: 1000,
  pvs: IList([PvData(moves: IList(pv), cp: cp)]),
);

void main() {
  const before = Chess.initial;
  Position afterMove(String uci) => before.play(Move.parse(uci)!);

  AiCoachRequest request({
    required String played,
    required String san,
    required int cpBefore,
    required int cpAfter,
    String bestFirst = 'e2e4',
    int depthAfter = 16,
  }) {
    final after = afterMove(played);
    // Reply lines are legal for the position after the move played.
    final replies = after.legalMoves.entries.first;
    final reply = '${replies.key.name}${replies.value.squares.first.name}';
    return makeAiCoachMoveRequest(
      before: before,
      played: SanMove(san, Move.parse(played)!),
      evalBefore: eval(before, [bestFirst, 'e7e5'], cp: cpBefore),
      evalAfter: eval(after, [reply], cp: cpAfter, depth: depthAfter),
      movesBefore: '',
    );
  }

  test('good move: played the engine first choice', () {
    final r = request(played: 'e2e4', san: 'e4', cpBefore: 30, cpAfter: 28);
    expect(r.evidence, contains('Task: explain the move that was played'));
    expect(r.evidence, contains('Move played: e4'));
    expect(r.evidence, contains('good move'));
    expect(r.evidence, contains('the move played.'));
    expect(r.allowedMoves, contains('e4'));
  });

  test('blunder: large evaluation drop is reported with the best move', () {
    final r = request(played: 'f2f3', san: 'f3', cpBefore: 30, cpAfter: -600, bestFirst: 'e2e4');
    expect(r.evidence, contains('blunder'));
    expect(r.evidence, contains("The engine's first choice was e4."));
    expect(r.allowedMoves, containsAll(['f3', 'e4']));
  });

  test('small drop is an inaccuracy or mistake, not a good move', () {
    final r = request(played: 'a2a3', san: 'a3', cpBefore: 30, cpAfter: -80);
    expect(r.evidence, isNot(contains('good move')));
  });

  test('facts for both positions are included', () {
    final r = request(played: 'e2e4', san: 'e4', cpBefore: 30, cpAfter: 28);
    expect(r.evidence, contains('Facts about the position before the move'));
    expect(r.evidence, contains('Facts about the position after the move'));
  });

  test('requires a deep enough evaluation after the move', () {
    expect(
      () => request(played: 'e2e4', san: 'e4', cpBefore: 30, cpAfter: 28, depthAfter: 5),
      throwsA(isA<AiCoachException>()),
    );
  });

  test('rejects an illegal move', () {
    expect(
      () => makeAiCoachMoveRequest(
        before: before,
        played: SanMove('e5', Move.parse('e2e5')!),
        evalBefore: eval(before, ['e2e4']),
        evalAfter: eval(before, ['e2e4']),
        movesBefore: '',
      ),
      throwsA(isA<AiCoachException>()),
    );
  });
}
