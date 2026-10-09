import 'package:intl/intl.dart';

/// Formatte un montant avec séparateur de milliers + le symbole de devise
/// choisi par l'utilisateur dans les Réglages (jamais codé en dur ailleurs).
String formaterMontant(double montant, String devise) {
  final formateur = NumberFormat('#,##0', 'fr_FR');
  return '${formateur.format(montant)} $devise';
}

/// Lit un montant saisi : "50000", "10 000", "10.000" ou "10,000", y compris
/// tel que [formaterMontant] l'affiche. Comme l'affichage, sans centimes :
/// "12,50" est refuse plutot que lu 1250. null si vide, nul, negatif ou
/// invalide — a utiliser pour toute saisie de montant.
double? lireMontant(String? saisie) {
  final texte = (saisie ?? '').replaceAll(RegExp(r'\s'), '');
  if (!RegExp(r'^\d+([.,]\d{3})*$').hasMatch(texte)) return null;
  final montant = int.tryParse(texte.replaceAll(RegExp(r'[.,]'), ''));
  return montant == null || montant <= 0 ? null : montant.toDouble();
}

/// Devise saisie librement, normalisee ("fg " -> "FG") : sinon "FG" et "fg"
/// donnent deux totaux separes. null si vide (repli sur la devise globale).
String? normaliserDevise(String saisie) {
  final devise = saisie.trim().toUpperCase();
  return devise.isEmpty ? null : devise;
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
