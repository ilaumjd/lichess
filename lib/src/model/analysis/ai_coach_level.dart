import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/binding.dart';

/// How much the coach assumes the user already knows.
///
/// Beginner and club differ only in the wording asked of the AI. Advanced also asks the engine for
/// more: more lines, a deeper search and a longer time cap, so it is the only level that can make
/// the user wait noticeably longer.
enum AiCoachLevel({required final String label, required final String description}) {
  beginner(
    label: 'Beginner',
    description:
        'Everyday language, chess terms explained, moves also described in words. '
        'Up to about 170 words.',
  ),
  club(
    label: 'Club player',
    description:
        'Normal chess terms without explaining the basics, focused on plans and tactics. '
        'Up to about 130 words.',
  ),
  advanced(
    label: 'Advanced',
    description:
        'Concise and technical, with concrete lines and evaluations. Up to about 100 words. '
        'Stockfish searches deeper and shows more lines, so the analysis can take a few seconds '
        'longer.',
  );

  /// How many engine lines are put in front of the AI.
  int get maxLines => this == advanced ? 4 : 3;

  /// How many moves of each line are put in front of the AI.
  int get maxMovesPerLine => this == advanced ? 14 : 12;

  /// The depth the engine must reach before its result is used.
  int get minDepth => this == advanced ? 14 : 12;

  /// How long the engine may search one position.
  Duration get searchTime => Duration(seconds: this == advanced ? 8 : 4);

  /// How many lines the engine is asked for, given what the device allows by default.
  int multiPv(int deviceDefault) => this == advanced ? math.max(deviceDefault, 4) : deviceDefault;

  /// The most words the AI is asked to use for a first answer.
  int get maxWords => switch (this) {
    beginner => 170,
    club => 130,
    advanced => 100,
  };

  /// The most words the AI is asked to use for a follow-up answer.
  int get maxFollowUpWords => switch (this) {
    beginner => 120,
    club => 100,
    advanced => 80,
  };

  static AiCoachLevel fromName(String? name) =>
      AiCoachLevel.values.where((level) => level.name == name).firstOrNull ?? beginner;
}

const aiCoachLevelStorageKey = 'aiCoach.level';

/// The level the user chose, kept in the app's preferences. Defaults to [AiCoachLevel.beginner].
final aiCoachLevelProvider = NotifierProvider<AiCoachLevelNotifier, AiCoachLevel>(
  AiCoachLevelNotifier.new,
);

class AiCoachLevelNotifier() extends Notifier<AiCoachLevel> {
  @override
  AiCoachLevel build() => AiCoachLevel.fromName(
    LichessBinding.instance.sharedPreferences.getString(aiCoachLevelStorageKey),
  );

  /// Saves [level]. The state changes only once the write succeeded.
  Future<void> set(AiCoachLevel level) async {
    await LichessBinding.instance.sharedPreferences.setString(aiCoachLevelStorageKey, level.name);
    state = level;
  }
}
