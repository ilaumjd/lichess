import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_engine.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';
import 'package:lichess_mobile/src/model/engine/position_evaluator.dart';

import '../../binding.dart';
import '../../test_container.dart';
import '../engine/fake_engine.dart';

final _refProvider = Provider<Ref>((ref) => ref);

/// Long enough for the evaluator's throttle to have let the last info line through.
Future<void> settle() =>
    Future<void>.delayed(kEngineEvalEmissionThrottleDelay * 2, () => Future<void>.value());

CloudEval cloud(Position position, List<String> pv, {int cp = 20, int depth = 16}) => CloudEval(
  position: position,
  depth: depth,
  nodes: 1000,
  pvs: IList([PvData(moves: IList(pv), cp: cp)]),
);

/// An engine service whose evaluations are scripted, so request building is tested without a
/// search.
class ScriptedEngine(super.ref, final ClientEval? Function(Position position) script)
    extends AiCoachEngine {
  final asked = <String>[];

  @override
  Future<ClientEval?> evaluate(Position position, {Duration timeout = kAiCoachSearchTime}) async {
    asked.add(position.fen);
    return script(position);
  }
}

void main() {
  TestLichessBinding.ensureInitialized();

  late AnalysisTestEngine engine;

  setUp(() {
    engine = AnalysisTestEngine();
    fakeEngine = engine;
  });

  group('AiCoachEngine', () {
    test('evaluates on demand, then lets the search go', () async {
      final container = await makeContainer();
      container.listen(aiCoachEngineProvider, (_, _) {});
      final coach = container.read(aiCoachEngineProvider);

      final future = coach.evaluate(Chess.initial);
      await settle();
      engine.emitDepthRange(toDepth: kAiCoachMinDepth);
      final eval = await future;

      expect(eval, isNotNull);
      expect(eval!.depth, greaterThanOrEqualTo(kAiCoachMinDepth));
      expect(engine.requestedPositions, [Chess.initial.fen]);
      // Not left searching up to the practice target depth: that would drain the battery.
      expect(engine.stopCount, greaterThanOrEqualTo(1));
    });

    test('a position that is already deep enough is not searched again', () async {
      final container = await makeContainer();
      container.listen(aiCoachEngineProvider, (_, _) {});
      final coach = container.read(aiCoachEngineProvider);

      final first = coach.evaluate(Chess.initial);
      await settle();
      engine.emitDepthRange(toDepth: kAiCoachMinDepth);
      await first;

      final again = await coach.evaluate(Chess.initial);
      expect(again!.depth, greaterThanOrEqualTo(kAiCoachMinDepth));
      expect(engine.requestedPositions, [Chess.initial.fen]);
    });
  });

  group('prepareAiCoachRequest', () {
    const before = Chess.initial;
    final e4 = Move.parse('e2e4')!;
    final after = before.play(e4);
    final played = SanMove('e4', e4);

    Future<ProviderContainer> container() async {
      final c = await makeContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('uses evaluations that are already deep enough without running the engine', () async {
      final c = await container();
      final scripted = ScriptedEngine(c.read(_refProvider), (_) => null);
      final request = await prepareAiCoachRequest(
        scripted,
        position: after,
        currentEval: cloud(after, ['e7e5', 'g1f3']),
        moves: 'e4',
        move: (
          before: before,
          played: played,
          evalBefore: cloud(before, ['e2e4', 'e7e5']),
          evalAfter: cloud(after, ['e7e5', 'g1f3']),
          movesBefore: '',
        ),
      );
      expect(scripted.asked, isEmpty);
      expect(request.evidence, contains('Task: explain the move that was played'));
    });

    test('runs the engine only for the positions that lack an evaluation', () async {
      final c = await container();
      final scripted = ScriptedEngine(
        c.read(_refProvider),
        (position) => position.fen == before.fen
            ? cloud(before, ['e2e4', 'e7e5'])
            : cloud(position, ['e7e5', 'g1f3']),
      );
      final request = await prepareAiCoachRequest(
        scripted,
        position: after,
        currentEval: null,
        moves: 'e4',
        move: (
          before: before,
          played: played,
          evalBefore: null,
          evalAfter: cloud(after, ['e7e5', 'g1f3']),
          movesBefore: '',
        ),
      );
      expect(scripted.asked, [before.fen]);
      expect(request.evidence, contains('Task: explain the move that was played'));
    });

    test('falls back to the position when the move cannot be explained', () async {
      final c = await container();
      final scripted = ScriptedEngine(
        c.read(_refProvider),
        // Nothing for the position before the move; the position after it is fine.
        (position) => position.fen == before.fen ? null : cloud(position, ['e7e5', 'g1f3']),
      );
      final request = await prepareAiCoachRequest(
        scripted,
        position: after,
        currentEval: null,
        moves: 'e4',
        move: (before: before, played: played, evalBefore: null, evalAfter: null, movesBefore: ''),
      );
      expect(request.evidence, contains('Task: explain this position.'));
    });

    test('fails clearly when the engine cannot analyse in time', () async {
      final c = await container();
      final scripted = ScriptedEngine(c.read(_refProvider), (_) => null);
      await expectLater(
        prepareAiCoachRequest(scripted, position: after, currentEval: null, moves: 'e4'),
        throwsA(isA<AiCoachException>()),
      );
    });

    test('a shallow evaluation counts as missing', () async {
      final c = await container();
      final scripted = ScriptedEngine(c.read(_refProvider), (p) => cloud(p, ['e7e5'], depth: 20));
      final request = await prepareAiCoachRequest(
        scripted,
        position: after,
        currentEval: cloud(after, ['e7e5'], depth: 4),
        moves: 'e4',
      );
      expect(scripted.asked, [after.fen]);
      expect(request.evidence, contains('Engine depth: 20'));
    });
  });
}
