import '../core/constants.dart';
import '../models/moto.dart';
import '../models/versement.dart';

/// Changement du montant de versement d'une moto : [montant] s'applique a
/// partir du jour [depuis], jusqu'au changement suivant.
typedef ChangementMontant = ({DateTime depuis, double montant});

/// Compte d'une moto : ce qui reste du sur les echeances passees ([retard])
/// et ce qui est deja paye d'avance ([avance]). Deux chiffres, jamais
/// compenses : une avance sur le futur ne cache pas un retard passe.
typedef CompteMoto = ({double retard, double avance});

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
  /// Un seul versement par période (règle du client) : par semaine du
  /// calendrier (lundi -> dimanche) en hebdomadaire, par mois en mensuel, et
  /// au moins N jours d'écart en "tous les N jours". Une date dont la
  /// période a déjà une échéance (payée, retard, dette, ou créée juste
  /// avant) est sautée : ex. lundi 14/09 dû, passage au vendredi -> premier
  /// vendredi le 25/09, pas le 18/09. Vaut pour tout changement (jour,
  /// fréquence, date de début, reprise après pause) : jamais de paiement
  /// redemandé ni de semaine comptée deux fois.
  static List<DateTime> datesAGenerer({
    required List<Versement> existants,
    required DateTime premiere,
    required String type,
    required int valeur,
    required DateTime aujourdHui,
  }) {
    var aVenir = existants.where((v) => _estAVenir(v, aujourdHui)).length;
    final dates = <DateTime>[];
    for (final d in _suiteDates(existants: existants, premiere: premiere, type: type, valeur: valeur)) {
      if (aVenir >= fenetreEcheances) break;
      dates.add(d);
      if (!d.isBefore(aujourdHui)) aVenir++;
    }
    return dates;
  }

  /// Suite sans fin des dates du rythme a partir de [premiere], sans jamais
  /// deux echeances dans la meme periode (voir [datesAGenerer]) : seule
  /// source des dates d'echeances a creer.
  static Iterable<DateTime> _suiteDates({
    required List<Versement> existants,
    required DateTime premiere,
    required String type,
    required int valeur,
  }) sync* {
    final occupees = existants.map((v) => dateSeule(v.dateEcheance)).toSet().toList()..sort();
    // "Tous les N jours" : la derniere echeance gardee suivait l'ancien rythme
    // (son ecart avec la precedente), pas les N jours du nouveau.
    final ancienRythme = occupees.length >= 2 ? _jours(occupees[occupees.length - 2], occupees.last) : null;
    DateTime? precedente;
    bool dejaPrise(DateTime d) {
      if (precedente != null && memePeriode(d, precedente, type: type, valeur: valeur)) return true;
      for (final o in occupees) {
        if (type == AppConstants.freqPersonnalisee && ancienRythme != null && o == occupees.last && d.isAfter(o)) {
          if (_jours(o, d) < ancienRythme) return true;
        } else if (memePeriode(d, o, type: type, valeur: valeur)) {
          return true;
        }
      }
      return false;
    }

    for (var d = dateSeule(premiere);; d = echeanceSuivante(dateActuelle: d, type: type, valeur: valeur)) {
      if (dejaPrise(d)) continue;
      precedente = d;
      yield d;
    }
  }

  /// Deux dates dans la même période de versement (un seul versement par
  /// période) : même semaine du calendrier (lundi -> dimanche) en
  /// hebdomadaire, même mois en mensuel, moins de [valeur] jours d'écart en
  /// "tous les N jours".
  static bool memePeriode(DateTime a, DateTime b, {required String type, required int valeur}) {
    final x = dateSeule(a);
    final y = dateSeule(b);
    switch (type) {
      case AppConstants.freqHebdomadaire:
        DateTime lundi(DateTime d) => DateTime(d.year, d.month, d.day - (d.weekday - 1));
        return lundi(x) == lundi(y);
      case AppConstants.freqMensuelle:
        return x.year == y.year && x.month == y.month;
      case AppConstants.freqPersonnalisee:
      default:
        return _jours(x, y) < (valeur < 1 ? 1 : valeur);
    }
  }

  /// Jours calendaires entre deux dates (en UTC : pas d'erreur d'un jour au
  /// changement d'heure).
  static int _jours(DateTime a, DateTime b) =>
      DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays.abs();

  /// Échéance encore attendue (ni payée, ni passée en dette) à partir d'aujourd'hui.
  static bool _estAVenir(Versement v, DateTime aujourdHui) =>
      v.statut != AppConstants.versementPaye &&
      v.statut != AppConstants.versementEnDette &&
      !dateSeule(v.dateEcheance).isBefore(aujourdHui);

  /// Montant du versement en vigueur le jour [d] : celui du dernier
  /// changement date au plus tard ce jour-la, sinon le montant de depart de
  /// la moto ([Moto.montantVersement]). [changements] : du plus ancien au
  /// plus recent.
  static double montantAu(Moto moto, List<ChangementMontant> changements, DateTime d) {
    var montant = moto.montantVersement;
    for (final c in changements) {
      if (c.depuis.isAfter(dateSeule(d))) break;
      montant = c.montant;
    }
    return montant;
  }

  // ---------------------------------------------------------------------
  // Argent du : la SEULE definition de l'app. La fiche moto, l'accueil, la
  // relance, l'encaissement, le recu et les PDF passent tous par ici.
  // Source de verite = les echeances enregistrees : l'app en cree une pour
  // chaque periode due ; une periode sans echeance (pause d'une moto
  // suspendue, echeance effacee) n'est jamais due.
  // ---------------------------------------------------------------------

  /// Ce qui a ete paye sur une echeance. "Payee" sans montant enregistre
  /// (ancien import) = payee en entier : on ne redemande jamais un paiement
  /// deja fait.
  static double montantPaye(Versement v) =>
      v.montantPaye ?? (v.statut == AppConstants.versementPaye ? v.montantPrevu : 0);

  /// Echeance qui compte dans ce qui est du : passee (due le lendemain de
  /// son jour), pas passee en dette (suivie dans Dettes, sinon payee deux
  /// fois), et pas tombee pendant la pause d'une moto suspendue (restee
  /// "en attente").
  static bool estDue(Versement v, Moto moto, DateTime aujourdHui) =>
      dateSeule(v.dateEcheance).isBefore(aujourdHui) &&
      v.statut != AppConstants.versementEnDette &&
      (moto.statut == AppConstants.motoActive || v.statut != AppConstants.versementEnAttente);

  /// Compte de la moto (voir [CompteMoto]) :
  /// - retard : ce qui reste du sur les echeances dues = exactement ce que
  ///   liste la relance ;
  /// - avance : ce qui est deja paye sur les echeances pas encore dues, plus
  ///   un eventuel trop-paye sur une echeance due.
  /// L'argent recu compte toujours, meme moto suspendue.
  static CompteMoto compte(Moto moto, List<Versement> versements, DateTime aujourdHui) {
    var retard = 0.0;
    var avance = 0.0;
    for (final v in versements) {
      if (v.statut == AppConstants.versementEnDette) continue;
      final paye = montantPaye(v);
      if (estDue(v, moto, aujourdHui)) {
        retard += resteDu(v);
        if (paye > v.montantPrevu) avance += paye - v.montantPrevu;
      } else if (v.statut == AppConstants.versementPaye) {
        avance += paye;
      }
    }
    return (retard: retard, avance: avance);
  }

  /// Nouvelle échéance du jour [d] : au montant en vigueur ce jour-là, déjà
  /// "en retard" si son jour est passé (même règle que
  /// DatabaseService.actualiserRetards). Seule façon de créer une échéance.
  static Versement nouvelleEcheance(Moto moto, List<ChangementMontant> changements, DateTime d, DateTime aujourdHui) =>
      Versement(
        motoId: moto.id!,
        dateEcheance: d,
        montantPrevu: montantAu(moto, changements, d),
        statut: d.isBefore(aujourdHui) ? AppConstants.versementEnRetard : AppConstants.versementEnAttente,
      );

  /// Ce qui reste dû sur une échéance (0 si payée en entier ou passée en
  /// dette).
  static double resteDu(Versement v) {
    if (v.statut == AppConstants.versementEnDette) return 0;
    return (v.montantPrevu - montantPaye(v)).clamp(0, double.infinity).toDouble();
  }

  /// Périodes encore à payer, de la plus ancienne à la plus récente, avec ce
  /// qui reste : échéances partielles, en retard ou à venir. Pas les
  /// soldées, ni celles passées en dette (elles se remboursent dans
  /// Dettes), ni celles de la pause d'une moto suspendue.
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
    final enPause = moto.statut != AppConstants.motoActive;
    return [
      for (final v in existants)
        if (resteDu(v) > 0 && !(enPause && v.statut == AppConstants.versementEnAttente))
          (date: dateSeule(v.dateEcheance), etat: etat(v), reste: resteDu(v)),
    ]..sort((a, b) => a.date.compareTo(b.date));
  }

  /// Periodes a regler avant de pouvoir payer celle du jour [date] (regle du
  /// client : toujours la plus ancienne d'abord) : on les paie, ou on passe
  /// les semaines deja dues en dette.
  static List<({DateTime date, String etat, double reste})> impayeesAvant({
    required List<Versement> existants,
    required Moto moto,
    required DateTime aujourdHui,
    required DateTime date,
  }) =>
      periodesAPayer(existants: existants, moto: moto, aujourdHui: aujourdHui)
          .where((p) => p.date.isBefore(dateSeule(date)))
          .toList();

  /// Periodes proposees pour un versement : celles a payer (dues et a
  /// venir), puis les 8 suivantes du rythme, pas encore creees (au
  /// montant en vigueur a leur date) pour payer d'avance.
  static List<({DateTime date, String etat, double reste})> periodesChoisissables({
    required Moto moto,
    required List<Versement> existants,
    required List<ChangementMontant> changements,
    required DateTime aujourdHui,
  }) =>
      [
        ...periodesAPayer(existants: existants, moto: moto, aujourdHui: aujourdHui),
        ..._periodesSuivantes(moto, existants, changements).take(8),
      ];

  /// Periodes du rythme apres la derniere echeance existante.
  static Iterable<({DateTime date, String etat, double reste})> _periodesSuivantes(
      Moto moto, List<Versement> existants, List<ChangementMontant> changements) {
    final dates = existants.map((v) => dateSeule(v.dateEcheance)).toList()..sort();
    final premiere = dates.isEmpty
        ? moto.dateDebut
        : echeanceSuivante(dateActuelle: dates.last, type: moto.frequenceType, valeur: moto.frequenceValeur);
    return _suiteDates(existants: existants, premiere: premiere, type: moto.frequenceType, valeur: moto.frequenceValeur)
        .map((d) => (date: d, etat: 'a venir', reste: montantAu(moto, changements, d)));
  }

  /// Ce que paie un versement de [montant] : les periodes [choisies] (null :
  /// toutes les periodes a payer), la plus ancienne d'abord ; un surplus
  /// paie les periodes qui suivent la derniere choisie, au rythme de la moto
  /// (avance). Jamais plus que son montant sur une echeance : la fiche et la
  /// relance restent d'accord quand ces periodes arrivent. Seul calcul d'un
  /// versement : l'apercu a l'ecran et l'enregistrement passent par ici.
  /// [depuis] : seulement les periodes a partir de ce jour (report d'une
  /// avance sur les echeances suivantes).
  static List<({DateTime date, double montant})> affecterVersement({
    required Moto moto,
    required List<Versement> existants,
    required List<ChangementMontant> changements,
    required DateTime aujourdHui,
    required double montant,
    Set<DateTime>? choisies,
    DateTime? depuis,
  }) {
    final univers = periodesAPayer(existants: existants, moto: moto, aujourdHui: aujourdHui)
        .followedBy(_periodesSuivantes(moto, existants, changements))
        .where((p) => depuis == null || !p.date.isBefore(dateSeule(depuis)));
    final selection = (choisies == null || choisies.isEmpty) ? null : choisies.map(dateSeule).toSet();
    final derniere = selection?.reduce((a, b) => a.isAfter(b) ? a : b);

    final affectations = <({DateTime date, double montant})>[];
    var restant = montant;
    void payer(({DateTime date, String etat, double reste}) p) {
      if (restant <= 0 || p.reste <= 0) return;
      final part = restant < p.reste ? restant : p.reste;
      affectations.add((date: p.date, montant: part));
      restant -= part;
    }

    if (selection != null) {
      for (final p in univers.takeWhile((p) => !p.date.isAfter(derniere!))) {
        if (selection.contains(p.date)) payer(p);
      }
    }
    // ponytail: 1000 periodes max, garde-fou si un montant prevu vaut 0.
    for (final p in univers.where((p) => derniere == null || p.date.isAfter(derniere)).take(1000)) {
      if (restant <= 0) break;
      payer(p);
    }
    if (restant > 0 && affectations.isNotEmpty) {
      final d = affectations.removeLast();
      affectations.add((date: d.date, montant: d.montant + restant)); // jamais d'argent perdu
    }
    return affectations..sort((a, b) => a.date.compareTo(b.date));
  }

  /// Nouveau plan des échéances après une modification de la moto. Seules
  /// les échéances À VENIR non payées sont recalculées : les versements payés,
  /// les retards et les dettes ne sont jamais supprimés (sinon les calculs
  /// seraient faux).
  /// - [depuisDateDebut] (la date de début a changé) : la suite repart de
  ///   cette date. Plus tôt, les échéances oubliées du début sont ajoutées
  ///   (ex: 2 versements jamais donnés) ; plus tard, seul l'avenir bouge.
  /// - sinon (fréquence ou jour) : le changement prend effet au prochain
  ///   versement prévu.
  /// Un nouveau montant ne passe pas par ici : voir
  /// DatabaseService.changerMontant.
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
