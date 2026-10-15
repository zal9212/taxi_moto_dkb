import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/moto.dart';
import '../models/versement.dart';
import '../models/depense.dart';
import '../models/dette.dart';
import '../utils/formatters.dart';
import '../utils/messages.dart';
import 'schedule_service.dart';

/// Génère les relevés PDF (par moto, ou rapport général toutes motos) et
/// propose le partage/l'impression natif du téléphone.
class PdfService {
  PdfService._();

  /// Releve d'une moto. Les chiffres (encaisse, retard, avance, dettes) sont ceux
  /// de la fiche moto, pas un second calcul : le PDF dit toujours la meme
  /// chose que l'app.
  static Future<void> genererEtPartagerReleve({
    required Moto moto,
    required List<Versement> versements,
    required List<Depense> depenses,
    required String deviseSymbole,
    required double totalEncaisse,
    required double remboursementsDettes,
    required CompteMoto compte,
    required List<Dette> dettes,
    required ({double rembourse, double reste})? Function(int? detteId) detteDe,
  }) async {
    final doc = pw.Document();
    final aujourdHui = ScheduleService.aujourdHui();
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
          pw.Text('Montant par versement : ${_n(moto.montantVersement)} $deviseSymbole'),
          pw.Text('Total encaisse : ${_n(totalEncaisse)} $deviseSymbole'),
          if (remboursementsDettes > 0)
            pw.Text('  dont ${_n(remboursementsDettes)} $deviseSymbole de remboursements de dettes'),
          pw.Text(compte.retard > 0
              ? 'En retard de : ${_n(compte.retard)} $deviseSymbole'
              : 'Retard : aucun (a jour)'),
          if (compte.avance > 0) pw.Text('Paye d\'avance : ${_n(compte.avance)} $deviseSymbole'),
          pw.Text('Total depenses (huile, reparations...) : ${_n(totalDepenses)} $deviseSymbole'),
          pw.SizedBox(height: 16),

          pw.Text('Historique des versements',
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 6),
          pw.Table.fromTextArray(
            headers: ['Echeance', 'Statut', 'Montant prevu', 'Montant paye', 'Date validation'],
            data: versements.map((v) {
              // Meme libelle que la fiche ; une echeance en dette compte ses remboursements.
              final ligne = ligneVersement(v,
                  moto: moto, dette: detteDe(v.detteId), aujourdHui: aujourdHui, devise: deviseSymbole);
              return [
                formaterDate(v.dateEcheance),
                ligne.libelle,
                _n(v.montantPrevu),
                ligne.paye == null ? '-' : _n(ligne.paye!),
                v.dateValidation != null ? formaterDate(v.dateValidation!) : '-',
              ];
            }).toList(),
            cellStyle: const pw.TextStyle(fontSize: 9),
            headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 16),

          if (dettes.isNotEmpty) ...[
            pw.Text('Dettes liees', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 6),
            pw.Table.fromTextArray(
              headers: ['Date', 'Motif', 'Montant', 'Rembourse', 'Reste'],
              data: dettes.map((d) {
                final etat = detteDe(d.id);
                return [
                  formaterDate(d.date),
                  d.notes ?? '-',
                  _n(d.montantInitial),
                  etat == null ? '-' : _n(etat.rembourse),
                  etat == null ? '-' : etat.reste <= 0 ? 'Rembourse' : _n(etat.reste),
                ];
              }).toList(),
              cellStyle: const pw.TextStyle(fontSize: 9),
              headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 16),
          ],

          pw.Text('Depenses',
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 6),
          pw.Table.fromTextArray(
            headers: ['Date', 'Montant', 'Description'],
            data: depenses
                .map((d) => [
                      formaterDate(d.date),
                      _n(d.montant),
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
    required Map<int, double> encaisseParMoto,
    required Map<int, CompteMoto> compteParMoto,
    required Map<int, List<Depense>> depensesParMoto,
    required String deviseSymbole,
  }) async {
    final doc = pw.Document();

    double totalGeneralVerse = 0;
    double totalGeneralRetard = 0;
    double totalGeneralAvance = 0;
    double totalGeneralDepenses = 0;

    final lignes = motos.map((m) {
      final depenses = m.id != null ? (depensesParMoto[m.id] ?? []) : <Depense>[];
      final verse = encaisseParMoto[m.id] ?? 0;
      final retard = compteParMoto[m.id]?.retard ?? 0.0;
      final avance = compteParMoto[m.id]?.avance ?? 0.0;
      final dep = depenses.fold<double>(0, (s, d) => s + d.montant);

      totalGeneralVerse += verse;
      totalGeneralRetard += retard;
      totalGeneralAvance += avance;
      totalGeneralDepenses += dep;

      return [
        m.nom,
        m.chauffeur,
        _n(verse),
        _n(retard),
        _n(avance),
        _n(dep),
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
          pw.Text('Genere le ${formaterDate(DateTime.now())}'),
          pw.SizedBox(height: 16),
          pw.Table.fromTextArray(
            headers: ['Moto', 'Chauffeur', 'Total encaisse', 'En retard', 'En avance', 'Depenses'],
            data: lignes,
            cellStyle: const pw.TextStyle(fontSize: 9),
            headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 20),
          pw.Divider(),
          pw.SizedBox(height: 8),
          pw.Text('Total general encaisse : ${_n(totalGeneralVerse)} $deviseSymbole',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
          pw.Text('Total general en retard : ${_n(totalGeneralRetard)} $deviseSymbole',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
          pw.Text('Total general en avance : ${_n(totalGeneralAvance)} $deviseSymbole',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
          pw.Text('Total general depenses : ${_n(totalGeneralDepenses)} $deviseSymbole',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
        ],
      ),
    );

    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: 'rapport_general_${_formaterDateFichier(DateTime.now())}.pdf',
    );
  }

  /// Nombre ecrit comme dans l'app ([formaterNombre]), avec une espace simple
  /// : la police integree du PDF n'a pas l'espace fine.
  static String _n(double montant) => formaterNombre(montant).replaceAll('\u202F', ' ').replaceAll('\u00A0', ' ');

  /// Comme [formaterDate] mais sans '/' : utilisable dans un nom de fichier
  /// (le '/' y serait interprete comme un separateur de dossier et ferait
  /// echouer l'ecriture du PDF).
  static String _formaterDateFichier(DateTime d) {
    return '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
  }
}
