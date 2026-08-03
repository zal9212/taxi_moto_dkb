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
