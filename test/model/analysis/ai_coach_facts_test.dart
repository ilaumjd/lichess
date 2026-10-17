import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_facts.dart';

String joined(String fen, {String? opening}) =>
    makeAiCoachFacts(Chess.fromSetup(Setup.parseFen(fen)), opening: opening).lines.join('\n');

void main() {
  test('start position: equal material, no captures or hanging pieces', () {
    final text = joined(kInitialFEN);
    expect(
      text,
      contains('Material (pawn 1, knight 3, bishop 3, rook 5, queen 9): White 39, Black 39'),
    );
    expect(text, contains('Material is equal.'));
    expect(text, isNot(contains('Attacked and not defended')));
    expect(text, isNot(contains('can capture')));
    expect(text, contains('castling is still possible'));
  });

  test('reports who is ahead in material', () {
    final text = joined('4k3/8/8/8/8/8/4P3/4KQ2 w - - 0 1');
    expect(text, contains('White is ahead by 10.'));
  });

  test('finds an undefended attacked piece', () {
    // Black knight on e5 is attacked by the white pawn on d4 and has no defender.
    final text = joined('4k3/8/8/4n3/3P4/8/8/4K3 w - - 0 1');
    expect(text, contains('Black knight on e5'));
    expect(text, contains('Attacked and not defended'));
    expect(text, contains('dxe5 (takes a knight)'));
  });

  test('finds a piece attacked by a cheaper piece even if defended', () {
    // White queen on d4 attacked by the black pawn on e5, defended by the king on e3.
    final text = joined('4k3/8/8/4p3/3Q4/4K3/8/8 b - - 0 1');
    expect(text, contains('White queen on d4 (attacked by a pawn on e5)'));
  });

  test('describes check, checkmate and stalemate', () {
    expect(joined('4k3/8/8/8/8/8/4q3/4K3 w - - 0 1'), contains('White is in check.'));
    expect(joined('R5k1/5ppp/8/8/8/8/8/4K3 b - - 0 1'), contains('Black is checkmated.'));
    expect(joined('7k/5Q2/6K1/8/8/8/8/8 b - - 0 1'), contains('stalemate'));
  });

  test('lists checks available to the side to move', () {
    final facts = makeAiCoachFacts(
      Chess.fromSetup(Setup.parseFen('4k3/8/8/8/8/8/8/R3K3 w - - 0 1')),
    );
    expect(facts.lines.join('\n'), contains('can give check with: Ra8+'));
    expect(facts.moves, contains('Ra8+'));
  });

  test('includes the supplied opening name and king state', () {
    final text = joined(kInitialFEN, opening: 'Italian Game');
    expect(text, contains('Opening: Italian Game.'));
    expect(text, contains('White king on e1'));
    expect(joined('4k3/8/8/8/8/8/8/4K3 w - - 0 1'), contains('castling is no longer possible'));
  });
}
