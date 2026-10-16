import 'dart:convert';

import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';

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
    final evidence = makeAiCoachEvidence(Chess.initial, evaluation, '');
    expect(evidence, contains(Chess.initial.fen));
    expect(evidence, contains('e4 e5 Nf3'));
    expect(evidence, contains('centipawns 24'));
    expect(evidence, contains("White's perspective"));
    expect(evidence, contains('Engine depth: 16'));
  });

  test('requires engine evidence', () {
    expect(() => makeAiCoachEvidence(Chess.initial, null, ''), throwsA(isA<AiCoachException>()));
  });

  test('rejects shallow and stale evaluations', () {
    expect(
      () => makeAiCoachEvidence(Chess.initial, evaluation.copyWith(depth: 8), ''),
      throwsA(isA<AiCoachException>()),
    );
    expect(
      () => makeAiCoachEvidence(Chess.initial.play(Move.parse('e2e4')!), evaluation, 'e4'),
      throwsA(isA<AiCoachException>()),
    );
  });

  test('rejects illegal engine moves', () {
    expect(
      () => makeAiCoachEvidence(
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
    final evidence = makeAiCoachEvidence(Chess.initial, evaluation, '');
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
}
