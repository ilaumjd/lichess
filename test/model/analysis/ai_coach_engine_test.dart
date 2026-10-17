import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_engine.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';
import 'package:lichess_mobile/src/model/engine/engine_utils.dart';
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
  final threatsAsked = <String>[];
  ClientEval? Function(Position position)? threatScript;

  @override
  Future<ClientEval?> evaluate(Position position, {Duration timeout = kAiCoachSearchTime}) async {
    asked.add(position.fen);
    return script(position);
  }

  @override
  Future<ClientEval?> evaluateThreat(
    Position position, {
    Duration timeout = kAiCoachThreatTime,
  }) async {
    threatsAsked.add(position.fen);
    return threatScript?.call(position);
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

  group('threat search', () {
    test('analyses the board from the other side and does not touch the real result', () async {
      final container = await makeContainer();
      container.listen(aiCoachEngineProvider, (_, _) {});
      final coach = container.read(aiCoachEngineProvider);

      final future = coach.evaluateThreat(Chess.initial);
      await settle();
      engine.emitDepthRange(toDepth: kAiCoachThreatMinDepth);
      final threat = await future;

      expect(threat, isNotNull);
      expect(threat!.depth, greaterThanOrEqualTo(kAiCoachThreatMinDepth));
      // The engine was asked about the same board with the other side to move.
      expect(engine.requestedPositions, [threatModePosition(Chess.initial).fen]);
      // And the normal evaluation of the position is still unknown.
      expect(coach.known(Chess.initial), isNull);
    });

    test('is not attempted when the side to move is in check', () async {
      final container = await makeContainer();
      container.listen(aiCoachEngineProvider, (_, _) {});
      final inCheck = Chess.fromSetup(Setup.parseFen('4k3/8/8/8/8/8/4q3/4K3 w - - 0 1'));
      final threat = await container.read(aiCoachEngineProvider).evaluateThreat(inCheck);
      expect(threat, isNull);
      expect(engine.requestedPositions, isEmpty);
    });

    test('gives up quietly when the engine says nothing in time', () async {
      final container = await makeContainer();
      container.listen(aiCoachEngineProvider, (_, _) {});
      final coach = container.read(aiCoachEngineProvider);
      final threat = await coach.evaluateThreat(
        Chess.initial,
        timeout: const Duration(milliseconds: 300),
      );
      expect(threat, isNull);
    });
  });

  group('prepareAiCoachRequest threats', () {
    const before = Chess.initial;
    final e4 = Move.parse('e2e4')!;
    final after = before.play(e4);
    final played = SanMove('e4', e4);

    CloudEval threatFor(Position p) => CloudEval(
      position: threatModePosition(p),
      depth: 12,
      nodes: 1,
      pvs: IList([
        PvData(moves: IList([if (p.turn == Side.white) 'e7e5' else 'g1f3']), cp: 0),
      ]),
    );

    test('are fetched for both sides of the move once it can be explained', () async {
      final c = await makeContainer();
      addTearDown(c.dispose);
      final scripted = ScriptedEngine(c.read(_refProvider), (_) => null)..threatScript = threatFor;
      final request = await prepareAiCoachRequest(
        scripted,
        position: after,
        currentEval: null,
        moves: 'e4',
        move: (
          before: before,
          played: played,
          evalBefore: cloud(before, ['e2e4', 'e7e5']),
          evalAfter: cloud(after, ['e7e5', 'g1f3']),
          movesBefore: '',
        ),
      );
      expect(scripted.threatsAsked, [before.fen, after.fen]);
      expect(request.evidence, contains('was threatening before the move'));
      expect(request.evidence, contains('threatens after the move'));
    });

    test('the second threat search is skipped when the first found nothing', () async {
      final c = await makeContainer();
      addTearDown(c.dispose);
      final scripted = ScriptedEngine(c.read(_refProvider), (_) => null);
      final request = await prepareAiCoachRequest(
        scripted,
        position: after,
        currentEval: null,
        moves: 'e4',
        move: (
          before: before,
          played: played,
          evalBefore: cloud(before, ['e2e4', 'e7e5']),
          evalAfter: cloud(after, ['e7e5', 'g1f3']),
          movesBefore: '',
        ),
      );
      expect(scripted.threatsAsked, [before.fen]);
      expect(request.evidence, contains('Task: explain the move that was played'));
      expect(request.evidence, isNot(contains('Threat:')));
    });

    test('are not searched when the move cannot be explained anyway', () async {
      final c = await makeContainer();
      addTearDown(c.dispose);
      final scripted = ScriptedEngine(c.read(_refProvider), (_) => null);
      await expectLater(
        prepareAiCoachRequest(
          scripted,
          position: after,
          currentEval: null,
          moves: 'e4',
          move: (
            before: before,
            played: played,
            evalBefore: null,
            evalAfter: null,
            movesBefore: '',
          ),
        ),
        throwsA(isA<AiCoachException>()),
      );
      expect(scripted.threatsAsked, isEmpty);
    });

    test('a missing threat never blocks the explanation', () async {
      final c = await makeContainer();
      addTearDown(c.dispose);
      final scripted = ScriptedEngine(c.read(_refProvider), (p) => cloud(p, ['e7e5', 'g1f3']));
      final request = await prepareAiCoachRequest(
        scripted,
        position: after,
        currentEval: cloud(after, ['e7e5', 'g1f3']),
        moves: 'e4',
      );
      expect(scripted.threatsAsked, [after.fen]);
      expect(request.evidence, isNot(contains('Threat:')));
    });
  });
}
