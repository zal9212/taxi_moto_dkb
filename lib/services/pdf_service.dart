import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../core/constants.dart';
import '../models/moto.dart';
import '../models/versement.dart';
import '../models/depense.dart';

/// Génère les relevés PDF (par moto, ou rapport général toutes motos) et
/// propose le partage/l'impression natif du téléphone. Aucune notion de
/// dette : uniquement le suivi des versements reçus et des dépenses.
class PdfService {
  PdfService._();

  static Future<void> genererEtPartagerReleve({
    required Moto moto,
    required List<Versement> versements,
    required List<Depense> depenses,
    required String deviseSymbole,
  }) async {
    final doc = pw.Document();

    final totalVerse = versements
        .where((v) => v.statut == AppConstants.versementPaye)
        .fold<double>(0, (s, v) => s + (v.montantPaye ?? 0));
    final totalEnRetard = versements
        .where((v) => v.statut == AppConstants.versementEnRetard)
        .fold<double>(0, (s, v) => s + v.montantPrevu);
    final totalDepenses = depenses.fold<double>(0, (s, d) => s + d.montant);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => [
          pw.Header(
            level: 0,
            child: pw.Text('Releve - ${moto.nom}',
                style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
          ),
          pw.Text('Chauffeur : ${moto.chauffeur}'),
          pw.Text('Montant par versement : ${moto.montantVersement.toStringAsFixed(0)} $deviseSymbole'),
          pw.Text('Total verse : ${totalVerse.toStringAsFixed(0)} $deviseSymbole'),
          pw.Text('Total en retard : ${totalEnRetard.toStringAsFixed(0)} $deviseSymbole'),
          pw.Text('Total depenses (huile, reparations...) : ${totalDepenses.toStringAsFixed(0)} $deviseSymbole'),
          pw.SizedBox(height: 16),

          pw.Text('Historique des versements',
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 6),
          pw.Table.fromTextArray(
            headers: ['Echeance', 'Statut', 'Montant prevu', 'Montant paye', 'Date validation'],
            data: versements
                .map((v) => [
                      _formaterDate(v.dateEcheance),
                      v.statut,
                      v.montantPrevu.toStringAsFixed(0),
                      v.montantPaye?.toStringAsFixed(0) ?? '-',
                      v.dateValidation != null ? _formaterDate(v.dateValidation!) : '-',
                    ])
                .toList(),
            cellStyle: const pw.TextStyle(fontSize: 9),
            headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 16),

          pw.Text('Depenses',
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 6),
          pw.Table.fromTextArray(
            headers: ['Date', 'Montant', 'Description'],
            data: depenses
                .map((d) => [
                      _formaterDate(d.date),
                      d.montant.toStringAsFixed(0),
                      d.description ?? '-',
                    ])
                .toList(),
            cellStyle: const pw.TextStyle(fontSize: 9),
            headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          ),
        ],
      ),
    );

    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: 'releve_${moto.nom.replaceAll(' ', '_')}.pdf',
    );
  }

  /// Rapport général : synthèse de toutes les motos (versements reçus,
  /// retards, dépenses) sur une période optionnelle.
  static Future<void> genererEtPartagerRapportGlobal({
    required List<Moto> motos,
    required Map<int, List<Versement>> versementsParMoto,
    required Map<int, List<Depense>> depensesParMoto,
    required String deviseSymbole,
  }) async {
    final doc = pw.Document();

    double totalGeneralVerse = 0;
    double totalGeneralRetard = 0;
    double totalGeneralDepenses = 0;

    final lignes = motos.map((m) {
      final versements = m.id != null ? (versementsParMoto[m.id] ?? []) : <Versement>[];
      final depenses = m.id != null ? (depensesParMoto[m.id] ?? []) : <Depense>[];
      final verse = versements
          .where((v) => v.statut == AppConstants.versementPaye)
          .fold<double>(0, (s, v) => s + (v.montantPaye ?? 0));
      final retard = versements
          .where((v) => v.statut == AppConstants.versementEnRetard)
          .fold<double>(0, (s, v) => s + v.montantPrevu);
      final dep = depenses.fold<double>(0, (s, d) => s + d.montant);

      totalGeneralVerse += verse;
      totalGeneralRetard += retard;
      totalGeneralDepenses += dep;

      return [
        m.nom,
        m.chauffeur,
        verse.toStringAsFixed(0),
        retard.toStringAsFixed(0),
        dep.toStringAsFixed(0),
      ];
    }).toList();

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => [
          pw.Header(
            level: 0,
            child: pw.Text('Rapport general - Toutes les motos',
                style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
          ),
          pw.Text('Genere le ${_formaterDate(DateTime.now())}'),
          pw.SizedBox(height: 16),
          pw.Table.fromTextArray(
            headers: ['Moto', 'Chauffeur', 'Total verse', 'En retard', 'Depenses'],
            data: lignes,
            cellStyle: const pw.TextStyle(fontSize: 9),
            headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 20),
          pw.Divider(),
          pw.SizedBox(height: 8),
          pw.Text('Total general verse : ${totalGeneralVerse.toStringAsFixed(0)} $deviseSymbole',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
          pw.Text('Total general en retard : ${totalGeneralRetard.toStringAsFixed(0)} $deviseSymbole',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
          pw.Text('Total general depenses : ${totalGeneralDepenses.toStringAsFixed(0)} $deviseSymbole',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
        ],
      ),
    );

    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: 'rapport_general_${_formaterDateFichier(DateTime.now())}.pdf',
    );
  }

  static String _formaterDate(DateTime d) {
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  /// Comme [_formaterDate] mais sans '/' : utilisable dans un nom de fichier
  /// (le '/' y serait interprete comme un separateur de dossier et ferait
  /// echouer l'ecriture du PDF).
  static String _formaterDateFichier(DateTime d) {
    return '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
  }
}
