import 'package:flutter/material.dart';

/// Clavier numerique des ecrans PIN (verrouillage, creation du PIN).
/// Lignes simples, pas de GridView : une grille (viewport) dans
/// l'IntrinsicHeight de ces ecrans fait planter la mise en page.
class ClavierPin extends StatelessWidget {
  final ValueChanged<String> onChiffre;
  final VoidCallback onEffacer;

  const ClavierPin({super.key, required this.onChiffre, required this.onEffacer});

  static const _lignes = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['', '0', '<'],
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final ligne in _lignes)
          Row(
            children: [
              for (final t in ligne)
                Expanded(
                  child: AspectRatio(
                    aspectRatio: 1.6,
                    child: t.isEmpty
                        ? const SizedBox.shrink()
                        : TextButton(
                            onPressed: () => t == '<' ? onEffacer() : onChiffre(t),
                            child: t == '<'
                                ? const Icon(Icons.backspace_outlined, color: Colors.white, size: 20)
                                : Text(t, style: const TextStyle(color: Colors.white, fontSize: 22)),
                          ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
