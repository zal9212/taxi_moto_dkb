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
