import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_input.dart';

void main() {
  test('reads a FEN', () {
    final input = parseAiCoachInput(' $kInitialFEN \n');
    expect(input.position.fen, kInitialFEN);
    expect(input.moves, isEmpty);
    expect(input.lastMove, isNull);
  });

  test('reads a PGN and exposes the last move with the position before it', () {
    final input = parseAiCoachInput('[Event "x"]\n\n1. e4 e5 2. Nf3 Nc6 *');
    expect(input.moves, 'e4 e5 Nf3 Nc6');
    final last = input.lastMove!;
    expect(last.played.san, 'Nc6');
    expect(last.movesBefore, 'e4 e5 Nf3');
    expect(last.before.fen, contains('rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b'));
    expect(last.evalBefore, isNull);
    expect(last.evalAfter, isNull);
    expect(input.position.ply, 4);
  });

  test('a PGN without moves is just the starting position', () {
    final input = parseAiCoachInput('[Event "x"]\n\n*');
    expect(input.position.fen, kInitialFEN);
    expect(input.lastMove, isNull);
  });

  test('honours a FEN header', () {
    final input = parseAiCoachInput('[FEN "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"]\n\n1. e4 *');
    expect(input.lastMove!.before.fen, startsWith('4k3/8/8/8/8/8/4P3/4K3'));
    expect(input.moves, 'e4');
  });

  test('only the first game of several is used', () {
    final input = parseAiCoachInput('1. e4 *\n\n[Event "two"]\n\n1. d4 *');
    expect(input.moves, 'e4');
  });

  test('rejects empty, garbage and oversize input with a readable message', () {
    for (final bad in ['', '   ', 'hello world']) {
      expect(() => parseAiCoachInput(bad), throwsA(isA<AiCoachException>()), reason: bad);
    }
    expect(
      () => parseAiCoachInput('a' * (kAiCoachMaxInputLength + 1)),
      throwsA(isA<AiCoachException>().having((e) => e.message, 'message', contains('too long'))),
    );
  });

  test('rejects an invalid FEN', () {
    expect(
      () => parseAiCoachInput('8/8/8/8/8/8/8/8 w - - 0 1'),
      throwsA(isA<AiCoachException>().having((e) => e.message, 'message', contains('FEN'))),
    );
  });

  test('rejects an illegal move and names it', () {
    expect(
      () => parseAiCoachInput('1. e4 e5 2. Ke4 *'),
      throwsA(isA<AiCoachException>().having((e) => e.message, 'message', contains('Ke4'))),
    );
  });

  test('rejects variants', () {
    expect(
      () => parseAiCoachInput('[Variant "Atomic"]\n\n1. e4 e5 *'),
      throwsA(isA<AiCoachException>()),
    );
  });
}
