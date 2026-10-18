import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_boards.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_move.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';

CloudEval eval(Position position, List<String> pv, {int cp = 20}) => CloudEval(
  position: position,
  depth: 16,
  nodes: 1,
  pvs: IList([PvData(moves: IList(pv), cp: cp)]),
);

String firstReply(Position position) {
  final entry = position.legalMoves.entries.firstWhere((e) => e.value.isNotEmpty);
  return '${entry.key.name}${entry.value.squares.first.name}';
}

void main() {
  const start = Chess.initial;
  final e4 = Move.parse('e2e4')!;
  final afterE4 = start.play(e4);

  AiCoachRequest moveRequest({String best = 'd2d4', Position? before, Move? played}) {
    final from = before ?? start;
    final move = played ?? e4;
    final after = from.play(move);
    return makeAiCoachMoveRequest(
      before: from,
      played: SanMove(from.makeSan(move).$2, move),
      evalBefore: eval(from, [best]),
      evalAfter: eval(after, [firstReply(after)]),
      movesBefore: '',
    );
  }

  group('boards of a request', () {
    test('a move shows the position before and after it, the move and the best move', () {
      final boards = moveRequest().boards!;
      expect(boards.before!.fen, start.fen);
      expect(boards.position.fen, afterE4.fen);
      expect(boards.played, e4);
      expect(boards.best, Move.parse('d2d4'));
      expect(boards.orientation, Side.white);
    });

    test('the board is seen from the side that moved', () {
      final black = Move.parse('e7e5')!;
      final request = moveRequest(before: afterE4, played: black, best: 'c7c5');
      expect(request.boards!.orientation, Side.black);
      expect(request.boards!.before!.fen, afterE4.fen);
    });

    test('when the move played is the best one, both point at the same move', () {
      final boards = moveRequest(best: 'e2e4').boards!;
      expect(boards.best, boards.played);
    });

    test('a position shows itself and the engine preferred move', () {
      final request = makeAiCoachRequest(start, eval(start, ['g1f3', 'g8f6']), '');
      final boards = request.boards!;
      expect(boards.before, isNull);
      expect(boards.position.fen, start.fen);
      expect(boards.played, isNull);
      expect(boards.best, Move.parse('g1f3'));
      expect(boards.orientation, Side.white);
    });

    test('a move that ends the game shows the final position', () {
      final before = Chess.fromSetup(
        Setup.parseFen('rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq - 0 2'),
      );
      final qh4 = Move.parse('d8h4')!;
      final request = makeAiCoachMoveRequest(
        before: before,
        played: SanMove('Qh4#', qh4),
        evalBefore: eval(before, ['d8h4'], cp: -9000),
        evalAfter: null,
        movesBefore: '',
      );
      expect(request.boards!.position.isCheckmate, isTrue);
      expect(request.boards!.played, qh4);
    });
  });

  group('boards rebuilt from saved evidence', () {
    void expectSame(AiCoachBoards? rebuilt, AiCoachBoards original) {
      expect(rebuilt, isNotNull);
      expect(rebuilt!.before?.fen, original.before?.fen);
      expect(rebuilt.position.fen, original.position.fen);
      expect(rebuilt.played, original.played);
      expect(rebuilt.best, original.best);
      expect(rebuilt.orientation, original.orientation);
    }

    test('a move explanation gives the same boards again', () {
      final request = moveRequest();
      expectSame(aiCoachBoardsFromEvidence(request.evidence), request.boards!);
    });

    test('a move that was the best move gives the same boards again', () {
      final request = moveRequest(best: 'e2e4');
      expectSame(aiCoachBoardsFromEvidence(request.evidence), request.boards!);
    });

    test('a Black move is seen from Black again', () {
      final request = moveRequest(before: afterE4, played: Move.parse('e7e5'), best: 'c7c5');
      expectSame(aiCoachBoardsFromEvidence(request.evidence), request.boards!);
    });

    test('a move with a check mark is read back', () {
      final before = Chess.fromSetup(Setup.parseFen('4k3/8/8/8/8/8/8/R3K3 w - - 0 1'));
      final capture = Move.parse('a1a8')!;
      final request = makeAiCoachMoveRequest(
        before: before,
        played: SanMove(before.makeSan(capture).$2, capture),
        evalBefore: eval(before, ['a1a8']),
        evalAfter: eval(before.play(capture), [firstReply(before.play(capture))]),
        movesBefore: '',
      );
      expectSame(aiCoachBoardsFromEvidence(request.evidence), request.boards!);
    });

    test('a position explanation gives the same boards again', () {
      final request = makeAiCoachRequest(start, eval(start, ['g1f3', 'g8f6']), '');
      expectSame(aiCoachBoardsFromEvidence(request.evidence), request.boards!);
    });

    test('other kinds of evidence, or damaged evidence, give nothing', () {
      for (final text in [
        '',
        'Task: review the whole game.\nCoach level: Beginner',
        'The user asks: why not play Nf3 instead?',
        'Task: explain this position.\nSide to move: White',
        'Task: explain this position.\nFEN: not a fen',
        'Task: explain the move that was played, not only the position.\nMove played: e4',
        // Ke4 is not a legal move in the position before it.
        'Task: explain the move that was played, not only the position.\nPosition before the move (FEN): ${start.fen}\nMove played: Ke4',
      ]) {
        expect(aiCoachBoardsFromEvidence(text), isNull, reason: text);
      }
    });
  });

  group("the user's side in boards rebuilt from evidence", () {
    test('a move explanation is turned to the side the evidence names', () {
      final black = Move.parse('e7e5')!;
      final before = afterE4;
      final request = makeAiCoachMoveRequest(
        before: before,
        played: SanMove('e5', black),
        evalBefore: eval(before, ['c7c5']),
        evalAfter: eval(before.play(black), [firstReply(before.play(black))]),
        movesBefore: 'e4',
        userSide: Side.white,
      );
      expect(request.boards!.orientation, Side.white);
      expect(aiCoachBoardsFromEvidence(request.evidence)!.orientation, Side.white);
    });

    test('a position explanation too', () {
      final request = makeAiCoachRequest(
        start,
        eval(start, ['g1f3', 'g8f6']),
        '',
        userSide: Side.black,
      );
      expect(aiCoachBoardsFromEvidence(request.evidence)!.orientation, Side.black);
    });

    test('evidence saved before the side was recorded is still read, by the mover', () {
      final request = moveRequest(before: afterE4, played: Move.parse('e7e5'), best: 'c7c5');
      expect(request.evidence, isNot(contains('The user is playing')));
      expect(aiCoachBoardsFromEvidence(request.evidence)!.orientation, Side.black);
    });
  });
}
