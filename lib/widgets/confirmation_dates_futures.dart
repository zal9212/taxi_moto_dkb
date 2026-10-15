import 'package:flutter/material.dart';

import '../services/excel_service.dart';
import '../utils/formatters.dart';

/// Avant un import Excel : des sommes (paiements, remboursements, depenses,
/// operations) datees dans le futur fausseraient "Ce mois" et les graphiques
/// - souvent une faute de frappe (2027 au lieu de 2026). L'app les liste et
/// demande une deuxieme confirmation. true : importer quand meme.
Future<bool> confirmerDatesFutures(BuildContext context, String cheminFichier) async {
  final List<({String feuille, int ligne, DateTime date})> lignes;
  try {
    lignes = await ExcelService.lignesDateeDansLeFutur(cheminFichier);
  } catch (_) {
    return true; // fichier illisible : l'import lui-meme affichera l'erreur
  }
  if (lignes.isEmpty || !context.mounted) return true;
  final confirme = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Dates dans le futur'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${lignes.length} ligne(s) du fichier sont datees apres aujourd\'hui :'),
            const SizedBox(height: 8),
            for (final l in lignes.take(10))
              Text('${l.feuille}, ligne ${l.ligne} : ${formaterDate(l.date)}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            if (lignes.length > 10) Text('... et ${lignes.length - 10} autre(s).'),
            const SizedBox(height: 8),
            const Text('Verifiez qu\'il ne s\'agit pas d\'une faute de frappe. Importer quand meme ?'),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler l\'import')),
        ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Importer quand meme')),
      ],
    ),
  );
  return confirme == true;
}
