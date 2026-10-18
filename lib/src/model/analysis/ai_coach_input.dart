import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_move.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';

/// One move of a game, with the position it was played from.
typedef AiCoachPly = ({Position before, SanMove move});

/// What a pasted FEN or PGN describes: the position to explain, the moves leading to it, and the
/// last move when there is one (then the coach explains that move). [plies] is the whole game, in
/// order, and [result] the PGN's Result tag (such as `1-0`), when it has one.
typedef AiCoachInput = ({
  Position position,
  String moves,
  AiCoachMoveContext? lastMove,
  IList<AiCoachPly> plies,
  String? result,
});

/// The longest text accepted, so a huge paste cannot freeze the parser.
const kAiCoachMaxInputLength = 30000;

/// Parses a FEN or the first game of a PGN. Standard chess only.
///
/// Throws an [AiCoachException] with a message fit to show the user.
AiCoachInput parseAiCoachInput(String text) {
  final input = text.trim();
  if (input.isEmpty) throw const AiCoachException('Paste a FEN or a PGN first.');
  if (input.length > kAiCoachMaxInputLength) {
    throw const AiCoachException('That text is too long. Paste a single game or position.');
  }

  // A FEN is a single line; anything else is read as a PGN.
  if (!input.contains('\n') && input.contains('/') && !input.contains('[')) {
    try {
      final position = Chess.fromSetup(Setup.parseFen(input));
      return (
        position: position,
        moves: '',
        lastMove: null,
        plies: const IListConst([]),
        result: null,
      );
    } on Object {
      throw const AiCoachException('That does not look like a valid FEN position.');
    }
  }

  final PgnGame<PgnNodeData> game;
  try {
    // Several games may be pasted at once: only the first is used.
    final games = PgnGame.parseMultiGamePgn(input);
    if (games.isEmpty) throw const FormatException();
    game = games.first;
  } on Object {
    throw const AiCoachException('Could not read that PGN.');
  }

  final Position start;
  try {
    start = PgnGame.startingPosition(game.headers);
  } on Object {
    throw const AiCoachException('That game starts from an invalid position.');
  }
  if (start.rule != Rule.chess) {
    throw const AiCoachException('The coach only explains standard chess.');
  }

  var position = start;
  final plies = <AiCoachPly>[];
  final sans = <String>[];
  Position? before;
  SanMove? last;
  for (final node in game.moves.mainline()) {
    final move = position.parseSan(node.san);
    if (move == null) {
      throw AiCoachException('Illegal or unreadable move in the PGN: ${node.san}');
    }
    before = position;
    final (next, san) = position.makeSan(move);
    last = SanMove(san, move);
    plies.add((before: before, move: last));
    sans.add(san);
    position = next;
  }

  if (sans.isEmpty) {
    // The PGN parser is lenient and reads plain text as an empty game: without headers there is
    // nothing here that was meant as a position.
    if (!input.contains('[')) {
      throw const AiCoachException('Could not find a position or any moves in that text.');
    }
    return (
      position: position,
      moves: '',
      lastMove: null,
      plies: const IListConst([]),
      result: game.headers['Result'],
    );
  }
  return (
    position: position,
    moves: sans.join(' '),
    lastMove: (
      before: before!,
      played: last!,
      evalBefore: null,
      evalAfter: null,
      movesBefore: sans.sublist(0, sans.length - 1).join(' '),
    ),
    plies: plies.toIList(),
    result: game.headers['Result'],
  );
}
