import 'package:intl/intl.dart';

/// Formatte un montant avec séparateur de milliers + le symbole de devise
/// choisi par l'utilisateur dans les Réglages (jamais codé en dur ailleurs).
String formaterMontant(double montant, String devise) {
  final formateur = NumberFormat('#,##0', 'fr_FR');
  return '${formateur.format(montant)} $devise';
}

String formaterDate(DateTime date) {
  return DateFormat('dd/MM/yyyy', 'fr_FR').format(date);
}

String formaterDateCourte(DateTime date) {
  return DateFormat('dd MMM', 'fr_FR').format(date);
}

/// Formatte plusieurs totaux dans des devises differentes (ex: des dettes
/// liees a des motos et a des boutiques utilisant des devises differentes),
/// separes par un point median — jamais additionnes entre eux.
String formaterTotauxParDevise(Map<String, double> totauxParDevise, String deviseParDefaut) {
  if (totauxParDevise.isEmpty) return formaterMontant(0, deviseParDefaut);
  return totauxParDevise.entries.map((e) => formaterMontant(e.value, e.key)).join(' · ');
}
