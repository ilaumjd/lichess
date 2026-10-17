import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_history.dart';

import '../../binding.dart';

void main() {
  setUp(() {
    TestLichessBinding.ensureInitialized();
    addTearDown(testBinding.reset);
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  test('history survives a fresh provider container without an API key', () async {
    final first = makeContainer();
    await first
        .read(aiCoachHistoryProvider.notifier)
        .save(model: 'model', evidence: 'FEN: position', explanation: 'Protect your king.');
    final second = makeContainer();
    final entry = second.read(aiCoachHistoryProvider).single;
    expect(entry.model, 'model');
    expect(entry.evidence, 'FEN: position');
    expect(entry.explanation, 'Protect your king.');
    expect(entry.savedAt.isUtc, isTrue);
    expect(
      second.read(aiCoachHistoryProvider.notifier).find(model: 'model', evidence: 'FEN: position'),
      'Protect your king.',
    );
    final data = jsonDecode(
      testBinding.sharedPreferences.getString(aiCoachHistoryStorageKey)!,
    ) as List<dynamic>;
    expect((data.single as Map<String, dynamic>).keys.toSet(), {
      'savedAt',
      'model',
      'evidence',
      'explanation',
      'followUps',
    });
  });

  test('keeps newest first and deduplicates exact evidence plus model', () async {
    final container = makeContainer();
    final history = container.read(aiCoachHistoryProvider.notifier);
    await history.save(model: 'one', evidence: 'a', explanation: 'old');
    await history.save(model: 'two', evidence: 'a', explanation: 'other model');
    await history.save(model: 'one', evidence: 'a', explanation: 'new');
    final entries = container.read(aiCoachHistoryProvider);
    expect(entries.length, 2);
    expect(entries.first.explanation, 'new');
    expect(entries.last.model, 'two');
  });

  test('concurrent saves are serialized and history is bounded to 100 entries', () async {
    final container = makeContainer();
    final history = container.read(aiCoachHistoryProvider.notifier);
    await Future.wait([
      for (var i = 0; i < 105; i++)
        history.save(model: 'model', evidence: '$i', explanation: 'note $i'),
    ]);
    final restored = makeContainer().read(aiCoachHistoryProvider);
    expect(restored.length, aiCoachHistoryLimit);
    expect(restored.first.evidence, '104');
    expect(restored.last.evidence, '5');
  });

  test('delete and clear persist across fresh containers', () async {
    final container = makeContainer();
    final history = container.read(aiCoachHistoryProvider.notifier);
    await history.save(model: 'model', evidence: 'a', explanation: 'a');
    await history.save(model: 'model', evidence: 'b', explanation: 'b');
    await history.delete(container.read(aiCoachHistoryProvider).first);
    expect(makeContainer().read(aiCoachHistoryProvider).single.evidence, 'a');
    await history.clear();
    expect(makeContainer().read(aiCoachHistoryProvider), isEmpty);
  });

  test('malformed record is skipped without hiding valid entries', () async {
    await testBinding.setInitialSharedPreferencesValues({
      aiCoachHistoryStorageKey: jsonEncode([
        {'broken': 'entry'},
        {
          'savedAt': '2026-10-17T00:00:00Z',
          'model': 'model',
          'evidence': 'fen',
          'explanation': 'note',
        },
      ]),
    });
    expect(makeContainer().read(aiCoachHistoryProvider).single.explanation, 'note');
  });

  test('storage failure does not publish unsaved history and can be retried', () async {
    final storage = FailingHistoryStorage();
    addTearDown(storage.failWrites.dispose);
    testBinding.sharedPreferences = storage;
    final container = makeContainer();
    final history = container.read(aiCoachHistoryProvider.notifier);
    await expectLater(
      history.save(model: 'model', evidence: 'fen', explanation: 'note'),
      throwsStateError,
    );
    expect(container.read(aiCoachHistoryProvider), isEmpty);
    storage.failWrites.value = false;
    await history.save(model: 'model', evidence: 'fen', explanation: 'note');
    expect(makeContainer().read(aiCoachHistoryProvider).single.explanation, 'note');
  });

  test('follow-ups are saved with their explanation and survive a fresh container', () async {
    final container = makeContainer();
    final history = container.read(aiCoachHistoryProvider.notifier);
    await history.save(model: 'model', evidence: 'fen', explanation: 'first');
    await history.addFollowUp(model: 'model', evidence: 'fen', question: 'why?', answer: 'because');
    await history.addFollowUp(model: 'model', evidence: 'fen', question: 'more?', answer: 'sure');
    final restored = makeContainer().read(aiCoachHistoryProvider).single;
    expect(restored.explanation, 'first');
    expect(restored.followUps.map((f) => f.question), ['why?', 'more?']);
    expect(restored.followUps.map((f) => f.answer), ['because', 'sure']);
    expect(
      makeContainer()
          .read(aiCoachHistoryProvider.notifier)
          .entryFor(model: 'model', evidence: 'fen'),
      isNotNull,
    );
  });

  test('a follow-up only goes to the entry for that model and evidence', () async {
    final container = makeContainer();
    final history = container.read(aiCoachHistoryProvider.notifier);
    await history.save(model: 'm1', evidence: 'a', explanation: 'one');
    await history.save(model: 'm1', evidence: 'b', explanation: 'two');
    await history.addFollowUp(model: 'm1', evidence: 'a', question: 'q', answer: 'x');
    final entries = container.read(aiCoachHistoryProvider);
    expect(entries.firstWhere((e) => e.evidence == 'a').followUps, hasLength(1));
    expect(entries.firstWhere((e) => e.evidence == 'b').followUps, isEmpty);
  });

  test('a follow-up for an explanation that is not saved changes nothing', () async {
    final container = makeContainer();
    final history = container.read(aiCoachHistoryProvider.notifier);
    await history.addFollowUp(model: 'm', evidence: 'missing', question: 'q', answer: 'a');
    expect(container.read(aiCoachHistoryProvider), isEmpty);
  });

  test('entries saved before follow-ups existed still load, with none', () async {
    await testBinding.setInitialSharedPreferencesValues({
      aiCoachHistoryStorageKey: jsonEncode([
        {'savedAt': '2026-10-17T00:00:00Z', 'model': 'm', 'evidence': 'e', 'explanation': 'old'},
      ]),
    });
    final entry = makeContainer().read(aiCoachHistoryProvider).single;
    expect(entry.explanation, 'old');
    expect(entry.followUps, isEmpty);
  });

  test('a malformed follow-up is skipped without hiding the explanation or the rest', () async {
    await testBinding.setInitialSharedPreferencesValues({
      aiCoachHistoryStorageKey: jsonEncode([
        {
          'savedAt': '2026-10-17T00:00:00Z',
          'model': 'm',
          'evidence': 'e',
          'explanation': 'kept',
          'followUps': [
            {'question': 'only a question'},
            {'question': 'good', 'answer': 'fine'},
          ],
        },
      ]),
    });
    final entry = makeContainer().read(aiCoachHistoryProvider).single;
    expect(entry.explanation, 'kept');
    expect(entry.followUps.single.question, 'good');
  });

  test('saving the same explanation again starts a fresh conversation', () async {
    final container = makeContainer();
    final history = container.read(aiCoachHistoryProvider.notifier);
    await history.save(model: 'm', evidence: 'e', explanation: 'first');
    await history.addFollowUp(model: 'm', evidence: 'e', question: 'q', answer: 'a');
    await history.save(model: 'm', evidence: 'e', explanation: 'second');
    expect(container.read(aiCoachHistoryProvider).single.followUps, isEmpty);
  });
}

class FailingHistoryStorage() extends FakeSharedPreferences {
  final failWrites = ValueNotifier(true);
  @override
  Future<bool> setString(String key, String value) {
    if (failWrites.value) throw StateError('disk unavailable');
    return super.setString(key, value);
  }
}
