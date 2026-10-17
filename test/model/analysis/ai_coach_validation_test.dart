import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_validation.dart';

void main() {
  test('normalises check marks and disambiguation', () {
    expect(normalizeAiCoachMove('Nbd7+'), 'Nd7');
    expect(normalizeAiCoachMove('Qxf7#'), 'Qxf7');
    expect(normalizeAiCoachMove('O-O-O+'), 'O-O-O');
    expect(normalizeAiCoachMove('exd5'), 'exd5');
  });

  test('accepts moves that were supplied, with or without check marks', () {
    final result = checkAiCoachAnswer('Nf3 develops a knight, then Bb5+ pins it.', ['Nf3', 'Bb5']);
    expect(result.unknownMoves, isEmpty);
    expect(result.mentions, 2);
  });

  test('flags piece moves that were not supplied', () {
    final result = checkAiCoachAnswer('White should play Qh5 or Nf3.', ['Nf3']);
    expect(result.unknownMoves.unlock, ['Qh5']);
  });

  test('does not flag plain squares or pawn pushes in prose', () {
    final result = checkAiCoachAnswer('The pawn on e4 controls d5 and f5.', <String>[]);
    expect(result.mentions, 0);
    expect(result.unknownMoves, isEmpty);
  });

  test('checks pawn captures, castling and promotions', () {
    final result = checkAiCoachAnswer('exd5 opens lines, O-O is safe, a8=Q wins.', ['exd5']);
    expect(result.unknownMoves.unlock, ['O-O', 'a8=Q']);
  });

  test('accepts a capture written without the x', () {
    expect(checkAiCoachAnswer('Nf3 takes the pawn.', ['Nxf3']).unknownMoves, isEmpty);
  });

  test('ignores words that merely look like moves inside other words', () {
    expect(checkAiCoachAnswer('Rb1ing around is silly', <String>[]).mentions, 0);
  });
}
