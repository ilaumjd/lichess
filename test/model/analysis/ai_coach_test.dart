import 'dart:convert';

import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';
import 'package:lichess_mobile/src/model/engine/engine_utils.dart';

void main() {
  const evaluation = CloudEval(
    position: Chess.initial,
    depth: 16,
    nodes: 1000,
    pvs: IListConst([
      PvData(moves: IListConst(['e2e4', 'e7e5', 'g1f3']), cp: 24),
    ]),
  );

  test('captures legal SAN lines and explicitly labels White score perspective', () {
    final request = makeAiCoachRequest(Chess.initial, evaluation, '');
    final evidence = request.evidence;
    expect(evidence, contains(Chess.initial.fen));
    expect(evidence, contains('e4 e5 Nf3'));
    expect(evidence, contains('score +0.2'));
    expect(evidence, contains('Facts computed by the app'));
    expect(evidence, contains('Task: explain this position.'));
    expect(request.allowedMoves, containsAll(['e4', 'e5', 'Nf3']));
    expect(evidence, contains("White's perspective"));
    expect(evidence, contains('Engine depth: 16'));
  });

  test('requires engine evidence', () {
    expect(() => makeAiCoachRequest(Chess.initial, null, ''), throwsA(isA<AiCoachException>()));
  });

  test('rejects shallow and stale evaluations', () {
    expect(
      () => makeAiCoachRequest(Chess.initial, evaluation.copyWith(depth: 8), ''),
      throwsA(isA<AiCoachException>()),
    );
    expect(
      () => makeAiCoachRequest(Chess.initial.play(Move.parse('e2e4')!), evaluation, 'e4'),
      throwsA(isA<AiCoachException>()),
    );
  });

  test('rejects illegal engine moves', () {
    expect(
      () => makeAiCoachRequest(
        Chess.initial,
        evaluation.copyWith(
          pvs: const IListConst([
            PvData(moves: IListConst(['e2e5']), cp: 24),
          ]),
        ),
        '',
      ),
      throwsA(isA<AiCoachException>()),
    );
  });

  test('posts only to OpenAI, uses beginner prompt, and caches repeated evidence', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      expect(request.url.toString(), 'https://api.openai.com/v1/chat/completions');
      expect(request.headers['Authorization'], 'Bearer fake-test-key');
      expect(request.headers.keys, isNot(contains('Cookie')));
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['model'], 'gpt-4o-mini');
      expect(request.body, contains('beginner'));
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'Move the pawn to control the centre.'},
            },
          ],
        }),
        200,
      );
    });
    addTearDown(client.close);
    final coach = AiCoach(client);
    final evidence = makeAiCoachRequest(Chess.initial, evaluation, '').evidence;
    for (var i = 0; i < 2; i++) {
      expect(
        await coach.explain(apiKey: 'fake-test-key', model: 'gpt-4o-mini', evidence: evidence),
        'Move the pawn to control the centre.',
      );
    }
    expect(calls, 1);
    coach.clearCache();
    await coach.explain(apiKey: 'fake-test-key', model: 'gpt-4o-mini', evidence: evidence);
    expect(calls, 2);
  });

  for (final status in [401, 429, 500]) {
    test('HTTP $status is safe and does not disclose response data', () async {
      final client = MockClient(
        (request) async => http.Response('secret provider response', status),
      );
      addTearDown(client.close);
      await expectLater(
        AiCoach(client).explain(apiKey: 'fake-test-key', model: 'model', evidence: 'position'),
        throwsA(
          isA<AiCoachException>().having((e) => e.message, 'message', isNot(contains('secret'))),
        ),
      );
    });
  }

  test('missing settings do not issue a request', () async {
    final client = MockClient((_) async => fail('Unexpected API request'));
    addTearDown(client.close);
    await expectLater(
      AiCoach(client).explain(apiKey: '', model: 'model', evidence: 'position'),
      throwsA(isA<AiCoachException>()),
    );
  });

  test('malformed successful response is reported safely', () async {
    final client = MockClient((_) async => http.Response('{"choices":[]}', 200));
    addTearDown(client.close);
    await expectLater(
      AiCoach(client).explain(apiKey: 'fake-test-key', model: 'model', evidence: 'position'),
      throwsA(isA<AiCoachException>()),
    );
  });

  test('retries once when the answer names a move that was not supplied, then verifies', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final messages = body['messages'] as List<dynamic>;
      final text = calls == 1 ? 'Play Qh5 to attack right away.' : 'Play Nf3 to develop a knight.';
      if (calls == 2) {
        expect(messages.length, 4);
        expect(jsonEncode(messages.last), contains('Qh5'));
      }
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': text},
            },
          ],
        }),
        200,
      );
    });
    addTearDown(client.close);
    final request = makeAiCoachRequest(Chess.initial, evaluation, '');
    final answer = await AiCoach(client).explain(
      apiKey: 'fake-test-key',
      model: 'model',
      evidence: request.evidence,
      allowedMoves: request.allowedMoves,
    );
    expect(calls, 2);
    expect(answer, contains('Play Nf3'));
    expect(answer, contains('Moves checked against'));
  });

  test('warns visibly when moves still cannot be verified after one retry', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'Play Qh5 now.'},
            },
          ],
        }),
        200,
      );
    });
    addTearDown(client.close);
    final request = makeAiCoachRequest(Chess.initial, evaluation, '');
    final answer = await AiCoach(client).explain(
      apiKey: 'fake-test-key',
      model: 'model',
      evidence: request.evidence,
      allowedMoves: request.allowedMoves,
    );
    expect(calls, 2);
    expect(answer, contains('Could not verify'));
    expect(answer, contains('Qh5'));
  });

  test('answers without move names get no verification footer and no retry', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'Develop your pieces and keep the king safe.'},
            },
          ],
        }),
        200,
      );
    });
    addTearDown(client.close);
    final request = makeAiCoachRequest(Chess.initial, evaluation, '');
    final answer = await AiCoach(client).explain(
      apiKey: 'fake-test-key',
      model: 'model',
      evidence: request.evidence,
      allowedMoves: request.allowedMoves,
    );
    expect(calls, 1);
    expect(answer, isNot(contains('Moves checked')));
    expect(answer, isNot(contains('Could not verify')));
  });

  group('threat information', () {
    // Start position with White to move: the threat position is the same board with Black to move.
    final threatPosition = threatModePosition(Chess.initial);
    CloudEval threatEval({
      int depth = 12,
      Position? at,
      List<String> pv = const ['e7e5', 'g1f3'],
    }) => CloudEval(
      position: at ?? threatPosition,
      depth: depth,
      nodes: 100,
      pvs: IList([PvData(moves: IList(pv), cp: -10)]),
    );

    test('is described as what the other side threatens, with its moves allowed', () {
      final request = makeAiCoachRequest(Chess.initial, evaluation, '', threat: threatEval());
      expect(request.evidence, contains('Threat: if it were Black to move instead'));
      expect(request.evidence, contains('what Black is threatening'));
      expect(request.evidence, contains('e5 Nf3'));
      expect(request.allowedMoves, containsAll(['e5', 'Nf3']));
    });

    test('is left out when absent, too shallow, for another position, or impossible', () {
      expect(makeAiCoachRequest(Chess.initial, evaluation, '').evidence, isNot(contains('Threat')));
      for (final bad in [threatEval(depth: 5), threatEval(at: Chess.initial)]) {
        expect(
          makeAiCoachRequest(Chess.initial, evaluation, '', threat: bad).evidence,
          isNot(contains('Threat')),
        );
      }
    });

    test('is never offered when the side to move is in check', () {
      final inCheck = Chess.fromSetup(Setup.parseFen('4k3/8/8/8/8/8/4q3/4K3 w - - 0 1'));
      expect(canAiCoachShowThreat(inCheck), isFalse);
      expect(canAiCoachShowThreat(Chess.initial), isTrue);
    });

    test('is never offered when the other side would be stalemated', () {
      // With Black to move this board is stalemate, so with White to move there is no threat to ask.
      final position = Chess.fromSetup(Setup.parseFen('7k/5Q2/6K1/8/8/8/8/8 w - - 0 1'));
      expect(position.isCheck, isFalse);
      expect(threatModePosition(position).isStalemate, isTrue);
      expect(canAiCoachShowThreat(position), isFalse);
    });

    test('the prompt tells the model how to read threat lines', () {
      expect(aiCoachSystemPrompt, contains('Threat'));
      expect(aiCoachSystemPrompt, contains('never as moves that were played'));
    });
  });
}
