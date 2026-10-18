import 'package:lichess_mobile/src/model/analysis/ai_coach.dart';
import 'package:lichess_mobile/src/model/analysis/ai_coach_input.dart';
import 'package:lichess_mobile/src/utils/navigation.dart';
import 'package:lichess_mobile/src/view/analysis/ai_coach_screen.dart';
import 'package:lichess_mobile/src/widgets/platform.dart';
import 'package:material_ui/material_ui.dart';

/// Asks for a FEN or a PGN, then opens the coach on it. Works without any game or analysis open.
class const AiCoachPositionScreen({super.key}) extends StatefulWidget {
  static Route<void> buildRoute() => buildScreenRoute(screen: const AiCoachPositionScreen());

  @override
  State<AiCoachPositionScreen> createState() => _AiCoachPositionScreenState();
}

class _AiCoachPositionScreenState() extends State<AiCoachPositionScreen> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _open() {
    final AiCoachInput input;
    try {
      input = parseAiCoachInput(_controller.text);
    } on AiCoachException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    setState(() => _error = null);
    Navigator.of(context).push(AiCoachScreen.buildRoute(prepare: aiCoachPrepareFor(input)));
  }

  @override
  Widget build(BuildContext context) => PlatformScaffold(
    appBar: const PlatformAppBar(title: Text('AI coach')),
    body: ListView(
      padding: const EdgeInsets.all(16).add(MediaQuery.paddingOf(context)),
      children: [
        const Text(
          'Paste a FEN or a PGN. With a PGN, the coach explains the last move of the game, so '
          'paste it up to the move you want explained. Stockfish analyses it on your phone '
          'first; nothing is sent to OpenAI until you tap Explain. Standard chess only.',
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _controller,
          minLines: 4,
          maxLines: 10,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'FEN or PGN',
            errorText: _error,
            suffixIcon: IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.clear),
              onPressed: () {
                _controller.clear();
                setState(() => _error = null);
              },
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _open, child: const Text('Analyse and explain')),
      ],
    ),
  );
}
