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

String _verdictText(MoveVerdict verdict) => switch (verdict) {
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
}) {
  if (!before.isLegal(played.move)) {
    throw const AiCoachException('That move is not legal in the position before it.');
  }
  final after = before.playUnchecked(played.move);
  final beforeLines = describeEngineLines(before, evalBefore);
  final afterLines = describeEngineLines(after, evalAfter);

  final mover = before.turn;
  final winningChancesBefore = evalBefore!.winningChances(mover);
  final winningChancesAfter = evalAfter!.winningChances(mover);
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

  final factsBefore = makeAiCoachFacts(before);
  final factsAfter = makeAiCoachFacts(after, opening: opening);

  final evidence =
      'Task: explain the move that was played, not only the position.\n'
      'Position before the move (FEN): ${before.fen}\n'
      'Move history before the move (SAN): ${movesBefore.isEmpty ? '(none)' : movesBefore}\n'
      'Side that moved: ${aiCoachSideName(mover)}\n'
      'Move played: ${played.san}\n'
      'Verdict (computed by the app from the change in evaluation): ${_verdictText(verdict)}\n'
      '$aiCoachScoreNote\n'
      'Evaluation before the move (best line): ${evalBefore.evalString}; '
      'after the move played: ${evalAfter.evalString}\n'
      "The engine's first choice was ${playedIsBest ? 'the move played' : bestSan}.\n"
      'Engine lines before the move (depth ${beforeLines.depth}):\n'
      '${beforeLines.text.join('\n')}\n'
      'Engine lines after the move (depth ${afterLines.depth}):\n'
      '${afterLines.text.join('\n')}\n'
      'Facts about the position before the move:\n'
      '${factsBefore.lines.map((l) => '- $l').join('\n')}\n'
      'Facts about the position after the move:\n'
      '${factsAfter.lines.map((l) => '- $l').join('\n')}';

  return (
    evidence: evidence,
    allowedMoves: {
      played.san,
      ...beforeLines.moves,
      ...afterLines.moves,
      ...factsBefore.moves,
      ...factsAfter.moves,
    }.toISet(),
  );
}
