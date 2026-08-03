import '../core/constants.dart';
import '../models/moto.dart';
import '../models/versement.dart';

/// Calcule le calendrier complet des échéances d'une moto à partir de sa
/// configuration (fréquence hebdomadaire / mensuelle / personnalisée).
/// Toute la logique de fréquence est centralisée ici — si un jour tu ajoutes
/// un nouveau type de fréquence, c'est le seul fichier à modifier.
class ScheduleService {
  ScheduleService._();

  /// Génère la liste des versements (non enregistrés en base) pour une moto.
  static List<Versement> genererEcheances(Moto moto) {
    final nombre = moto.nombreVersements;
    final dates = _genererDates(
      dateDebut: moto.dateDebut,
      type: moto.frequenceType,
      valeur: moto.frequenceValeur,
      nombre: nombre,
    );

    return List.generate(nombre, (i) {
      final estDernier = i == nombre - 1;
      final montantRestant = moto.montantTotal - (moto.montantVersement * i);
      final montantEcheance = estDernier && montantRestant < moto.montantVersement
          ? montantRestant
          : moto.montantVersement;

      return Versement(
        motoId: moto.id ?? 0,
        dateEcheance: dates[i],
        montantPrevu: montantEcheance,
        statut: AppConstants.versementEnAttente,
      );
    });
  }

  static List<DateTime> _genererDates({
    required DateTime dateDebut,
    required String type,
    required int valeur,
    required int nombre,
  }) {
    final dates = <DateTime>[];

    switch (type) {
      case AppConstants.freqHebdomadaire:
        // valeur = jour de la semaine cible, 1 (Lundi) à 7 (Dimanche)
        var premiere = dateDebut;
        while (premiere.weekday != valeur) {
          premiere = premiere.add(const Duration(days: 1));
        }
        for (var i = 0; i < nombre; i++) {
          dates.add(premiere.add(Duration(days: 7 * i)));
        }
        break;

      case AppConstants.freqMensuelle:
        // valeur = jour du mois cible, 1 à 31 (ajusté si le mois est plus court)
        for (var i = 0; i < nombre; i++) {
          final moisCible = dateDebut.month + i;
          final anneeCible = dateDebut.year + ((moisCible - 1) ~/ 12);
          final moisNormalise = ((moisCible - 1) % 12) + 1;
          final dernierJourDuMois =
              DateTime(anneeCible, moisNormalise + 1, 0).day;
          final jour = valeur > dernierJourDuMois ? dernierJourDuMois : valeur;
          dates.add(DateTime(anneeCible, moisNormalise, jour));
        }
        break;

      case AppConstants.freqPersonnalisee:
      default:
        // valeur = intervalle en jours entre deux versements
        for (var i = 0; i < nombre; i++) {
          dates.add(dateDebut.add(Duration(days: valeur * i)));
        }
        break;
    }

    return dates;
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
