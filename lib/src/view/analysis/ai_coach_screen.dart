import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/db/secure_storage.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_alternative.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_engine.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_history.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_input.dart';
import 'package:lichess_mobile/src/utils/navigation.dart';
import 'package:lichess_mobile/src/view/analysis/ai_coach_history_screen.dart';
import 'package:lichess_mobile/src/view/settings/ai_coach_settings_screen.dart';
import 'package:lichess_mobile/src/widgets/platform.dart';
import 'package:material_ui/material_ui.dart';

/// Builds the request to explain, running Stockfish on demand where an evaluation is missing.
typedef AiCoachPrepare = Future<AiCoachRequest> Function(AiCoachEngine engine);

/// Prepares the request for a parsed FEN or game: the last move when there is one, else the
/// position. Stockfish runs on demand for whatever has no evaluation yet.
AiCoachPrepare aiCoachPrepareFor(AiCoachInput input) =>
    (engine) => prepareAiCoachRequest(
      engine,
      position: input.position,
      currentEval: null,
      moves: input.moves,
      move: input.lastMove,
    );

/// Opens the coach on the last move of the game in [pgn] (standard chess only), for the result
/// dialogs. Shows a message instead when the game cannot be read.
void openAiCoachForPgn(BuildContext context, String pgn) {
  final AiCoachInput input;
  try {
    input = parseAiCoachInput(pgn);
  } on AiCoachException catch (error) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    return;
  }
  Navigator.of(context).push(AiCoachScreen.buildRoute(prepare: aiCoachPrepareFor(input)));
}

/// Explains a position or move.
///
/// The screen first analyses the position on the device (nothing leaves the phone), then waits
/// for the user to tap Explain before anything is sent to OpenAI. The position is captured when
/// the screen is opened, so a board that changes meanwhile cannot change what is explained.
class const AiCoachScreen({required final AiCoachPrepare prepare, super.key})
    extends ConsumerStatefulWidget {
  static Route<void> buildRoute({required AiCoachPrepare prepare}) =>
      buildScreenRoute(screen: AiCoachScreen(prepare: prepare));

  @override
  ConsumerState<AiCoachScreen> createState() => _AiCoachScreenState();
}

class _AiCoachScreenState() extends ConsumerState<AiCoachScreen> {
  AiCoachRequest? _request;
  bool _preparing = true;
  bool _busy = false;
  String? _answer;
  String? _error;

  /// The model the shown explanation was made with, which keys its saved conversation.
  String? _model;
  IList<AiCoachFollowUp> _followUps = const IListConst([]);
  final _questionController = TextEditingController();
  final _moveController = TextEditingController();
  bool _asking = false;

  /// Whether Stockfish is analysing a move the user asked about.
  bool _analysingMove = false;
  String? _followUpError;

