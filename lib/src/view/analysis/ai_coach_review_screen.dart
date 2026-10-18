import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lichess_mobile/src/db/secure_storage.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_engine.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_history.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_input.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_level.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_move.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_review.dart';
import 'package:lichess_mobile/src/utils/navigation.dart';
import 'package:lichess_mobile/src/view/analysis/ai_coach_boards_view.dart';
import 'package:lichess_mobile/src/view/analysis/ai_coach_screen.dart';
import 'package:lichess_mobile/src/view/settings/ai_coach_settings_screen.dart';
import 'package:lichess_mobile/src/widgets/platform.dart';
import 'package:material_ui/material_ui.dart';

/// Opens the review of the game in [pgn] (standard chess only), for the result dialogs. [side] is
/// the side to review (both when null). Shows a message instead when the game cannot be reviewed.
void openAiCoachReviewForPgn(BuildContext context, String pgn, {Side? side}) {
  final AiCoachInput input;
  try {
    input = parseAiCoachInput(pgn);
  } on AiCoachException catch (error) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    return;
  }
  final problem = aiCoachReviewProblem(input);
  if (problem != null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
    return;
  }
  Navigator.of(context).push(AiCoachReviewScreen.buildRoute(input: input, side: side));
}

enum _Phase() {
  setup,
  scanning,
  moments,
  explaining,
  done,
}

/// Reviews a whole game: Stockfish scans it on the device, the worst moves are picked out, and
/// only when the user agrees are they explained (and the game summarised) by the AI.
class const AiCoachReviewScreen({required final AiCoachInput input, final Side? side, super.key})
    extends ConsumerStatefulWidget {
  static Route<void> buildRoute({required AiCoachInput input, Side? side}) => buildScreenRoute(
    screen: AiCoachReviewScreen(input: input, side: side),
  );

  @override
  ConsumerState<AiCoachReviewScreen> createState() => _AiCoachReviewScreenState();
}

class _AiCoachReviewScreenState() extends ConsumerState<AiCoachReviewScreen> {
  late Side? _side = widget.side;
  _Phase _phase = _Phase.setup;
  AiCoachLevel _level = AiCoachLevel.beginner;

  int _done = 0;
  int _total = 0;
  bool _cancelRequested = false;

  late AiCoachScan _scan;
  IList<AiCoachMoment> _moments = const IListConst([]);
  AiCoachReviewStats _stats = (good: 0, inaccuracies: 0, mistakes: 0, blunders: 0);

  /// The AI's explanation of each key moment, by half-move number.
  IMap<int, String> _notes = const IMapConst({});
  String? _summary;
  String? _error;

  IList<AiCoachPly> get _plies => widget.input.plies;

  @override
  void dispose() {
    // Lets the scan stop at its next position, and the engine go.
    _cancelRequested = true;
    super.dispose();
  }

