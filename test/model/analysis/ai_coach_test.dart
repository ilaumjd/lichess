import 'dart:convert';

import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_answer.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_level.dart';
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

  group('follow-up questions', () {
    Map<String, dynamic>? lastBody;
    var calls = 0;

    AiCoach coachReplying(String text) {
      calls = 0;
      final client = MockClient((request) async {
        calls++;
        lastBody = jsonDecode(request.body) as Map<String, dynamic>;
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
      return AiCoach(client);
    }

    List<Map<String, dynamic>> sent() =>
        (lastBody!['messages'] as List<dynamic>).cast<Map<String, dynamic>>();

    test('sends evidence, the first answer without the app note, and the question', () async {
      final coach = coachReplying('Because the knight attacks the centre.');
      final answer = await coach.followUp(
        apiKey: 'fake-test-key',
        model: 'model',
        evidence: 'EVIDENCE',
        firstAnswer: "Play Nf3.\n\n✓ Moves checked against Stockfish's lines.",
        previous: const [],
        question: 'Why?',
      );
      expect(answer, 'Because the knight attacks the centre.');
      final messages = sent();
      expect(messages.map((m) => m['role']), ['system', 'user', 'assistant', 'user']);
      expect(messages.first['content'], contains(aiCoachFollowUpPrompt));
      expect(messages[1]['content'], 'EVIDENCE');
      expect(messages[2]['content'], 'Play Nf3.');
      expect(messages[2]['content'], isNot(contains('Moves checked')));
      expect(messages.last['content'], 'Why?');
    });

    test('sends only the most recent turns', () async {
      final coach = coachReplying('Fine.');
      final previous = [for (var i = 0; i < 9; i++) (question: 'q$i', answer: 'a$i')];
      await coach.followUp(
        apiKey: 'fake-test-key',
        model: 'model',
        evidence: 'EVIDENCE',
        firstAnswer: 'first',
        previous: previous,
        question: 'latest',
      );
      final contents = sent().map((m) => m['content']).toList();
      expect(contents, isNot(contains('q0')));
      expect(contents, isNot(contains('q2')));
      expect(contents, containsAll(['q3', 'a3', 'q8', 'a8', 'latest']));
      // system + evidence + first answer + 6 turns * 2 + the question.
      expect(sent().length, 3 + kAiCoachContextTurns * 2 + 1);
    });

    test('accepts a move the user named, but still checks everything else', () async {
      final coach = coachReplying('I have no engine evidence about Nc3, but Qh5 is not good.');
      final answer = await coach.followUp(
        apiKey: 'fake-test-key',
        model: 'model',
        evidence: 'EVIDENCE',
        firstAnswer: 'first',
        previous: const [],
        question: 'Why not Nc3?',
        allowedMoves: {'Nf3'}.toISet(),
      );
      // Qh5 was neither supplied nor named by the user, so it is flagged (after one retry).
      expect(calls, 2);
      expect(answer, contains('Could not verify'));
      expect(answer, contains('Qh5'));
      expect(answer, isNot(contains("verify these moves against Stockfish's lines: Nc3")));
    });

    test('a user-named move alone does not trigger a warning or retry', () async {
      final coach = coachReplying('There is no engine evidence about Nc3.');
      final answer = await coach.followUp(
        apiKey: 'fake-test-key',
        model: 'model',
        evidence: 'EVIDENCE',
        firstAnswer: 'first',
        previous: const [],
        question: 'Why not Nc3?',
        allowedMoves: {'Nf3'}.toISet(),
      );
      expect(calls, 1);
      expect(answer, isNot(contains('Could not verify')));
    });

    test('rejects empty, oversize and unconfigured questions without a request', () {
      final coach = coachReplying('never used');
      Future<String> ask({String key = 'fake-test-key', String question = 'ok'}) => coach.followUp(
        apiKey: key,
        model: 'model',
        evidence: 'E',
        firstAnswer: 'a',
        previous: const [],
        question: question,
      );
      expect(ask(question: '   '), throwsA(isA<AiCoachException>()));
      expect(
        ask(question: 'x' * (kAiCoachMaxQuestionLength + 1)),
        throwsA(isA<AiCoachException>()),
      );
      expect(ask(key: ''), throwsA(isA<AiCoachException>()));
      expect(calls, 0);
    });

    test('stripAiCoachNote removes only the trailing app notes', () {
      expect(stripAiCoachNote('Text.\n\n✓ Moves checked.'), 'Text.');
      expect(stripAiCoachNote('Text.\n\n⚠ Could not verify: Qh5.'), 'Text.');
      expect(stripAiCoachNote('Plain answer.'), 'Plain answer.');
      expect(stripAiCoachNote('A ✓ inside.'), 'A ✓ inside.');
    });
  });

  group('why not this move', () {
    test('requests carry the position of the decision and its evaluation', () {
      final request = makeAiCoachRequest(Chess.initial, evaluation, '');
      expect(request.decision, isNotNull);
      expect(request.decision!.position.fen, Chess.initial.fen);
      expect(request.decision!.eval.depth, 16);
    });

    test('extra evidence is attached to the question, and its moves are allowed', () async {
      Map<String, dynamic>? body;
      final client = MockClient((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'Nf3 is slower than the engine move e4.'},
              },
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);
      final answer = await AiCoach(client).followUp(
        apiKey: 'fake-test-key',
        model: 'model',
        evidence: 'EVIDENCE',
        firstAnswer: 'first',
        previous: const [],
        question: 'Why not Nf3?',
        allowedMoves: {'e4'}.toISet(),
        extraEvidence: 'COMPARISON DATA',
        extraMoves: {'Nf3'}.toISet(),
      );
      final messages = (body!['messages'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(messages.last['content'], startsWith('Why not Nf3?'));
      expect(messages.last['content'], contains('Extra engine evidence for this question:'));
      expect(messages.last['content'], contains('COMPARISON DATA'));
      expect(messages.first['content'], contains('Extra engine evidence'));
      expect(answer, isNot(contains('Could not verify')));
    });

    test('without extra evidence the question is sent unchanged', () async {
      Map<String, dynamic>? body;
      final client = MockClient((request) async {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'Fine.'},
              },
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);
      await AiCoach(client).followUp(
        apiKey: 'fake-test-key',
        model: 'model',
        evidence: 'EVIDENCE',
        firstAnswer: 'first',
        previous: const [],
        question: 'Why?',
      );
      final messages = (body!['messages'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(messages.last['content'], 'Why?');
    });
  });

  group("the user's side", () {
    test('is named in the evidence and the board is turned to it', () {
      final request = makeAiCoachRequest(Chess.initial, evaluation, '', userSide: Side.black);
      expect(request.evidence, contains('The user is playing Black.'));
      expect(request.boards!.orientation, Side.black);
    });

    test('is left out, and the board follows the side to move, when it is not known', () {
      final request = makeAiCoachRequest(Chess.initial, evaluation, '');
      expect(request.evidence, isNot(contains('The user is playing')));
      expect(request.boards!.orientation, Side.white);
    });

    test('every level tells the AI how to speak about the user and the opponent', () {
      for (final level in AiCoachLevel.values) {
        final prompt = aiCoachSystemPromptFor(level);
        expect(prompt, contains('which side the user plays'));
        expect(prompt, contains('"you"'));
        expect(prompt, contains('"your opponent"'));
      }
    });

    test('the line is only there when the side is known', () {
      expect(aiCoachUserLine(null), isEmpty);
      expect(aiCoachUserLine(Side.white), 'The user is playing White.\n');
    });
  });

  group('structured answers', () {
    Map<String, dynamic> structuredReply(
      List<String> sectionTexts, {
      String headline = 'Headline.',
    }) => {
      'headline': headline,
      'sections': [
        for (var i = 0; i < sectionTexts.length; i++) {'title': 'S$i', 'text': sectionTexts[i]},
      ],
    };

    /// A client whose successive replies are [contents], and which records every request body.
    ({MockClient client, List<Map<String, dynamic>> bodies}) replying(
      List<String> contents, {
      int? failFirstWith,
    }) {
      final bodies = <Map<String, dynamic>>[];
      var i = 0;
      final client = MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        if (failFirstWith != null && bodies.length == 1) return http.Response('no', failFirstWith);
        final content = contents[(i++).clamp(0, contents.length - 1)];
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': content},
              },
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);
      return (client: client, bodies: bodies);
    }

    final request = makeAiCoachRequest(Chess.initial, evaluation, '');

    Future<String> explain(AiCoach coach, {bool withMoves = true}) => coach.explain(
      apiKey: 'k',
      model: 'm',
      evidence: request.evidence,
      allowedMoves: withMoves ? request.allowedMoves : null,
    );

    test('the request asks for the JSON schema', () async {
      final r = replying([
        jsonEncode(structuredReply(['Develop.'])),
      ]);
      await explain(AiCoach(r.client));
      final format = r.bodies.single['response_format'] as Map<String, dynamic>;
      expect(format['type'], 'json_schema');
      final schema = format['json_schema'] as Map<String, dynamic>;
      expect(schema['strict'], true);
      expect(schema['schema'], aiCoachAnswerSchema);
    });

    test('the instructions ask for JSON and no Markdown', () async {
      final r = replying([
        jsonEncode(structuredReply(['Develop.'])),
      ]);
      await explain(AiCoach(r.client));
      final system = (r.bodies.single['messages'] as List<dynamic>).first as Map<String, dynamic>;
      expect(system['content'], contains('Reply as JSON'));
      expect(system['content'], contains('no Markdown'));
    });

    test('a structured reply is saved as an answer with the check inside it', () async {
      final r = replying([
        jsonEncode(structuredReply(['Nf3 develops a knight.'])),
      ]);
      final stored = await explain(AiCoach(r.client));
      final answer = AiCoachAnswer.tryParse(stored)!;
      expect(answer.headline, 'Headline.');
      expect(answer.check, AiCoachCheckResult.verified);
      expect(stored, isNot(contains('✓')));
    });

    test('an answer that names no moves has no check at all', () async {
      final r = replying([
        jsonEncode(structuredReply(['Develop your pieces.'])),
      ]);
      expect(AiCoachAnswer.tryParse(await explain(AiCoach(r.client)))!.check, isNull);
    });

    test('a move that was not supplied triggers one retry, and is flagged if it stays', () async {
      final bad = jsonEncode(structuredReply(['Qh5 attacks.']));
      final r = replying([bad, bad]);
      final answer = AiCoachAnswer.tryParse(await explain(AiCoach(r.client)))!;
      expect(r.bodies, hasLength(2));
      expect(answer.check, AiCoachCheckResult.unverified);
      expect(answer.unverified, ['Qh5']);
    });

    test('the retry can fix it', () async {
      final r = replying([
        jsonEncode(structuredReply(['Qh5 attacks.'])),
        jsonEncode(structuredReply(['Nf3 develops.'])),
      ]);
      final answer = AiCoachAnswer.tryParse(await explain(AiCoach(r.client)))!;
      expect(r.bodies, hasLength(2));
      expect(answer.check, AiCoachCheckResult.verified);
      expect(answer.sections.single.text, 'Nf3 develops.');
      // The retry keeps the schema, and shows the model its own answer.
      expect(r.bodies[1]['response_format'], isNotNull);
      expect(jsonEncode(r.bodies[1]['messages']), contains('Qh5'));
    });

    test('moves in the headline are checked too', () async {
      final bad = jsonEncode(structuredReply(['Fine.'], headline: 'Qh5 wins.'));
      final r = replying([bad, bad]);
      expect(AiCoachAnswer.tryParse(await explain(AiCoach(r.client)))!.unverified, ['Qh5']);
    });

    test('without moves to check the answer is stored as it came', () async {
      final r = replying([
        jsonEncode(structuredReply(['Qh5 attacks.'])),
      ]);
      final answer = AiCoachAnswer.tryParse(await explain(AiCoach(r.client), withMoves: false))!;
      expect(r.bodies, hasLength(1));
      expect(answer.check, isNull);
    });

    test('a model that rejects the schema is asked again without it, and still works', () async {
      final r = replying(['Nf3 develops a knight.'], failFirstWith: 400);
      final stored = await explain(AiCoach(r.client));
      expect(r.bodies, hasLength(2));
      expect(r.bodies[0]['response_format'], isNotNull);
      expect(r.bodies[1]['response_format'], isNull);
      // Plain text is handled the way it always was.
      expect(AiCoachAnswer.tryParse(stored), isNull);
      expect(stored, contains('Nf3 develops a knight.'));
      expect(stored, contains('Moves checked'));
    });

    test('a model that ignores the schema and answers in plain text still works', () async {
      final r = replying(['Qh5 attacks.']);
      final stored = await explain(AiCoach(r.client));
      expect(AiCoachAnswer.tryParse(stored), isNull);
      expect(stored, contains('Could not verify'));
    });

    test('other errors are still reported, not retried', () async {
      final r = replying(['x'], failFirstWith: 500);
      await expectLater(explain(AiCoach(r.client)), throwsA(isA<AiCoachException>()));
      expect(r.bodies, hasLength(1));
    });

    test('follow-ups stay plain text, and get the first answer flattened', () async {
      final r = replying(['Because it develops.']);
      final first = AiCoachAnswer.tryParse(jsonEncode(structuredReply(['Develop.'])))!
          .withCheck(AiCoachCheckResult.verified)
          .toStored();
      final answer = await AiCoach(r.client).followUp(
        apiKey: 'k',
        model: 'm',
        evidence: 'E',
        firstAnswer: first,
        previous: const [],
        question: 'Why?',
      );
      expect(answer, 'Because it develops.');
      expect(r.bodies.single['response_format'], isNull);
      final messages = (r.bodies.single['messages'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(messages.first['content'], isNot(contains('Reply as JSON')));
      expect(messages.first['content'], contains('plain text only'));
      expect(messages[2]['content'], 'Headline.\nS0: Develop.');
    });
  });
}