  @override
  void dispose() {
    _questionController.dispose();
    _moveController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Keeps the engine service alive for as long as the screen is.
    ref.listenManual(aiCoachEngineProvider, (_, _) {});
    // Not from initState: starting the engine changes providers, which is not allowed while the
    // widget tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prepare();
    });
  }

  Future<void> _prepare() async {
    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      final request = await widget.prepare(ref.read(aiCoachEngineProvider));
      if (mounted) {
        setState(() {
          _request = request;
          _preparing = false;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _preparing = false;
          _error = error is AiCoachException
              ? error.message
              : 'Stockfish could not analyse this position. Please try again.';
        });
      }
    }
  }

  Future<void> _explain(AiCoachRequest request) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final model =
          await SecureStorage.instance.read(key: aiCoachModelStorage) ?? aiCoachDefaultModel;
      if (!mounted) return;
      final history = ref.read(aiCoachHistoryProvider.notifier);
      final saved = history.entryFor(model: model, evidence: request.evidence);
      if (saved != null) {
        setState(() {
          _model = model;
          _answer = saved.explanation;
          _followUps = saved.followUps;
          _busy = false;
        });
        return;
      }
      final key = await SecureStorage.instance.read(key: aiCoachKeyStorage) ?? '';
      if (!mounted) return;
      final coach = ref.read(aiCoachProvider);
      final answer = await coach.explain(
        apiKey: key,
        model: model,
        evidence: request.evidence,
        allowedMoves: request.allowedMoves,
      );
      String? saveError;
      try {
        await history.save(model: model, evidence: request.evidence, explanation: answer);
      } on Object {
        saveError = 'Explanation received, but it could not be saved on this device.';
      }
      if (mounted) {
        setState(() {
          _model = model;
          _answer = answer;
          _followUps = const IListConst([]);
          _error = saveError;
          _busy = false;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error is AiCoachException ? error.message : 'Could not read AI coach settings.';
        });
      }
    }
  }

  /// "Why not this move?": evaluates the move the user typed, then asks the coach to compare it
  /// with the best one using that evidence.
  Future<void> _compare(AiCoachRequest request) async {
    final decision = request.decision;
    if (decision == null || _asking || _analysingMove) return;
    setState(() {
      _analysingMove = true;
      _followUpError = null;
    });
    final AiCoachAlternative alternative;
    try {
      alternative = await prepareAiCoachAlternative(
        ref.read(aiCoachEngineProvider),
        decision: decision,
        input: _moveController.text,
      );
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _analysingMove = false;
          _followUpError = error is AiCoachException
              ? error.message
              : 'Stockfish could not analyse that move. Please try again.';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _analysingMove = false);
    await _ask(
      request,
      alternative.question,
      extraEvidence: alternative.evidence,
      extraMoves: alternative.moves,
    );
    if (mounted && _followUpError == null) _moveController.clear();
  }

  Future<void> _ask(
    AiCoachRequest request,
    String question, {
    String? extraEvidence,
    ISet<String>? extraMoves,
  }) async {
    final firstAnswer = _answer;
    final model = _model;
    if (firstAnswer == null || model == null || _asking) return;
    setState(() {
      _asking = true;
      _followUpError = null;
    });
    try {
      final key = await SecureStorage.instance.read(key: aiCoachKeyStorage) ?? '';
      if (!mounted) return;
      final answer = await ref
          .read(aiCoachProvider)
          .followUp(
            apiKey: key,
            model: model,
            evidence: request.evidence,
            firstAnswer: firstAnswer,
            previous: _followUps.unlock,
            question: question,
            allowedMoves: request.allowedMoves,
            extraEvidence: extraEvidence,
            extraMoves: extraMoves,
          );
      String? warning;
      try {
        await ref
            .read(aiCoachHistoryProvider.notifier)
            .addFollowUp(
              model: model,
              evidence: request.evidence,
              question: question.trim(),
              answer: answer,
            );
      } on Object {
        warning = 'Answer received, but it could not be saved on this device.';
      }
      if (mounted) {
        setState(() {
          _followUps = _followUps.add((question: question.trim(), answer: answer));
          _questionController.clear();
          _followUpError = warning;
          _asking = false;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _asking = false;
          _followUpError = error is AiCoachException
              ? error.message
              : 'Could not read AI coach settings.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = _request;
    return PlatformScaffold(
      appBar: const PlatformAppBar(title: Text('Explain position')),
      body: ListView(
        padding: const EdgeInsets.all(16).add(MediaQuery.paddingOf(context)),
        children: [
          const Text('Beginner coach', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          const Text(
            'Stockfish analyses the position on your phone first. Tapping Explain then sends the '
            'position and engine evidence directly to OpenAI using your API key. Charges may '
            'apply. Nothing is sent automatically. Stockfish supplies the moves; the AI tries to '
            'explain them and may make mistakes. Successful explanations are saved on this '
            'device. If this exact evidence and model are already saved, the answer is opened '
            'without an API request.',
          ),
          const SizedBox(height: 12),
          if (_preparing)
            Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                const Expanded(child: Text('Analysing the position with Stockfish…')),
                TextButton(
                  onPressed: () {
                    ref.read(aiCoachEngineProvider).cancel();
                    Navigator.of(context).pop();
                  },
                  child: const Text('Cancel'),
                ),
              ],
            ),
          if (request != null)
            ExpansionTile(
              title: const Text('Position and engine evidence'),
              children: [
                Padding(padding: const EdgeInsets.all(12), child: SelectableText(request.evidence)),
              ],
            ),
          TextButton(
            onPressed: _busy
                ? null
                : () => Navigator.of(context).push(AiCoachSettingsScreen.buildRoute()),
            child: const Text('AI coach settings'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).push(AiCoachHistoryScreen.buildRoute()),
            child: const Text('Explanation history'),
          ),
          if (request != null)
            FilledButton(
              onPressed: _busy ? null : () => _explain(request),
              child: Text(_answer == null ? 'Explain' : 'Show saved explanation'),
            ),
          if (_error != null && request == null && !_preparing)
            FilledButton(onPressed: _prepare, child: const Text('Try again')),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null)
            Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(_error!)),
          if (_answer != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: SelectableText(_answer!),
            ),
          for (final turn in _followUps) ...[
            Text('You: ${turn.question}', style: const TextStyle(fontWeight: FontWeight.bold)),
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 16),
              child: SelectableText(turn.answer),
            ),
          ],
          if (_answer != null && request != null)
            if (_followUps.length >= kAiCoachMaxFollowUps)
              const Text(
                'That is the most follow-up questions for one explanation. Ask about another '
                'move to keep going.',
              )
            else ...[
              Wrap(
                spacing: 8,
                children: [
                  for (final quick in const ['Explain simpler', 'What should I do differently?'])
                    ActionChip(
                      label: Text(quick),
                      onPressed: _asking || _analysingMove ? null : () => _ask(request, quick),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _questionController,
                enabled: !_asking && !_analysingMove,
                minLines: 1,
                maxLines: 4,
                maxLength: kAiCoachMaxQuestionLength,
                decoration: const InputDecoration(labelText: 'Ask a follow-up question'),
              ),
              FilledButton(
                onPressed: _asking || _analysingMove
                    ? null
                    : () => _ask(request, _questionController.text),
                child: const Text('Ask'),
              ),
              if (request.decision != null) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: _moveController,
                  enabled: !_asking && !_analysingMove,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: kAiCoachMaxMoveInputLength,
                  decoration: const InputDecoration(
                    labelText: 'Compare a move (for example Nf3 or e2e4)',
                  ),
                ),
                FilledButton(
                  onPressed: _asking || _analysingMove ? null : () => _compare(request),
                  child: const Text('Why not this move?'),
                ),
              ],
              if (_analysingMove)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 12),
                      Expanded(child: Text('Analysing that move with Stockfish…')),
                    ],
                  ),
                ),
              if (_asking)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (_followUpError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(_followUpError!),
                ),
            ],
        ],
      ),
    );
  }
}
