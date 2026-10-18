import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_facts.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';
import 'package:lichess_mobile/src/model/engine/practice_comment.dart';

/// The move that led to a displayed position, with the engine evaluations on both sides of it.
typedef AiCoachMoveContext = ({
  Position before,
  SanMove played,
  ClientEval? evalBefore,
  ClientEval? evalAfter,
  String movesBefore,
});

String aiCoachVerdictText(MoveVerdict verdict) => switch (verdict) {
  .goodMove => 'good move',
  .notBest => 'not the best move, but the position stays winning',
  .inaccuracy => 'inaccuracy (a small slip)',
  .mistake => 'mistake',
  .blunder => 'blunder (a serious error)',
};

/// Builds the request that explains the move [played] from the position [before].
///
/// [evalBefore] must be an evaluation of [before] and [evalAfter] of the position after the
/// move. The verdict reuses the thresholds of the app's practice mode.
AiCoachRequest makeAiCoachMoveRequest({
  required Position before,
  required SanMove played,
  required ClientEval? evalBefore,
  required ClientEval? evalAfter,
  required String movesBefore,
  String? opening,
  ClientEval? threatBefore,
  ClientEval? threatAfter,
}) {
  if (!before.isLegal(played.move)) {
    throw const AiCoachException('That move is not legal in the position before it.');
  }
  final after = before.playUnchecked(played.move);
  final beforeLines = describeEngineLines(before, evalBefore);
  // A move that ends the game (checkmate, stalemate, a draw) leaves nothing for the engine to
  // evaluate afterwards; the result is known.
  final gameOver = after.isGameOver;
  final afterLines = gameOver ? null : describeEngineLines(after, evalAfter);

  final mover = before.turn;
  final winningChancesBefore = evalBefore!.winningChances(mover);
  final winningChancesAfter = gameOver
      ? (after.isCheckmate ? 1.0 : 0.0)
      : evalAfter!.winningChances(mover);
  final evalAfterText = !gameOver
      ? evalAfter!.evalString
      : after.isCheckmate
      ? 'checkmate'
      : 'draw';
  final bestUci = evalBefore.pvs.first.moves.first;
  final playedIsBest = bestUci == played.move.uci;
  final verdict = MoveVerdict.fromShift(
    winningChancesBefore - winningChancesAfter,
    hasBetterMove: !playedIsBest,
    winningChancesBefore: winningChancesBefore,
    winningChancesAfter: winningChancesAfter,
  );

  final bestMove = Move.parse(bestUci);
  final bestSan = bestMove != null && before.isLegal(bestMove)
      ? before.makeSan(bestMove).$2
      : bestUci;

  final moverName = aiCoachSideName(before.turn);
  final opponentName = aiCoachSideName(before.turn.opposite);
  final threatOnBoard = describeThreat(
    position: before,
    evaluation: threatBefore,
    ifItWere: opponentName,
    meaning: 'what $opponentName was threatening before the move',
  );
  final threatCreated = describeThreat(
    position: after,
    evaluation: threatAfter,
    ifItWere: moverName,
    meaning: 'what $moverName threatens after the move',
  );

  final factsBefore = makeAiCoachFacts(before);
  final factsAfter = makeAiCoachFacts(after, opening: opening);

  final evidence =
      'Task: explain the move that was played, not only the position.\n'
      'Position before the move (FEN): ${before.fen}\n'
      'Move history before the move (SAN): ${movesBefore.isEmpty ? '(none)' : movesBefore}\n'
      'Side that moved: ${aiCoachSideName(mover)}\n'
      'Move played: ${played.san}\n'
      'Verdict (computed by the app from the change in evaluation): ${aiCoachVerdictText(verdict)}\n'
      '$aiCoachScoreNote\n'
      'Evaluation before the move (best line): ${evalBefore.evalString}; '
      'after the move played: $evalAfterText\n'
      "The engine's first choice was ${playedIsBest ? 'the move played' : bestSan}.\n"
      'Engine lines before the move (depth ${beforeLines.depth}):\n'
      '${beforeLines.text.join('\n')}\n'
      '${afterLines == null ? '${after.isCheckmate ? 'This move gives checkmate, so the game ends and ${aiCoachSideName(mover)} wins.' : 'This move ends the game in a draw.'}\n' : 'Engine lines after the move (depth ${afterLines.depth}):\n${afterLines.text.join('\n')}\n'}'
      '${threatOnBoard == null ? '' : '${threatOnBoard.text}\n'}'
      '${threatCreated == null ? '' : '${threatCreated.text}\n'}'
      'Facts about the position before the move:\n'
      '${factsBefore.lines.map((l) => '- $l').join('\n')}\n'
      'Facts about the position after the move:\n'
      '${factsAfter.lines.map((l) => '- $l').join('\n')}';

  return AiCoachRequest(
    evidence: evidence,
    decision: (position: before, eval: evalBefore),
    allowedMoves: {
      played.san,
      ...beforeLines.moves,
      ...?afterLines?.moves,
      ...factsBefore.moves,
      ...factsAfter.moves,
      ...?threatOnBoard?.moves,
      ...?threatCreated?.moves,
    }.toISet(),
  );
}
