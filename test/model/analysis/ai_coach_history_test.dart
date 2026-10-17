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
}

class FailingHistoryStorage() extends FakeSharedPreferences {
  final failWrites = ValueNotifier(true);
  @override
  Future<bool> setString(String key, String value) {
    if (failWrites.value) throw StateError('disk unavailable');
    return super.setString(key, value);
  }
}