  Future<void> _startScan() async {
    final problem = aiCoachReviewProblem(widget.input);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _phase = _Phase.scanning;
      _cancelRequested = false;
      _error = null;
      _done = 0;
      _total = _plies.length + 1;
      _level = ref.read(aiCoachLevelProvider);
    });
    final scan = await scanAiCoachGame(
      ref.read(aiCoachEngineProvider),
      _plies,
      onProgress: (done, total) {
        if (mounted) {
          setState(() {
            _done = done;
            _total = total;
          });
        }
      },
      isCancelled: () => _cancelRequested || !mounted,
    );
    if (!mounted) return;
    if (scan == null) {
      setState(() => _phase = _Phase.setup);
      return;
    }
    setState(() {
      _scan = scan;
      _moments = pickKeyMoments(plies: _plies, scan: scan, side: _side);
      _stats = reviewStats(plies: _plies, scan: scan, side: _side);
      _notes = const IMapConst({});
      _summary = null;
      _phase = _Phase.moments;
    });
  }

  Future<({String key, String model})> _credentials() async {
    final model =
        await SecureStorage.instance.read(key: aiCoachModelStorage) ?? aiCoachDefaultModel;
    final key = await SecureStorage.instance.read(key: aiCoachKeyStorage) ?? '';
    return (key: key, model: model);
  }

  /// The AI's answer for [request]: the saved one when this exact evidence was explained before,
  /// else a new one, which is then saved.
  Future<String> _answer(AiCoachRequest request, String model, String key, {String? system}) async {
    final history = ref.read(aiCoachHistoryProvider.notifier);
    final saved = history.find(model: model, evidence: request.evidence);
    if (saved != null) return saved;
    final answer = await ref
        .read(aiCoachProvider)
        .explain(
          apiKey: key,
          model: model,
          evidence: request.evidence,
          allowedMoves: request.allowedMoves,
          level: _level,
          system: system,
        );
    try {
      await history.save(model: model, evidence: request.evidence, explanation: answer);
    } on Object {
      // The answer is still shown; it just is not kept.
    }
    return answer;
  }

  /// The request that explains half-move [index], built from the scan so the engine only searches
  /// further where the quick scan was too shallow.
  Future<AiCoachRequest> _momentRequest(int index) {
    final ply = _plies[index];
    final after = ply.before.playUnchecked(ply.move.move);
    return prepareAiCoachRequest(
      ref.read(aiCoachEngineProvider),
      position: after,
      currentEval: _scan[index + 1],
      moves: _plies.take(index + 1).map((p) => p.move.san).join(' '),
      move: (
        before: ply.before,
        played: ply.move,
        evalBefore: _scan[index],
        evalAfter: _scan[index + 1],
        movesBefore: _plies.take(index).map((p) => p.move.san).join(' '),
      ),
      level: _level,
      withThreats: false,
      userSide: widget.side,
    );
  }

  Future<void> _explainAll() async {
    setState(() {
      _phase = _Phase.explaining;
      _error = null;
    });
    try {
      final credentials = await _credentials();
      for (final moment in _moments) {
        if (!mounted) return;
        if (_notes.containsKey(moment.index)) continue;
        final request = await _momentRequest(moment.index);
        final answer = await _answer(request, credentials.model, credentials.key);
        if (!mounted) return;
        setState(() => _notes = _notes.add(moment.index, answer));
      }
      final summary = makeAiCoachReviewRequest(
        plies: _plies,
        moments: _moments,
        notes: _notes,
        stats: _stats,
        side: _side,
        result: widget.input.result,
        level: _level,
        userSide: widget.side,
      );
      final text = await _answer(
        summary,
        credentials.model,
        credentials.key,
        system: aiCoachReviewPromptFor(_level),
      );
      if (!mounted) return;
      setState(() {
        _summary = text;
        _phase = _Phase.done;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _phase = _Phase.moments;
          _error = error is AiCoachException ? error.message : 'Could not read AI coach settings.';
        });
      }
    }
  }

  void _openMoment(AiCoachMoment moment) {
    final ply = _plies[moment.index];
    final index = moment.index;
    Navigator.of(context).push(
      AiCoachScreen.buildRoute(
        prepare: (engine, level) => prepareAiCoachRequest(
          engine,
          position: ply.before.playUnchecked(ply.move.move),
          currentEval: _scan[index + 1],
          moves: _plies.take(index + 1).map((p) => p.move.san).join(' '),
          move: (
            before: ply.before,
            played: ply.move,
            evalBefore: _scan[index],
            evalAfter: _scan[index + 1],
            movesBefore: _plies.take(index).map((p) => p.move.san).join(' '),
          ),
          level: level,
          withThreats: false,
          userSide: widget.side,
        ),
      ),
    );
  }

  String _statsLine() {
    final judged = _stats.good + _stats.inaccuracies + _stats.mistakes + _stats.blunders;
    return '$judged moves judged: ${_stats.good} good, ${_stats.inaccuracies} inaccuracies, '
        '${_stats.mistakes} mistakes, ${_stats.blunders} blunders.';
  }

  @override
  Widget build(BuildContext context) {
    final seconds = (_plies.length * kAiCoachScanTime.inMilliseconds / 1000).round();
    return PlatformScaffold(
      appBar: const PlatformAppBar(title: Text('Game review')),
      body: ListView(
        padding: const EdgeInsets.all(16).add(MediaQuery.paddingOf(context)),
        children: [
          const Text(
            'Stockfish scans every move of the game on your phone first. Nothing is sent to OpenAI '
            'until you tap the button that explains the key moments, and it says how many '
            'requests that makes. Charges may apply. Explanations can be wrong.',
          ),
          const SizedBox(height: 16),
          if (_phase == _Phase.setup) ...[
            const Text('Review for', style: TextStyle(fontWeight: FontWeight.bold)),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('White'),
                  selected: _side == Side.white,
                  onSelected: (_) => setState(() => _side = Side.white),
                ),
                ChoiceChip(
                  label: const Text('Black'),
                  selected: _side == Side.black,
                  onSelected: (_) => setState(() => _side = Side.black),
                ),
                ChoiceChip(
                  label: const Text('Both'),
                  selected: _side == null,
                  onSelected: (_) => setState(() => _side = null),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${_plies.length} half-moves. The scan takes about $seconds seconds and runs on '
              'your phone.',
            ),
            const SizedBox(height: 8),
            FilledButton(onPressed: _startScan, child: const Text('Start the scan')),
          ],
          if (_phase == _Phase.scanning) ...[
            LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
            const SizedBox(height: 8),
            Text('Analysing position $_done of $_total…'),
            TextButton(
              onPressed: () => setState(() => _cancelRequested = true),
              child: const Text('Cancel'),
            ),
          ],
          if (_phase == _Phase.moments || _phase == _Phase.explaining || _phase == _Phase.done) ...[
            Text(_statsLine()),
            const SizedBox(height: 12),
            if (_moments.isEmpty)
              const Text('No clear mistakes were found in this game.')
            else ...[
              const Text('Key moments', style: TextStyle(fontWeight: FontWeight.bold)),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  "Each board is the position before the move: green arrow is the engine's "
                  'preferred move, red arrow is the move played.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              for (final moment in _moments)
                Card(
                  child: InkWell(
                    onTap: _notes[moment.index] == null ? null : () => _openMoment(moment),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 130,
                            child: AiCoachBoardsView(
                              compact: true,
                              boards: aiCoachMomentBoards(
                                plies: _plies,
                                scan: _scan,
                                moment: moment,
                                userSide: widget.side,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${aiCoachMoveLabel(_plies[moment.index])}: '
                                  '${aiCoachVerdictText(moment.verdict)}',
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Evaluation ${moment.evalBefore} to ${moment.evalAfter}'
                                  '${_notes[moment.index] == null ? '' : '\n\n${stripAiCoachNote(_notes[moment.index]!)}'}',
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ],
          if (_phase == _Phase.moments) ...[
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _explainAll,
              child: Text(
                _moments.isEmpty
                    ? 'Summarise the game (1 request to OpenAI)'
                    : 'Explain these moments and summarise (${_moments.length + 1} requests to '
                          'OpenAI)',
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).push(AiCoachSettingsScreen.buildRoute()),
              child: const Text('AI coach settings'),
            ),
          ],
          if (_phase == _Phase.explaining) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _notes.length < _moments.length
                        ? 'Explaining key moment ${_notes.length + 1} of ${_moments.length}…'
                        : 'Writing the summary…',
                  ),
                ),
              ],
            ),
          ],
          if (_error != null)
            Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(_error!)),
          if (_summary != null) ...[
            const SizedBox(height: 16),
            const Text('Summary', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(height: 8),
            SelectableText(_summary!),
          ],
        ],
      ),
    );
  }
}
