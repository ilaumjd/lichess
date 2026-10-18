import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_engine.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_facts.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_level.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_move.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';
import 'package:lichess_mobile/src/model/engine/practice_comment.dart';

/// A question about a move the user named, with the engine evidence to answer it.
typedef AiCoachAlternative = ({String question, String evidence, ISet<String> moves});

/// The longest text accepted as a move.
const kAiCoachMaxMoveInputLength = 12;

/// Reads a move the user typed, as SAN (`Nf3`, `nf3`, `exd5`, `O-O`, `0-0`) or UCI (`g1f3`).
///
/// Throws an [AiCoachException] with a message fit to show the user when it is empty, unreadable,
/// ambiguous or not legal in [position].
Move parseAiCoachMoveInput(Position position, String input) {
  var text = input.trim().replaceAll(RegExp(r'[?!+#]+$'), '');
  if (text.isEmpty) {
    throw const AiCoachException('Type a move first, for example Nf3 or e2e4.');
  }
  if (text.length > kAiCoachMaxMoveInputLength) {
    throw const AiCoachException('That does not look like a move. Try Nf3 or e2e4.');
  }

  text = text.replaceAll('0', 'O');
  if (RegExp(r'^[oO]-[oO](-[oO])?$').hasMatch(text)) text = text.toUpperCase();

  final candidates = <String>{
    text,
    // "nf3" is read as a knight move: SAN needs a capital for pieces. A pawn capture such as
    // "bxc3" is tried as typed first, so it keeps its meaning when that is legal.
    if (RegExp('^[nbrqk]').hasMatch(text) && text.length >= 3)
      '${text[0].toUpperCase()}${text.substring(1)}',
  };
  for (final candidate in candidates) {
    final move = position.parseSan(candidate);
    if (move != null) return move;
  }

  if (RegExp(r'^[a-hA-H][1-8][a-hA-H][1-8][qrbnQRBN]?$').hasMatch(text)) {
    final move = Move.parse(text.toLowerCase());
    if (move != null && position.isLegal(move)) return move;
  }

  throw AiCoachException('"${input.trim()}" is not a legal move in this position.');
}

/// Builds the evidence for "why not [input]?": the engine's best move against the move named,
/// with real evaluations of both. Runs Stockfish on the position after the named move.
///
/// Throws an [AiCoachException] if the move cannot be read or the engine runs out of time.
Future<AiCoachAlternative> prepareAiCoachAlternative(
  AiCoachEngine engine, {
  required AiCoachDecision decision,
  required String input,
  AiCoachLevel level = AiCoachLevel.beginner,
}) async {
  final position = decision.position;
  final move = parseAiCoachMoveInput(position, input);
  final (after, san) = position.makeSanUnchecked(move);
  final mover = position.turn;
  final moverName = aiCoachSideName(mover);

  final bestLines = describeEngineLines(position, decision.eval, level: level);
  final bestUci = decision.eval.pvs.first.moves.first;
  final bestMove = Move.parse(bestUci);
  final bestSan = bestMove != null && position.isLegal(bestMove)
      ? position.makeSan(bestMove).$2
      : bestUci;
  final isBest = move.uci == bestUci;

  final question = 'Why not $san?';
  final header =
      'The user asks: why not play $san instead?\n'
      'Position before the choice (FEN): ${position.fen}\n'
      'Side to move: $moverName\n'
      "The engine's preferred move: $bestSan\n"
      'The move the user asks about: $san '
      "(${isBest ? "this is the engine's first choice" : "not the engine's first choice"})\n";
  final bestBlock =
      'Engine lines at the position before the choice (depth ${bestLines.depth}):\n'
      '${bestLines.text.join('\n')}\n';

  // Games that end with the move need no engine.
  if (after.isCheckmate || after.isStalemate || after.isInsufficientMaterial) {
    final outcome = after.isCheckmate
        ? 'This move gives checkmate, so the game ends and $moverName wins.'
        : 'This move ends the game in a draw (stalemate or not enough material to win).';
    return (
      question: question,
      evidence: '$header$bestBlock$outcome',
      moves: {san, ...bestLines.moves}.toISet(),
    );
  }

  final ClientEval? evalAfter = await engine.evaluate(after, level: level);
  final AiCoachLines afterLines;
  try {
    afterLines = describeEngineLines(after, evalAfter, level: level);
  } on AiCoachException {
    throw AiCoachException('Stockfish could not analyse $san in time. Please try again.');
  }

  final winningChancesBest = decision.eval.winningChances(mover);
  final winningChancesAfter = evalAfter!.winningChances(mover);
  final verdict = MoveVerdict.fromShift(
    winningChancesBest - winningChancesAfter,
    hasBetterMove: !isBest,
    winningChancesBefore: winningChancesBest,
    winningChancesAfter: winningChancesAfter,
  );
  final facts = makeAiCoachFacts(after);

  final evidence =
      '$header'
      'Verdict for $san (computed by the app from the change in evaluation): '
      '${aiCoachVerdictText(verdict)}\n'
      '$aiCoachScoreNote\n'
      'Evaluation: best line ${decision.eval.evalString}; after $san ${evalAfter.evalString}.\n'
      '$bestBlock'
      'Engine lines after $san (depth ${afterLines.depth}):\n${afterLines.text.join('\n')}\n'
      'Facts about the position after $san:\n${facts.lines.map((l) => '- $l').join('\n')}';

  return (
    question: question,
    evidence: evidence,
    moves: {san, ...bestLines.moves, ...afterLines.moves, ...facts.moves}.toISet(),
  );
}

/// The boards for a saved or shown "Why not X?" question, or null when [question] is not one or X
/// is not a legal move in [position]. [position] is where the choice was made and [best] the
/// engine's preferred move there. Needs no engine: it only draws what the question names.
AiCoachBoards? aiCoachAlternativeBoards({
  required Position position,
  required Move? best,
  required String question,

  /// The side at the bottom: the side the user plays when known, else the side to move.
  Side? orientation,
}) {
  final match = RegExp(r'^Why not (.+)\?$').firstMatch(question.trim());
  if (match == null) return null;
  try {
    final move = parseAiCoachMoveInput(position, match.group(1)!);
    return (
      before: position,
      position: position.playUnchecked(move),
      played: move,
      best: best,
      orientation: orientation ?? position.turn,
    );
  } on AiCoachException {
    return null;
  }
}
