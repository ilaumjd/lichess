import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';

/// Facts about a position that the app computes itself, so the AI explains them instead of
/// guessing them. Attack and defence counts ignore pins and x-rays, so they are described as
/// "attacked"/"defended", not as proven tactics.
typedef AiCoachFacts = ({IList<String> lines, ISet<String> moves});

const _maxListed = 6;

const _values = {
  Role.pawn: 1,
  Role.knight: 3,
  Role.bishop: 3,
  Role.rook: 5,
  Role.queen: 9,
  Role.king: 0,
};

String aiCoachSideName(Side side) => side == .white ? 'White' : 'Black';

String _pieceName(Piece piece) => '${aiCoachSideName(piece.color)} ${piece.role.name}';

String _lastRank(Side side) => side == .white ? '8' : '1';

String _homeRank(Side side) => side == .white ? '1' : '8';

/// Computes facts about [position]. [opening] is an optional opening name supplied by the caller.
AiCoachFacts makeAiCoachFacts(Position position, {String? opening}) {
  final lines = <String>[];
  final moves = <String>{};
  final board = position.board;

  if (opening != null && opening.isNotEmpty) {
    lines.add('Opening: $opening.');
  }

  if (position.isCheckmate) {
    lines.add('${aiCoachSideName(position.turn)} is checkmated.');
  } else if (position.isStalemate) {
    lines.add('The position is stalemate (a draw).');
  } else if (position.isCheck) {
    lines.add('${aiCoachSideName(position.turn)} is in check.');
  }

  // Material.
  final material = {Side.white: 0, Side.black: 0};
  for (final (_, piece) in board.pieces) {
    material[piece.color] = material[piece.color]! + _values[piece.role]!;
  }
  final diff = material[Side.white]! - material[Side.black]!;
  lines.add(
    'Material (pawn 1, knight 3, bishop 3, rook 5, queen 9): '
    'White ${material[Side.white]}, Black ${material[Side.black]}. '
    '${diff == 0 ? 'Material is equal.' : '${diff > 0 ? 'White' : 'Black'} is ahead by ${diff.abs()}.'}',
  );

  // Attacked pieces.
  final hanging = <String>[];
  final attackedByCheaper = <String>[];
  for (final (square, piece) in board.pieces) {
    if (piece.role == Role.king) continue;
    final attackers = board.attacksTo(square, piece.color.opposite);
    if (attackers.isEmpty) continue;
    final defenders = board.attacksTo(square, piece.color);
    var cheapest = 100;
    Piece? cheapestPiece;
    Square? cheapestSquare;
    for (final attackerSquare in attackers.squares) {
      final attacker = board.pieceAt(attackerSquare);
      if (attacker == null) continue;
      final value = attacker.role == Role.king ? 100 : _values[attacker.role]!;
      if (value < cheapest) {
        cheapest = value;
        cheapestPiece = attacker;
        cheapestSquare = attackerSquare;
      }
    }
    final description = '${_pieceName(piece)} on ${square.name}';
    if (defenders.isEmpty) {
      hanging.add(description);
    } else if (cheapestPiece != null && cheapest < _values[piece.role]!) {
      attackedByCheaper.add(
        '$description (attacked by a ${cheapestPiece.role.name} on ${cheapestSquare!.name})',
      );
    }
  }
  if (hanging.isNotEmpty) {
    lines.add(
      'Attacked and not defended: ${hanging.take(_maxListed).join('; ')}. '
      '(Ignores pins, so check the engine lines before calling it a free capture.)',
    );
  }
  if (attackedByCheaper.isNotEmpty) {
    lines.add('Attacked by a cheaper piece: ${attackedByCheaper.take(_maxListed).join('; ')}.');
  }

  // Captures and checks for the side to move.
  final captures = <({int value, String text})>[];
  final checks = <String>[];
  for (final entry in position.legalMoves.entries) {
    final from = entry.key;
    final mover = board.pieceAt(from);
    if (mover == null) continue;
    for (final to in entry.value.squares) {
      final target = board.pieceAt(to);
      final isEnPassant = mover.role == Role.pawn && target == null && from.file != to.file;
      final promotes = mover.role == Role.pawn && to.name.endsWith(_lastRank(position.turn));
      final move = NormalMove(from: from, to: to, promotion: promotes ? Role.queen : null);
      final (after, san) = position.makeSanUnchecked(move);
      if (target != null || isEnPassant) {
        final captured = target?.role ?? Role.pawn;
        captures.add((value: _values[captured]!, text: '$san (takes a ${captured.name})'));
        moves.add(san);
      }
      if (after.isCheck && !after.isCheckmate) {
        checks.add(san);
        moves.add(san);
      } else if (after.isCheckmate) {
        checks.add('$san (checkmate)');
        moves.add(san);
      }
    }
  }
  final side = aiCoachSideName(position.turn);
  captures.sort((a, b) => b.value.compareTo(a.value));
  if (captures.isNotEmpty) {
    lines.add(
      '$side to move can capture: ${captures.take(_maxListed).map((c) => c.text).join(', ')}.',
    );
  }
  if (checks.isNotEmpty) {
    lines.add('$side to move can give check with: ${checks.take(_maxListed).join(', ')}.');
  }

  // King safety, kept deliberately simple.
  final rights = position.castles.castlingRights.squares.map((s) => s.name).toList();
  for (final color in Side.values) {
    final king = board.kingOf(color);
    if (king == null) continue;
    final canCastle = rights.any((name) => name.endsWith(_homeRank(color)));
    final home = king.name.endsWith(_homeRank(color));
    lines.add(
      '${aiCoachSideName(color)} king on ${king.name}; '
      '${canCastle ? 'castling is still possible' : 'castling is no longer possible'}'
      '${home ? '' : ' (king has left the back rank)'}.',
    );
  }

  return (lines: lines.toIList(), moves: moves.toISet());
}
