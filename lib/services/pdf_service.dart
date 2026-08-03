import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/moto.dart';
import '../models/versement.dart';
import '../models/depense.dart';

/// Génère un relevé PDF (versements + dépenses + solde) pour une moto,
/// et propose le partage/l'impression natif du téléphone.
class PdfService {
  PdfService._();

  static Future<void> genererEtPartagerReleve({
    required Moto moto,
    required List<Versement> versements,
    required List<Depense> depenses,
    required double soldeRestant,
    required String deviseSymbole,
  }) async {
    final doc = pw.Document();

    final totalPaye = versements
        .where((v) => v.statut == 'paye')
        .fold<double>(0, (s, v) => s + (v.montantPaye ?? 0));
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
          pw.Text('Montant total du pret : ${moto.montantTotal.toStringAsFixed(0)} $deviseSymbole'),
          pw.Text('Total verse : ${totalPaye.toStringAsFixed(0)} $deviseSymbole'),
          pw.Text('Solde restant : ${soldeRestant.toStringAsFixed(0)} $deviseSymbole'),
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

  static String _formaterDate(DateTime d) {
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }
}
