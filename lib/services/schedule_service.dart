import '../core/constants.dart';

/// Calcule les dates d'échéance des versements d'une moto à partir de sa
/// configuration (fréquence hebdomadaire / mensuelle / personnalisée).
/// Les versements sont récurrents et indéfinis (pas de montant total à
/// atteindre) : on calcule uniquement "la première échéance" puis "la
/// suivante après une date donnée", ce qui permet à DatabaseService de
/// maintenir une fenêtre glissante d'échéances à venir.
/// Toute la logique de fréquence est centralisée ici — si un jour tu ajoutes
/// un nouveau type de fréquence, c'est le seul fichier à modifier.
class ScheduleService {
  ScheduleService._();

  /// Première échéance à partir de la date de début, selon la fréquence.
  static DateTime premiereEcheance({
    required DateTime dateDebut,
    required String type,
    required int valeur,
  }) {
    switch (type) {
      case AppConstants.freqHebdomadaire:
        // valeur = jour de la semaine cible, 1 (Lundi) à 7 (Dimanche)
        var date = dateDebut;
        while (date.weekday != valeur) {
          date = date.add(const Duration(days: 1));
        }
        return date;

      case AppConstants.freqMensuelle:
        // valeur = jour du mois cible, 1 à 31 (ajusté si le mois est plus court)
        final dernierJourDuMois = DateTime(dateDebut.year, dateDebut.month + 1, 0).day;
        final jour = valeur > dernierJourDuMois ? dernierJourDuMois : valeur;
        return DateTime(dateDebut.year, dateDebut.month, jour);

      case AppConstants.freqPersonnalisee:
      default:
        // valeur = intervalle en jours entre deux versements
        return dateDebut;
    }
  }

  /// Échéance suivante après une date donnée, selon la fréquence.
  static DateTime echeanceSuivante({
    required DateTime dateActuelle,
    required String type,
    required int valeur,
  }) {
    switch (type) {
      case AppConstants.freqHebdomadaire:
        return dateActuelle.add(const Duration(days: 7));

      case AppConstants.freqMensuelle:
        final moisCible = dateActuelle.month + 1;
        final anneeCible = dateActuelle.year + ((moisCible - 1) ~/ 12);
        final moisNormalise = ((moisCible - 1) % 12) + 1;
        final dernierJourDuMois = DateTime(anneeCible, moisNormalise + 1, 0).day;
        final jour = valeur > dernierJourDuMois ? dernierJourDuMois : valeur;
        return DateTime(anneeCible, moisNormalise, jour);

      case AppConstants.freqPersonnalisee:
      default:
        return dateActuelle.add(Duration(days: valeur));
    }
  }

  /// Libellé lisible de la fréquence pour l'affichage dans l'UI.
  static String libelleFrequence(String type, int valeur) {
    switch (type) {
      case AppConstants.freqHebdomadaire:
        return 'Chaque ${AppConstants.joursSemaine[valeur - 1]}';
      case AppConstants.freqMensuelle:
        return 'Le $valeur de chaque mois';
      case AppConstants.freqPersonnalisee:
        return 'Tous les $valeur jours';
      default:
        return '';
    }
  }
}
