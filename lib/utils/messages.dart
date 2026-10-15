import '../core/constants.dart';
import '../models/moto.dart';
import '../models/versement.dart';
import '../services/schedule_service.dart';
import 'formatters.dart';

/// Message de relance a envoyer au chauffeur (WhatsApp, SMS...) : chaque
/// periode due et le total.
String messageRelance({
  required String chauffeur,
  required String moto,
  required List<({DateTime date, String etat, double reste})> dues,
  required String devise,
}) {
  final total = dues.fold<double>(0, (t, p) => t + p.reste);
  return [
    'Bonjour $chauffeur,',
    'Rappel pour la moto $moto : ${formaterMontant(total, devise)} restent a payer.',
    for (final p in dues) '- ${formaterDate(p.date)} : ${formaterMontant(p.reste, devise)}',
    'Merci.',
  ].join('\n');
}

/// Recu d'un versement encaisse : montant, periodes payees et ce qui reste du.
String messageRecu({
  required String chauffeur,
  required String moto,
  required double montant,
  required DateTime date,
  required List<({DateTime date, double montant})> affectations,
  required double resteDu,
  required String devise,
}) {
  return [
    'Recu - $moto ($chauffeur)',
    '${formaterMontant(montant, devise)} recus le ${formaterDate(date)}.',
    'Periodes payees :',
    for (final a in affectations) '- ${formaterDate(a.date)} : ${formaterMontant(a.montant, devise)}',
    resteDu > 0 ? 'Reste du : ${formaterMontant(resteDu, devise)}' : 'A jour, merci.',
  ].join('\n');
}

/// Une echeance telle que la fiche moto et le releve PDF l'affichent (meme
/// texte aux deux endroits) : son libelle et ce qui a deja ete paye. Une
/// echeance passee en dette compte ce qui avait ete paye avant, plus les
/// remboursements de sa [dette] (null : dette introuvable).
({String libelle, double? paye}) ligneVersement(
  Versement v, {
  required Moto moto,
  ({double rembourse, double reste})? dette,
  required DateTime aujourdHui,
  required String devise,
}) {
  final reste = ScheduleService.resteDu(v);
  switch (v.statut) {
    case AppConstants.versementPaye:
      return (
        libelle: reste > 0 ? 'Partiel (reste ${formaterMontant(reste, devise)})' : 'Paye',
        paye: v.montantPaye,
      );
    case AppConstants.versementEnDette:
      if (dette == null) return (libelle: 'Dette', paye: v.montantPaye);
      return (
        libelle: dette.reste <= 0 ? 'Rembourse' : 'Dette (reste ${formaterMontant(dette.reste, devise)})',
        paye: (v.montantPaye ?? 0) + dette.rembourse,
      );
    default:
      // Meme regle que les calculs (ScheduleService.estDue) : une semaine
      // tombee pendant la pause d'une moto suspendue n'est pas due.
      final libelle = ScheduleService.estDue(v, moto, aujourdHui)
          ? 'En retard'
          : v.dateEcheance.isBefore(aujourdHui)
              ? 'Pendant la pause (non du)'
              : 'A venir';
      return (libelle: libelle, paye: v.montantPaye);
  }
}
