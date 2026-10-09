import '../core/constants.dart';
import '../models/moto.dart';
import '../models/versement.dart';

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

  /// Nombre d'échéances à venir (non payées) maintenues en permanence pour
  /// chaque moto active. Dès qu'une échéance est validée, une nouvelle est
  /// générée pour garder cette fenêtre pleine — le versement est récurrent
  /// et indéfini, il n'y a pas de montant total à atteindre.
  static const int fenetreEcheances = 4;

  /// Date sans l'heure (minuit) : toutes les échéances tombent à 00:00 pour
  /// que les comparaisons de jours restent justes, quelle que soit l'heure
  /// à laquelle la moto a été créée ou modifiée.
  static DateTime dateSeule(DateTime d) => DateTime(d.year, d.month, d.day);

  static DateTime aujourdHui() => dateSeule(DateTime.now());

  /// Première échéance à partir de [dateDebut] (incluse) qui respecte la
  /// fréquence. Les jours sont comptés avec DateTime(a, m, j + n) plutôt
  /// qu'avec add(Duration) pour ne jamais dériver d'une heure (heure d'été).
  static DateTime premiereEcheance({
    required DateTime dateDebut,
    required String type,
    required int valeur,
  }) {
    final d = dateSeule(dateDebut);
    switch (type) {
      case AppConstants.freqHebdomadaire:
        // valeur = jour de la semaine cible, 1 (Lundi) à 7 (Dimanche)
        return DateTime(d.year, d.month, d.day + (valeur - d.weekday + 7) % 7);

      case AppConstants.freqMensuelle:
        // valeur = jour du mois cible, 1 à 31 (ajusté si le mois est plus
        // court) — jamais avant la date de début : sinon le mois suivant.
        final ceMois = _jourDuMois(d.year, d.month, valeur);
        return ceMois.isBefore(d) ? _jourDuMois(d.year, d.month + 1, valeur) : ceMois;

      case AppConstants.freqPersonnalisee:
      default:
        // valeur = intervalle en jours entre deux versements
        return d;
    }
  }

  /// Échéance suivante, strictement après [dateActuelle], selon la fréquence.
  /// En hebdomadaire/mensuelle, c'est le prochain jour choisi : un changement
  /// de jour (ex: lundi -> mercredi) s'applique donc dès l'échéance suivante.
  static DateTime echeanceSuivante({
    required DateTime dateActuelle,
    required String type,
    required int valeur,
  }) {
    final d = dateSeule(dateActuelle);
    switch (type) {
      case AppConstants.freqHebdomadaire:
      case AppConstants.freqMensuelle:
        return premiereEcheance(dateDebut: DateTime(d.year, d.month, d.day + 1), type: type, valeur: valeur);

      case AppConstants.freqPersonnalisee:
      default:
        // Au moins 1 jour, pour que la suite avance toujours.
        return DateTime(d.year, d.month, d.day + (valeur < 1 ? 1 : valeur));
    }
  }

  static DateTime _jourDuMois(int annee, int mois, int jour) {
    final dernierJourDuMois = DateTime(annee, mois + 1, 0).day;
    return DateTime(annee, mois, jour > dernierJourDuMois ? dernierJourDuMois : jour);
  }

  /// Dates des échéances à créer en suivant la fréquence à partir de
  /// [premiere] (incluse), jusqu'à avoir [fenetreEcheances] échéances non
  /// payées à partir d'aujourd'hui. Les dates déjà passées sont créées aussi
  /// (elles deviennent des retards) : le retard d'un chauffeur qui ne paie
  /// plus continue donc de grossir au lieu de s'arrêter à 4 échéances.
  /// Rien n'est créé dans la période déjà couverte par les échéances
  /// conservées (de la première à la dernière : payées, retards, dettes) :
  /// jamais de paiement redemandé ni de retard en double. Les trous au milieu
  /// se comblent à la main (voir [datesManquantes]).
  static List<DateTime> datesAGenerer({
    required List<Versement> existants,
    required DateTime premiere,
    required String type,
    required int valeur,
    required DateTime aujourdHui,
  }) {
    final occupees = existants.map((v) => dateSeule(v.dateEcheance)).toList()..sort();
    var aVenir = existants.where((v) => _estAVenir(v, aujourdHui)).length;

    final dates = <DateTime>[];
    for (var d = dateSeule(premiere);
        aVenir < fenetreEcheances;
        d = echeanceSuivante(dateActuelle: d, type: type, valeur: valeur)) {
      if (occupees.isNotEmpty && !d.isBefore(occupees.first) && !d.isAfter(occupees.last)) continue;
      dates.add(d);
      if (!d.isBefore(aujourdHui)) aVenir++;
    }
    return dates;
  }

  /// Échéance encore attendue (ni payée, ni passée en dette) à partir d'aujourd'hui.
  static bool _estAVenir(Versement v, DateTime aujourdHui) =>
      v.statut != AppConstants.versementPaye &&
      v.statut != AppConstants.versementEnDette &&
      !dateSeule(v.dateEcheance).isBefore(aujourdHui);

  /// Dates passées de la fréquence, à partir de [depuis], qui n'ont aucune
  /// échéance (oubliées au début ou au milieu de l'historique), pour les
  /// ajouter à la main — rien n'est supprimé ni déplacé.
  static List<DateTime> datesManquantes({
    required List<Versement> existants,
    required DateTime depuis,
    required String type,
    required int valeur,
    required DateTime aujourdHui,
  }) {
    final occupees = existants.map((v) => dateSeule(v.dateEcheance)).toSet();
    return [
      for (var d = premiereEcheance(dateDebut: depuis, type: type, valeur: valeur);
          d.isBefore(aujourdHui);
          d = echeanceSuivante(dateActuelle: d, type: type, valeur: valeur))
        if (!occupees.contains(d)) d,
    ];
  }

  /// Ce qui reste dû sur une échéance (0 si payée en entier ou passée en
  /// dette). Une échéance "payée" sans montant enregistré (ancien import)
  /// compte comme soldée : on ne redemande jamais un paiement déjà fait.
  static double resteDu(Versement v) {
    if (v.statut == AppConstants.versementEnDette) return 0;
    final paye = v.montantPaye ?? (v.statut == AppConstants.versementPaye ? v.montantPrevu : 0);
    return (v.montantPrevu - paye).clamp(0, double.infinity).toDouble();
  }

  /// Périodes encore dues, de la plus ancienne à la plus récente, avec ce qui
  /// reste à payer : échéances partielles, en retard ou à venir, et périodes
  /// passées qui n'ont jamais eu d'échéance (depuis la date de début). Pas
  /// les périodes soldées, ni celles passées en dette (elles se remboursent
  /// dans Dettes).
  static List<({DateTime date, String etat, double reste})> periodesAPayer({
    required List<Versement> existants,
    required Moto moto,
    required DateTime aujourdHui,
  }) {
    String etat(Versement v) => v.statut == AppConstants.versementPaye
        ? 'partiel'
        : dateSeule(v.dateEcheance).isBefore(aujourdHui)
            ? 'en retard'
            : 'a venir';
    final periodes = [
      for (final v in existants)
        if (resteDu(v) > 0) (date: dateSeule(v.dateEcheance), etat: etat(v), reste: resteDu(v)),
      for (final d in datesManquantes(
        existants: existants,
        depuis: moto.dateDebut,
        type: moto.frequenceType,
        valeur: moto.frequenceValeur,
        aujourdHui: aujourdHui,
      ))
        (date: d, etat: 'manquante', reste: moto.montantVersement),
    ]..sort((a, b) => a.date.compareTo(b.date));
    return periodes;
  }

  /// Répartit un montant reçu sur les périodes dues, la plus ancienne
  /// d'abord (méthode des logiciels d'encaissement de loyers) : chaque
  /// période est soldée avant de passer à la suivante. Un trop-payé au-delà
  /// de toutes les périodes reste sur la dernière (avance du chauffeur).
  static List<({DateTime date, double montant})> repartirPaiement(
    List<({DateTime date, String etat, double reste})> periodes,
    double montant,
  ) {
    final affectations = <({DateTime date, double montant})>[];
    var restant = montant;
    for (final p in periodes) {
      if (restant <= 0) break;
      final part = restant < p.reste ? restant : p.reste;
      affectations.add((date: p.date, montant: part));
      restant -= part;
    }
    if (restant > 0 && affectations.isNotEmpty) {
      final derniere = affectations.removeLast();
      affectations.add((date: derniere.date, montant: derniere.montant + restant));
    }
    return affectations;
  }

  /// Nouveau plan des échéances après une modification de la moto. Seules
  /// les échéances À VENIR non payées sont recalculées : les versements payés,
  /// les retards et les dettes ne sont jamais supprimés (sinon les calculs
  /// seraient faux).
  /// - [depuisDateDebut] (la date de début a changé) : la suite repart de
  ///   cette date. Plus tôt, les échéances oubliées du début sont ajoutées
  ///   (ex: 2 versements jamais donnés) ; plus tard, seul l'avenir bouge.
  /// - sinon (fréquence, jour ou montant) : le changement prend effet au
  ///   prochain versement prévu.
  static ({List<Versement> aSupprimer, List<DateTime> aCreer}) replanifier({
    required List<Versement> existants,
    required Moto moto,
    required bool depuisDateDebut,
    required DateTime aujourdHui,
  }) {
    bool estRemplacee(Versement v) => _estAVenir(v, aujourdHui);

    final aSupprimer = existants.where(estRemplacee).toList();
    final DateTime premiere;
    if (depuisDateDebut) {
      premiere = dateSeule(moto.dateDebut);
    } else {
      // Prochain versement prevu = la plus proche des echeances remplacees.
      final prevues = aSupprimer.map((v) => dateSeule(v.dateEcheance)).toList()..sort();
      premiere = premiereEcheance(
        dateDebut: prevues.isEmpty ? aujourdHui : prevues.first,
        type: moto.frequenceType,
        valeur: moto.frequenceValeur,
      );
    }

    return (
      aSupprimer: aSupprimer,
      aCreer: datesAGenerer(
        existants: existants.where((v) => !estRemplacee(v)).toList(),
        premiere: premiere,
        type: moto.frequenceType,
        valeur: moto.frequenceValeur,
        aujourdHui: aujourdHui,
      ),
    );
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
