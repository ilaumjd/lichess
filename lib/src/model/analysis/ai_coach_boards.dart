import 'package:dartchess/dartchess.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';

/// The rest of the line that starts with [prefix], or null when there is no such line.
String? _after(String evidence, String prefix) {
  for (final line in evidence.split('\n')) {
    if (line.startsWith(prefix)) return line.substring(prefix.length).trim();
  }
  return null;
}

/// A move written in standard notation, ignoring check marks and a trailing full stop.
Move? _san(Position position, String text) =>
    position.parseSan(text.replaceAll(RegExp(r'[+#.]+$'), ''));

/// The side the evidence says the user plays, or null when it does not say.
Side? _userSide(String evidence) => switch (_after(evidence, 'The user is playing ')) {
  'White.' => Side.white,
  'Black.' => Side.black,
  _ => null,
};

/// Rebuilds the boards of a saved explanation from its evidence, so that explanations saved before
/// the boards existed (and the ones opened from the history) can show them too.
///
/// Understands the evidence of a move explanation and of a position explanation, standard chess
/// only. Returns null for anything else, or when the evidence cannot be read.
AiCoachBoards? aiCoachBoardsFromEvidence(String evidence) {
  try {
    if (evidence.startsWith('Task: explain the move that was played')) {
      final fen = _after(evidence, 'Position before the move (FEN): ');
      final san = _after(evidence, 'Move played: ');
      final first = _after(evidence, "The engine's first choice was ");
      if (fen == null || san == null) return null;
      final before = Chess.fromSetup(Setup.parseFen(fen));
      final played = _san(before, san);
      if (played == null) return null;
      final best = first == null || first.startsWith('the move played')
          ? played
          : _san(before, first);
      return (
        before: before,
        position: before.playUnchecked(played),
        played: played,
        best: best,
        orientation: _userSide(evidence) ?? before.turn,
      );
    }
    if (evidence.startsWith('Task: explain this position.')) {
      final fen = _after(evidence, 'FEN: ');
      if (fen == null) return null;
      final position = Chess.fromSetup(Setup.parseFen(fen));
      // The first engine line looks like "1. score +0.2; line: e4 e5 Nf3".
      final line = _after(evidence, '1. score ');
      final lineMoves = line?.split('line: ').last.split(' ');
      final best = lineMoves == null || lineMoves.isEmpty ? null : _san(position, lineMoves.first);
      return (
        before: null,
        position: position,
        played: null,
        best: best,
        orientation: _userSide(evidence) ?? position.turn,
      );
    }
  } on Object {
    return null;
  }
  return null;
}
