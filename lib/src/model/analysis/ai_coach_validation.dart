import 'package:fast_immutable_collections/fast_immutable_collections.dart';

/// Result of checking the moves named in an AI answer against the moves the app supplied.
typedef AiCoachCheck = ({IList<String> unknownMoves, int mentions});

// Piece moves, castling, pawn captures and promotions. Plain pawn moves such as "e4" are not
// checked, because they cannot be told apart from squares ("the pawn on e4").
final _moveMention = RegExp(
  '(?<![A-Za-z0-9])'
  '(O-O-O|O-O|[KQRBN][a-h]?[1-8]?x?[a-h][1-8]|[a-h]x[a-h][1-8](?:=[QRBN])?|[a-h][18]=[QRBN])'
  '[+#]?(?![A-Za-z0-9])',
);

/// Normalises a move so that "Nbd7+" and "Nd7" compare equal: the check marks and the
/// disambiguation are dropped, and piece moves keep the piece, capture mark and destination.
String normalizeAiCoachMove(String san) {
  final move = san.replaceAll(RegExp('[+#]'), '');
  if (move.startsWith('O-O')) return move;
  final match = RegExp(r'^([KQRBN])[a-h]?[1-8]?(x?)([a-h][1-8])$').firstMatch(move);
  if (match != null) return '${match.group(1)}${match.group(2)}${match.group(3)}';
  return move;
}

/// Finds the moves named in [answer] that are not in [allowedMoves].
AiCoachCheck checkAiCoachAnswer(String answer, Iterable<String> allowedMoves) {
  final allowed = allowedMoves.map(normalizeAiCoachMove).toSet();
  final unknown = <String>{};
  var mentions = 0;
  for (final match in _moveMention.allMatches(answer)) {
    mentions++;
    final move = match.group(1)!;
    // The capture mark is optional in prose ("Nf3" vs "Nxf3"), so accept either form.
    final key = normalizeAiCoachMove(move);
    final withoutCapture = key.replaceFirst('x', '');
    final accepted =
        allowed.contains(key) || allowed.any((a) => a.replaceFirst('x', '') == withoutCapture);
    if (!accepted) unknown.add(move);
  }
  return (unknownMoves: unknown.toIList(), mentions: mentions);
}
