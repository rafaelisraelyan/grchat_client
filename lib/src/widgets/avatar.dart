import 'package:flutter/material.dart';

const _palette = [
  0xFF574CC9,
  0xFF2E7D5B,
  0xFFB5651D,
  0xFF4A90D9,
  0xFF9B59B6,
  0xFF1ABC9C,
  0xFFE91E63,
  0xFF607D8B,
];

/// Letter avatar, stable color per nick.
class Avatar extends StatelessWidget {
  const Avatar(this.nick, {super.key, this.radius = 14});

  final String nick;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final letter = nick.isEmpty ? '?' : nick[0].toUpperCase();
    return CircleAvatar(
      radius: radius,
      backgroundColor: Color(_palette[nick.hashCode.abs() % _palette.length]),
      child: Text(letter,
          style: TextStyle(
              fontSize: radius,
              fontWeight: FontWeight.w700,
              color: Colors.white)),
    );
  }
}

/// Rounded-square server tile like the mockup.
class ServerTile extends StatelessWidget {
  const ServerTile(this.letter,
      {super.key, this.color = const Color(0xFF574CC9), this.selected = false});

  final String letter;
  final Color color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(children: [
        if (selected)
          Positioned(
            left: -12,
            top: 10,
            bottom: 10,
            child: Container(
              width: 4,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: selected ? color : color.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: Alignment.center,
          child: Text(letter,
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
        ),
      ]),
    );
  }
}

/// Home/DM stand tile: chat icon identity, no emoji.
class HomeTile extends StatelessWidget {
  const HomeTile({super.key, required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 44,
        height: 44,
        child: Stack(children: [
          if (selected)
            Positioned(
              left: -12,
              top: 10,
              bottom: 10,
              child: Container(
                width: 4,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xFF574CC9)
                  : Colors.grey.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.forum,
                color: selected ? Colors.white : Colors.grey, size: 22),
          ),
        ]),
      ),
    );
  }
}

class RolePill extends StatelessWidget {
  const RolePill(this.role, {super.key});

  final String role;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(role,
          style: const TextStyle(fontSize: 10, color: Colors.grey)),
    );
  }
}
