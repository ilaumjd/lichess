import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_alternative.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_engine.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_level.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';

import '../../test_container.dart';

final _refProvider = Provider<Ref>((ref) => ref);

CloudEval cloud(Position position, List<String> pv, {int cp = 20, int depth = 16}) => CloudEval(
  position: position,
  depth: depth,
  nodes: 1000,
  pvs: IList([PvData(moves: IList(pv), cp: cp)]),
);

/// An engine service with scripted evaluations; records the positions it was asked about.
class ScriptedEngine(super.ref, final ClientEval? Function(Position position) script)
    extends AiCoachEngine {
  final asked = <String>[];

  @override
  Future<ClientEval?> evaluate(
    Position position, {
    Duration? timeout,
    AiCoachLevel level = AiCoachLevel.beginner,
  }) async {
    asked.add(position.fen);
    return script(position);
  }
}

Position fen(String value) => Chess.fromSetup(Setup.parseFen(value));

void main() {
  group('parseAiCoachMoveInput', () {
    const start = Chess.initial;
    final castling = fen('r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1');

    String san(Position position, String input) =>
        position.makeSan(parseAiCoachMoveInput(position, input)).$2;

    test('reads SAN, with or without a capital, check marks and annotations', () {
      expect(san(start, 'Nf3'), 'Nf3');
      expect(san(start, 'nf3'), 'Nf3');
      expect(san(start, ' e4 '), 'e4');
      expect(san(start, 'Nf3?!'), 'Nf3');
      expect(san(start, 'Nc3+'), 'Nc3');
    });

    test('reads UCI, in any case', () {
      expect(san(start, 'g1f3'), 'Nf3');
      expect(san(start, 'E2E4'), 'e4');
    });

    test('reads castling in the usual spellings', () {
      for (final input in ['O-O', 'o-o', '0-0']) {
        expect(san(castling, input), 'O-O', reason: input);
      }
      for (final input in ['O-O-O', '0-0-0', 'o-o-o']) {
        expect(san(castling, input), 'O-O-O', reason: input);
      }
    });

    test('a pawn capture keeps its meaning when it is legal as typed', () {
      final position = fen('4k3/8/8/8/8/2p5/1P6/4K3 w - - 0 1');
      expect(san(position, 'bxc3'), 'bxc3');
    });

    test('rejects empty, oversize, garbage and illegal input with a readable message', () {
      for (final bad in ['', '   ', '??']) {
        expect(
          () => parseAiCoachMoveInput(start, bad),
          throwsA(
            isA<AiCoachException>().having((e) => e.message, 'message', contains('Type a move')),
          ),
          reason: bad,
        );
      }
      expect(
        () => parseAiCoachMoveInput(start, 'e2e4e2e4e2e4e2e4'),
        throwsA(
          isA<AiCoachException>().having(
            (e) => e.message,
            'message',
            contains('does not look like'),
          ),
        ),
      );
      for (final bad in ['hello', 'Ke4', 'e5', 'O-O', 'a1a8']) {
        expect(
          () => parseAiCoachMoveInput(start, bad),
          throwsA(
            isA<AiCoachException>().having(
              (e) => e.message,
              'message',
              contains('not a legal move'),
            ),
          ),
          reason: bad,
        );
      }
    });
  });

  group('prepareAiCoachAlternative', () {
    const start = Chess.initial;

    Future<ProviderContainer> container() async {
      final c = await makeContainer();
      addTearDown(c.dispose);
      return c;
    }

    AiCoachDecision decision() => (position: start, eval: cloud(start, ['e2e4', 'e7e5'], cp: 30));

    // The reply line must be legal in whatever position the engine is asked about.
    ClientEval answer(Position position, {int cp = 0}) {
      final first = position.legalMoves.entries.firstWhere((e) => e.value.isNotEmpty);
      final reply = '${first.key.name}${first.value.squares.first.name}';
      return cloud(position, [reply], cp: cp);
    }

    test("the engine's own first choice is reported as such", () async {
      final c = await container();
      final engine = ScriptedEngine(c.read(_refProvider), (p) => answer(p, cp: 28));
      final alt = await prepareAiCoachAlternative(engine, decision: decision(), input: 'e4');
      expect(alt.question, 'Why not e4?');
      expect(alt.evidence, contains("this is the engine's first choice"));
      expect(alt.evidence, contains('good move'));
      expect(alt.moves, contains('e4'));
    });

    test('a bad move is compared with the best one using both evaluations', () async {
      final c = await container();
      final engine = ScriptedEngine(c.read(_refProvider), (p) => answer(p, cp: -600));
      final alt = await prepareAiCoachAlternative(engine, decision: decision(), input: 'f3');
      expect(alt.question, 'Why not f3?');
      expect(alt.evidence, contains("The engine's preferred move: e4"));
      expect(alt.evidence, contains("not the engine's first choice"));
      expect(alt.evidence, contains('blunder'));
      expect(alt.evidence, contains('Evaluation: best line +0.3; after f3 -6.0'));
      expect(alt.evidence, contains('Engine lines at the position before the choice'));
      expect(alt.evidence, contains('Engine lines after f3'));
      expect(alt.evidence, contains('Facts about the position after f3'));
      expect(alt.moves, containsAll(['f3', 'e4']));
    });

    test('the engine is asked only about the position after the named move', () async {
      final c = await container();
      final engine = ScriptedEngine(c.read(_refProvider), (p) => answer(p));
      await prepareAiCoachAlternative(engine, decision: decision(), input: 'Nf3');
      expect(engine.asked, [start.play(Move.parse('g1f3')!).fen]);
    });

    test('says so when Stockfish ran out of time, naming the move', () async {
      final c = await container();
      final engine = ScriptedEngine(c.read(_refProvider), (_) => null);
      await expectLater(
        prepareAiCoachAlternative(engine, decision: decision(), input: 'Nf3'),
        throwsA(isA<AiCoachException>().having((e) => e.message, 'message', contains('Nf3'))),
      );
    });

    test('an unreadable move never reaches the engine', () async {
      final c = await container();
      final engine = ScriptedEngine(c.read(_refProvider), (p) => answer(p));
      await expectLater(
        prepareAiCoachAlternative(engine, decision: decision(), input: 'Ke4'),
        throwsA(isA<AiCoachException>()),
      );
      expect(engine.asked, isEmpty);
    });

    test('a move that gives checkmate needs no engine', () async {
      // Fool's mate: Black to play Qh4#.
      final position = fen('rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq - 0 2');
      final c = await container();
      final engine = ScriptedEngine(c.read(_refProvider), (p) => answer(p));
      final alt = await prepareAiCoachAlternative(
        engine,
        decision: (position: position, eval: cloud(position, ['d8h4'], cp: -9000)),
        input: 'Qh4',
      );
      expect(alt.evidence, contains('gives checkmate'));
      expect(alt.evidence, contains("this is the engine's first choice"));
      expect(engine.asked, isEmpty);
    });

    test('a move that stalemates is reported as a draw without the engine', () async {
      final position = fen('7k/5Q2/8/8/8/8/8/6K1 w - - 0 1');
      final c = await container();
      final engine = ScriptedEngine(c.read(_refProvider), (p) => answer(p));
      final alt = await prepareAiCoachAlternative(
        engine,
        decision: (position: position, eval: cloud(position, ['f7g7'], cp: 9000)),
        input: 'Qg6',
      );
      expect(alt.evidence, contains('draw'));
      expect(engine.asked, isEmpty);
    });

    test('needs a usable evaluation of the position before the choice', () async {
      final c = await container();
      final engine = ScriptedEngine(c.read(_refProvider), (p) => answer(p));
      await expectLater(
        prepareAiCoachAlternative(
          engine,
          decision: (position: start, eval: cloud(start, ['e2e4'], depth: 3)),
          input: 'Nf3',
        ),
        throwsA(isA<AiCoachException>()),
      );
    });
  });

  group('aiCoachAlternativeBoards', () {
    const start = Chess.initial;
    final best = Move.parse('e2e4');

    AiCoachBoards? boards(String question, {Position? position}) =>
        aiCoachAlternativeBoards(position: position ?? start, best: best, question: question);

    test('draws the position, the named move and the engine move', () {
      final result = boards('Why not Nf3?')!;
      expect(result.before!.fen, start.fen);
      expect(result.position.fen, start.play(Move.parse('g1f3')!).fen);
      expect(result.played, Move.parse('g1f3'));
      expect(result.best, best);
      expect(result.orientation, Side.white);
    });

    test('reads the move however it was typed in the question', () {
      expect(boards('Why not nf3?')!.played, Move.parse('g1f3'));
      expect(boards('Why not g1f3?')!.played, Move.parse('g1f3'));
      expect(boards('  Why not Nf3?  ')!.played, Move.parse('g1f3'));
      final castling = fen('r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1');
      expect(boards('Why not O-O?', position: castling)!.played, isNotNull);
    });

    test('is seen from the side that has to choose', () {
      final black = start.play(Move.parse('e2e4')!);
      expect(boards('Why not e5?', position: black)!.orientation, Side.black);
    });

    test('is nothing for questions that do not name a move', () {
      for (final question in [
        'Explain simpler',
        'What should I do differently?',
        'Why not?',
        'Why not Nf3',
        'why not Nf3?',
        'Why is Nf3 better?',
        '',
      ]) {
        expect(boards(question), isNull, reason: question);
      }
    });

    test('is nothing when the move is not legal in the position', () {
      expect(boards('Why not Ke4?'), isNull);
      expect(boards('Why not banana?'), isNull);
    });

    test('works without an engine move, and when the move named is the best one', () {
      expect(
        aiCoachAlternativeBoards(position: start, best: null, question: 'Why not e4?')!.best,
        isNull,
      );
      final same = boards('Why not e4?')!;
      expect(same.played, same.best);
    });
  });
}
