import 'package:flutter/material.dart';

/// Convertit un hex '#RRGGBB' (ou 'RRGGBB') en [Color]. Utilise pour les
/// couleurs de categorie d'activite, choisies dans une palette fixe.
Color couleurDepuisHex(String hex) {
  final nettoye = hex.replaceFirst('#', '');
  return Color(int.parse('FF$nettoye', radix: 16));
}

/// Texte lisible (blanc ou noir) par-dessus [couleur], selon sa luminance.
Color texteContrasteSur(Color couleur) {
  return couleur.computeLuminance() > 0.5 ? Colors.black : Colors.white;
}
