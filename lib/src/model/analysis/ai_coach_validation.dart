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

/// [text] cut into pieces, each marked as a move named in it or as ordinary text, in order, so that
/// the moves can be drawn differently. Joining the pieces gives [text] back.
List<({String text, bool isMove})> splitAiCoachMoves(String text) {
  final pieces = <({String text, bool isMove})>[];
  var last = 0;
  for (final match in _moveMention.allMatches(text)) {
    // The pattern may include a check mark but never its lookarounds: use the whole match.
    if (match.start > last) pieces.add((text: text.substring(last, match.start), isMove: false));
    pieces.add((text: text.substring(match.start, match.end), isMove: true));
    last = match.end;
  }
  if (last < text.length) pieces.add((text: text.substring(last), isMove: false));
  return pieces;
}

/// The moves named in [text] (the same kinds of mention [checkAiCoachAnswer] checks).
List<String> extractAiCoachMoves(String text) => [
  for (final match in _moveMention.allMatches(text)) match.group(1)!,
];

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
