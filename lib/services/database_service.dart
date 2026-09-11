import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../core/constants.dart';
import '../models/categorie_activite.dart';
import '../models/categorie_entite.dart';
import '../models/categorie_transaction.dart';
import '../models/dette.dart';
import '../models/moto.dart';
import '../models/versement.dart';
import '../models/depense.dart';
import '../models/parametre.dart';
import 'schedule_service.dart';

/// Point d'accès unique à la base SQLite locale.
/// Toute lecture/écriture de l'app passe par ce service (singleton).
class DatabaseService {
  DatabaseService._internal();
  static final DatabaseService instance = DatabaseService._internal();

  /// Nombre d'échéances à venir (non payées) maintenues en permanence pour
  /// chaque moto active. Dès qu'une échéance est validée, une nouvelle est
  /// générée pour garder cette fenêtre pleine — le versement est récurrent
  /// et indéfini, il n'y a pas de montant total à atteindre.
  static const int _tailleFenetreEcheances = 4;

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final path = await cheminBaseDeDonnees();
    return openDatabase(
      path,
      version: AppConstants.dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// Chemin du fichier SQLite sur le disque — utilise pour la
  /// sauvegarde/restauration (copie brute du fichier).
  Future<String> cheminBaseDeDonnees() async {
    final dbPath = await getDatabasesPath();
    return join(dbPath, AppConstants.dbName);
  }

  /// Ferme la connexion active. Necessaire avant de copier ou remplacer le
  /// fichier de base (sauvegarde/restauration) pour garantir qu'aucune
  /// ecriture n'est en cours et que le fichier sur disque est a jour.
  /// La connexion est rouverte automatiquement au prochain acces via
  /// [database].
  Future<void> fermer() async {
    final db = _db;
    if (db != null) {
      _db = null;
      await db.close();
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE motos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nom TEXT NOT NULL,
        chauffeur TEXT NOT NULL,
        montant_versement REAL NOT NULL,
        frequence_type TEXT NOT NULL,
        frequence_valeur INTEGER NOT NULL,
        date_debut TEXT NOT NULL,
        statut TEXT NOT NULL,
        date_creation TEXT NOT NULL,
        notes TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE versements (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        moto_id INTEGER NOT NULL,
        date_echeance TEXT NOT NULL,
        date_validation TEXT,
        montant_prevu REAL NOT NULL,
        montant_paye REAL,
        statut TEXT NOT NULL,
        notes TEXT,
        FOREIGN KEY (moto_id) REFERENCES motos (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE categories_depenses (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nom TEXT NOT NULL UNIQUE,
        icone TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE depenses (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        moto_id INTEGER NOT NULL,
        categorie_id INTEGER NOT NULL,
        montant REAL NOT NULL,
        date TEXT NOT NULL,
        description TEXT,
        FOREIGN KEY (moto_id) REFERENCES motos (id) ON DELETE CASCADE,
        FOREIGN KEY (categorie_id) REFERENCES categories_depenses (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE parametres (
        id INTEGER PRIMARY KEY,
        pin_code_hash TEXT,
        biometrie_active INTEGER NOT NULL DEFAULT 0,
        devise_symbole TEXT NOT NULL DEFAULT 'FG',
        delai_notification_heures INTEGER NOT NULL DEFAULT 24,
        categorie_active_id INTEGER
      )
    ''');

    await _creerTablesCategoriesActivite(db);
    await _creerTablesDettes(db);

    // Catégories de dépenses par défaut (l'utilisateur peut en ajouter/supprimer)
    for (final cat in AppConstants.categoriesParDefaut) {
      await db.insert('categories_depenses', {
        'nom': cat['nom'],
        'icone': cat['icone'],
      });
    }

    // Ligne unique de paramètres par défaut
    await db.insert('parametres', Parametre().toMap());
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v2 : suppression du "montant total a rembourser" - l'app ne gere
      // plus une dette a solder mais des versements recurrents indefinis.
      // L'ancien statut "solde" n'existe plus, on le ramene a "actif".
      await db.execute('''
        CREATE TABLE motos_new (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          nom TEXT NOT NULL,
          chauffeur TEXT NOT NULL,
          montant_versement REAL NOT NULL,
          frequence_type TEXT NOT NULL,
          frequence_valeur INTEGER NOT NULL,
          date_debut TEXT NOT NULL,
          statut TEXT NOT NULL,
          date_creation TEXT NOT NULL,
          notes TEXT
        )
      ''');
      await db.execute('''
        INSERT INTO motos_new (id, nom, chauffeur, montant_versement, frequence_type,
                                frequence_valeur, date_debut, statut, date_creation, notes)
        SELECT id, nom, chauffeur, montant_versement, frequence_type, frequence_valeur,
               date_debut,
               CASE WHEN statut = 'solde' THEN 'actif' ELSE statut END,
               date_creation, notes
        FROM motos
      ''');
      await db.execute('DROP TABLE motos');
      await db.execute('ALTER TABLE motos_new RENAME TO motos');
    }

    if (oldVersion < 3) {
      // v3 : systeme generique de "categories d'activite" (ex: Boutiques),
      // a cote de Motos qui reste inchange. Purement additif.
      await db.execute('ALTER TABLE parametres ADD COLUMN categorie_active_id INTEGER');
      await _creerTablesCategoriesActivite(db);
    }

    if (oldVersion < 4) {
      // v4 : suivi des dettes personnelles. Purement additif.
      await _creerTablesDettes(db);
    }
  }

  /// Tables du systeme generique de categories d'activite (ex: Boutiques),
  /// separe de Motos. Regroupe ici car cree a la fois dans [_onCreate]
  /// (nouvelle installation) et dans [_onUpgrade] (v3, installation
  /// existante) — les deux doivent aboutir au meme schema.
  Future<void> _creerTablesCategoriesActivite(Database db) async {
    await db.execute('''
      CREATE TABLE categories_activite (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nom TEXT NOT NULL,
        couleur TEXT NOT NULL,
        devise_symbole TEXT NOT NULL,
        date_creation TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE categorie_champs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        categorie_id INTEGER NOT NULL,
        niveau TEXT NOT NULL,
        nom TEXT NOT NULL,
        type TEXT NOT NULL,
        options TEXT,
        ordre INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (categorie_id) REFERENCES categories_activite (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE categorie_entites (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        categorie_id INTEGER NOT NULL,
        nom TEXT NOT NULL,
        statut TEXT NOT NULL,
        date_creation TEXT NOT NULL,
        notes TEXT,
        FOREIGN KEY (categorie_id) REFERENCES categories_activite (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE categorie_entite_valeurs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entite_id INTEGER NOT NULL,
        champ_id INTEGER NOT NULL,
        valeur TEXT,
        FOREIGN KEY (entite_id) REFERENCES categorie_entites (id),
        FOREIGN KEY (champ_id) REFERENCES categorie_champs (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE categorie_transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entite_id INTEGER NOT NULL,
        type TEXT NOT NULL,
        montant REAL NOT NULL,
        date TEXT NOT NULL,
        description TEXT,
        FOREIGN KEY (entite_id) REFERENCES categorie_entites (id)
      )
    ''');

    await db.execute('''
      CREATE TABLE categorie_transaction_valeurs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        transaction_id INTEGER NOT NULL,
        champ_id INTEGER NOT NULL,
        valeur TEXT,
        FOREIGN KEY (transaction_id) REFERENCES categorie_transactions (id),
        FOREIGN KEY (champ_id) REFERENCES categorie_champs (id)
      )
    ''');
  }

  /// Tables du suivi des dettes personnelles, separe du systeme de
  /// categories generique. [lien_type]/[lien_id] referencent
  /// optionnellement une moto ou une entite de categorie (aucune
  /// contrainte FOREIGN KEY stricte ici : la cible depend de lien_type).
  Future<void> _creerTablesDettes(Database db) async {
    await db.execute('''
      CREATE TABLE dettes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nom_personne TEXT NOT NULL,
        montant_initial REAL NOT NULL,
        date TEXT NOT NULL,
        notes TEXT,
        date_creation TEXT NOT NULL,
        lien_type TEXT,
        lien_id INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE dette_remboursements (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        dette_id INTEGER NOT NULL,
        montant REAL NOT NULL,
        date TEXT NOT NULL,
        notes TEXT,
        FOREIGN KEY (dette_id) REFERENCES dettes (id)
      )
    ''');
  }

  // ---------------------------------------------------------------------
  // MOTOS
  // ---------------------------------------------------------------------

  Future<int> insererMoto(Moto moto) async {
    final db = await database;
    return db.insert('motos', moto.toMap()..remove('id'));
  }

  Future<int> modifierMoto(Moto moto) async {
    final db = await database;
    return db.update('motos', moto.toMap(), where: 'id = ?', whereArgs: [moto.id]);
  }

  /// Supprime definitivement une moto ainsi que tout son historique
  /// (versements, depenses). Irreversible : a n'appeler qu'apres
  /// confirmation explicite de l'utilisateur.
  ///
  /// Note : les FOREIGN KEY ... ON DELETE CASCADE du schema ne sont pas
  /// appliquees par sqflite (PRAGMA foreign_keys n'est jamais active ici),
  /// donc le nettoyage des tables liees se fait explicitement ci-dessous.
  Future<void> supprimerMoto(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('versements', where: 'moto_id = ?', whereArgs: [id]);
      await txn.delete('depenses', where: 'moto_id = ?', whereArgs: [id]);
      await txn.delete('motos', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// Supprime TOUTES les motos, versements et depenses (utilise pour un
  /// import Excel en mode "remplacement complet"). Les reglages et les
  /// categories de depenses sont conserves. Irreversible.
  Future<void> viderToutesLesDonnees() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('versements');
      await txn.delete('depenses');
      await txn.delete('motos');
    });
  }

  Future<List<Moto>> listerMotos({String? statut}) async {
    final db = await database;
    final maps = await db.query(
      'motos',
      where: statut != null ? 'statut = ?' : null,
      whereArgs: statut != null ? [statut] : null,
      orderBy: 'date_creation DESC',
    );
    return maps.map((m) => Moto.fromMap(m)).toList();
  }

  Future<Moto?> obtenirMoto(int id) async {
    final db = await database;
    final maps = await db.query('motos', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Moto.fromMap(maps.first);
  }

  // ---------------------------------------------------------------------
  // VERSEMENTS
  // ---------------------------------------------------------------------

  Future<int> insererVersement(Versement v) async {
    final db = await database;
    return db.insert('versements', v.toMap()..remove('id'));
  }

  Future<void> insererVersements(List<Versement> versements) async {
    final db = await database;
    final batch = db.batch();
    for (final v in versements) {
      batch.insert('versements', v.toMap()..remove('id'));
    }
    await batch.commit(noResult: true);
  }

  Future<int> modifierVersement(Versement v) async {
    final db = await database;
    return db.update('versements', v.toMap(), where: 'id = ?', whereArgs: [v.id]);
  }

  /// Valide un versement : marque payé, fixe la date de validation
  /// et permet d'ajuster le montant réellement versé si besoin.
  Future<void> validerVersement(int versementId, {double? montantPaye}) async {
    final db = await database;
    final maps = await db.query('versements', where: 'id = ?', whereArgs: [versementId]);
    if (maps.isEmpty) return;
    final v = Versement.fromMap(maps.first);
    final vMisAJour = v.copyWith(
      statut: AppConstants.versementPaye,
      dateValidation: DateTime.now(),
      montantPaye: montantPaye ?? v.montantPrevu,
    );
    await modifierVersement(vMisAJour);
  }

  /// Corrige le montant reellement recu pour un versement deja valide
  /// (erreur de saisie du gerant), sans toucher a son statut ni sa date
  /// de validation.
  Future<void> modifierMontantPaye(int versementId, double nouveauMontant) async {
    final db = await database;
    await db.update(
      'versements',
      {'montant_paye': nouveauMontant},
      where: 'id = ?',
      whereArgs: [versementId],
    );
  }

  /// Annule la validation d'un versement marque paye par erreur : il
  /// redevient "en_attente", ou "en_retard" si son echeance est deja
  /// passee.
  Future<void> annulerValidationVersement(int versementId) async {
    final db = await database;
    final maps = await db.query('versements', where: 'id = ?', whereArgs: [versementId]);
    if (maps.isEmpty) return;
    final v = Versement.fromMap(maps.first);
    final nouveauStatut = v.dateEcheance.isBefore(DateTime.now())
        ? AppConstants.versementEnRetard
        : AppConstants.versementEnAttente;
    await db.update(
      'versements',
      {
        'statut': nouveauStatut,
        'date_validation': null,
        'montant_paye': null,
      },
      where: 'id = ?',
      whereArgs: [versementId],
    );
  }

  /// Recalcule les statuts "en_attente" -> "en_retard" pour les échéances
  /// dépassées. À appeler au démarrage de l'app et sur pull-to-refresh.
  /// Ne fait basculer en "en_retard" que les echeances des motos encore
  /// actives : une moto suspendue/archivee (hors service) ne doit plus
  /// accumuler de retard au fil du temps qui passe.
  Future<void> actualiserRetards() async {
    final db = await database;
    final aujourdHui = DateTime.now().toIso8601String();
    await db.rawUpdate(
      'UPDATE versements SET statut = ? '
      'WHERE statut = ? AND date_echeance < ? '
      'AND moto_id IN (SELECT id FROM motos WHERE statut = ?)',
      [
        AppConstants.versementEnRetard,
        AppConstants.versementEnAttente,
        aujourdHui,
        AppConstants.motoActive,
      ],
    );
  }

  Future<List<Versement>> listerVersementsParMoto(int motoId) async {
    final db = await database;
    final maps = await db.query(
      'versements',
      where: 'moto_id = ?',
      whereArgs: [motoId],
      orderBy: 'date_echeance DESC',
    );
    return maps.map((m) => Versement.fromMap(m)).toList();
  }

  Future<Versement?> prochainVersement(int motoId) async {
    final db = await database;
    final maps = await db.query(
      'versements',
      where: 'moto_id = ? AND statut != ?',
      whereArgs: [motoId, AppConstants.versementPaye],
      orderBy: 'date_echeance ASC',
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Versement.fromMap(maps.first);
  }

  /// Liste des versements récents (tous statuts) avec filtres optionnels
  /// par moto et par période — alimente l'activité récente de l'accueil.
  Future<List<Versement>> listerVersementsRecents({
    int? motoId,
    DateTime? debut,
    DateTime? fin,
    int limite = 20,
  }) async {
    final db = await database;
    final conditions = <String>[];
    final args = <dynamic>[];

    if (motoId != null) {
      conditions.add('moto_id = ?');
      args.add(motoId);
    }
    if (debut != null) {
      conditions.add('date_echeance >= ?');
      args.add(debut.toIso8601String());
    }
    if (fin != null) {
      conditions.add('date_echeance <= ?');
      args.add(fin.toIso8601String());
    }

    final maps = await db.query(
      'versements',
      where: conditions.isNotEmpty ? conditions.join(' AND ') : null,
      whereArgs: conditions.isNotEmpty ? args : null,
      orderBy: 'date_echeance DESC',
      limit: limite,
    );
    return maps.map((m) => Versement.fromMap(m)).toList();
  }

  /// Somme des versements payés, avec filtres optionnels.
  Future<double> totalEncaisse({int? motoId, DateTime? debut, DateTime? fin}) async {
    final db = await database;
    final conditions = <String>["statut = ?"];
    final args = <dynamic>[AppConstants.versementPaye];

    if (motoId != null) {
      conditions.add('moto_id = ?');
      args.add(motoId);
    }
    if (debut != null) {
      conditions.add('date_validation >= ?');
      args.add(debut.toIso8601String());
    }
    if (fin != null) {
      conditions.add('date_validation <= ?');
      args.add(fin.toIso8601String());
    }

    final result = await db.rawQuery(
      'SELECT COALESCE(SUM(montant_paye), 0) as total FROM versements WHERE ${conditions.join(' AND ')}',
      args,
    );
    return (result.first['total'] as num).toDouble();
  }

  /// Solde net (d'une moto si [motoId] est fourni, sinon global) : positif
  /// si plus a ete verse que ce qui etait du jusqu'a aujourd'hui (avance),
  /// negatif si de l'argent est du (retard). A la difference d'une simple
  /// somme des echeances au statut "en_retard", ce calcul tient aussi
  /// compte des versements partiels sur des echeances marquees payees
  /// (le manque n'est alors plus "perdu") et des versements superieurs au
  /// montant prevu (le credit se reporte sur les echeances suivantes).
  ///
  /// Le montant du (totalDu) ne compte que les echeances des motos encore
  /// actives : une moto suspendue/archivee ne doit plus voir son retard
  /// grossir avec le temps qui passe pendant qu'elle est hors service.
  /// Le montant recu (totalRecu), lui, reste toujours comptabilise quel
  /// que soit le statut actuel de la moto — l'argent deja encaisse ne
  /// disparait pas quand on met une moto en pause.
  Future<double> soldeNet({int? motoId}) async {
    final db = await database;
    final aujourdHui = DateTime.now().toIso8601String();

    final recuConditions = <String>['statut = ?'];
    final recuArgs = <dynamic>[AppConstants.versementPaye];
    if (motoId != null) {
      recuConditions.add('moto_id = ?');
      recuArgs.add(motoId);
    }
    final recu = await db.rawQuery(
      'SELECT COALESCE(SUM(montant_paye), 0) as total FROM versements WHERE ${recuConditions.join(' AND ')}',
      recuArgs,
    );

    final duConditions = <String>[
      'date_echeance <= ?',
      'moto_id IN (SELECT id FROM motos WHERE statut = ?)',
    ];
    final duArgs = <dynamic>[aujourdHui, AppConstants.motoActive];
    if (motoId != null) {
      duConditions.add('moto_id = ?');
      duArgs.add(motoId);
    }
    final du = await db.rawQuery(
      'SELECT COALESCE(SUM(montant_prevu), 0) as total FROM versements WHERE ${duConditions.join(' AND ')}',
      duArgs,
    );

    final totalRecu = (recu.first['total'] as num).toDouble();
    final totalDu = (du.first['total'] as num).toDouble();
    return totalRecu - totalDu;
  }

  /// Total des versements reçus (payés), regroupé par période, pour les
  /// statistiques. [periode] vaut 'semaine' | 'mois' | 'annee'. Retourne les
  /// [nombrePeriodes] dernières périodes, clé = date de début de période,
  /// triées du plus ancien au plus récent, avec 0 pour les périodes sans
  /// versement (pour un graphique continu).
  Future<List<MapEntry<DateTime, double>>> totalEncaisseParPeriode({
    required String periode,
    int? motoId,
    int nombrePeriodes = 8,
  }) async {
    final maintenant = DateTime.now();
    final aujourdHui = DateTime(maintenant.year, maintenant.month, maintenant.day);

    DateTime cleDe(DateTime d) {
      switch (periode) {
        case 'semaine':
          final lundi = d.subtract(Duration(days: d.weekday - 1));
          return DateTime(lundi.year, lundi.month, lundi.day);
        case 'trimestre':
          return DateTime(d.year, ((d.month - 1) ~/ 3) * 3 + 1);
        case 'semestre':
          return DateTime(d.year, d.month <= 6 ? 1 : 7);
        case 'annee':
          return DateTime(d.year);
        case 'mois':
        default:
          return DateTime(d.year, d.month);
      }
    }

    DateTime periodePrecedente(DateTime cle) {
      switch (periode) {
        case 'semaine':
          return cle.subtract(const Duration(days: 7));
        case 'trimestre':
          return DateTime(cle.year, cle.month - 3);
        case 'semestre':
          return DateTime(cle.year, cle.month - 6);
        case 'annee':
          return DateTime(cle.year - 1);
        case 'mois':
        default:
          return DateTime(cle.year, cle.month - 1);
      }
    }

    final cleActuelle = cleDe(aujourdHui);
    final cles = <DateTime>[cleActuelle];
    for (var i = 1; i < nombrePeriodes; i++) {
      cles.insert(0, periodePrecedente(cles.first));
    }
    final debut = cles.first;

    final db = await database;
    final conditions = <String>["statut = ?", "date_validation >= ?"];
    final args = <dynamic>[AppConstants.versementPaye, debut.toIso8601String()];
    if (motoId != null) {
      conditions.add('moto_id = ?');
      args.add(motoId);
    }
    final maps = await db.query(
      'versements',
      where: conditions.join(' AND '),
      whereArgs: args,
    );

    final totauxParCle = {for (final c in cles) c: 0.0};
    for (final m in maps) {
      final v = Versement.fromMap(m);
      if (v.dateValidation == null) continue;
      final cle = cleDe(v.dateValidation!);
      if (totauxParCle.containsKey(cle)) {
        totauxParCle[cle] = totauxParCle[cle]! + (v.montantPaye ?? 0);
      }
    }

    return cles.map((c) => MapEntry(c, totauxParCle[c] ?? 0.0)).toList();
  }

  /// Garantit qu'il existe toujours au moins [_tailleFenetreEcheances]
  /// échéances non payées à venir pour cette moto : génère les suivantes
  /// si besoin, en repartant de la dernière échéance connue (ou de la
  /// date de début si c'est la toute première). Les versements étant
  /// récurrents et indéfinis, cette fenêtre glissante remplace l'ancien
  /// plan fini basé sur un montant total.
  Future<void> assurerEcheances(Moto moto) async {
    if (moto.id == null) return;
    final existants = await listerVersementsParMoto(moto.id!); // tri date DESC
    final enCours = existants.where((v) => v.statut != AppConstants.versementPaye).length;
    if (enCours >= _tailleFenetreEcheances) return;

    DateTime prochaine;
    if (existants.isEmpty) {
      prochaine = ScheduleService.premiereEcheance(
        dateDebut: moto.dateDebut,
        type: moto.frequenceType,
        valeur: moto.frequenceValeur,
      );
    } else {
      prochaine = ScheduleService.echeanceSuivante(
        dateActuelle: existants.first.dateEcheance,
        type: moto.frequenceType,
        valeur: moto.frequenceValeur,
      );
    }

    final nouvelles = <Versement>[];
    for (var i = 0; i < _tailleFenetreEcheances - enCours; i++) {
      nouvelles.add(Versement(
        motoId: moto.id!,
        dateEcheance: prochaine,
        montantPrevu: moto.montantVersement,
        statut: AppConstants.versementEnAttente,
      ));
      prochaine = ScheduleService.echeanceSuivante(
        dateActuelle: prochaine,
        type: moto.frequenceType,
        valeur: moto.frequenceValeur,
      );
    }
    await insererVersements(nouvelles);
  }

  /// A appeler quand une moto est reactivee apres une pause (suspension).
  /// Les echeances encore non payees qui dataient d'avant la pause ne
  /// doivent pas etre comptees comme du retard : la moto n'a pas
  /// travaille pendant ce temps, c'est justement pour ca qu'elle avait
  /// ete mise en pause. On les retire (l'historique deja paye n'est
  /// jamais touche) et on redemarre une fenetre fraiche a partir
  /// d'aujourd'hui, pas de la date ou elle s'etait arretee.
  Future<void> redemarrerEcheancesApresReactivation(Moto moto) async {
    if (moto.id == null) return;
    final db = await database;
    await db.delete(
      'versements',
      where: 'moto_id = ? AND statut != ?',
      whereArgs: [moto.id, AppConstants.versementPaye],
    );

    final aujourdHui = DateTime.now();
    var prochaine = ScheduleService.premiereEcheance(
      dateDebut: aujourdHui,
      type: moto.frequenceType,
      valeur: moto.frequenceValeur,
    );
    // Filet de securite : pour la frequence mensuelle, premiereEcheance()
    // peut retomber plus tot dans le mois courant que la date du jour.
    while (prochaine.isBefore(aujourdHui)) {
      prochaine = ScheduleService.echeanceSuivante(
        dateActuelle: prochaine,
        type: moto.frequenceType,
        valeur: moto.frequenceValeur,
      );
    }

    final nouvelles = <Versement>[];
    for (var i = 0; i < _tailleFenetreEcheances; i++) {
      nouvelles.add(Versement(
        motoId: moto.id!,
        dateEcheance: prochaine,
        montantPrevu: moto.montantVersement,
        statut: AppConstants.versementEnAttente,
      ));
      prochaine = ScheduleService.echeanceSuivante(
        dateActuelle: prochaine,
        type: moto.frequenceType,
        valeur: moto.frequenceValeur,
      );
    }
    await insererVersements(nouvelles);
  }

  // ---------------------------------------------------------------------
  // CATEGORIES DE DEPENSES
  // ---------------------------------------------------------------------

  Future<List<CategorieDepense>> listerCategories() async {
    final db = await database;
    final maps = await db.query('categories_depenses', orderBy: 'nom ASC');
    return maps.map((m) => CategorieDepense.fromMap(m)).toList();
  }

  Future<int> insererCategorie(CategorieDepense cat) async {
    final db = await database;
    return db.insert('categories_depenses', cat.toMap()..remove('id'));
  }

  Future<int> supprimerCategorie(int id) async {
    final db = await database;
    return db.delete('categories_depenses', where: 'id = ?', whereArgs: [id]);
  }

  // ---------------------------------------------------------------------
  // DEPENSES
  // ---------------------------------------------------------------------

  Future<int> insererDepense(Depense d) async {
    final db = await database;
    return db.insert('depenses', d.toMap()..remove('id'));
  }

  Future<int> modifierDepense(Depense d) async {
    final db = await database;
    return db.update('depenses', d.toMap(), where: 'id = ?', whereArgs: [d.id]);
  }

  Future<int> supprimerDepense(int id) async {
    final db = await database;
    return db.delete('depenses', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Depense>> listerDepensesParMoto(int motoId) async {
    final db = await database;
    final maps = await db.query(
      'depenses',
      where: 'moto_id = ?',
      whereArgs: [motoId],
      orderBy: 'date DESC',
    );
    return maps.map((m) => Depense.fromMap(m)).toList();
  }

  Future<List<Depense>> listerDepensesRecentes({int? motoId, int limite = 20}) async {
    final db = await database;
    final maps = await db.query(
      'depenses',
      where: motoId != null ? 'moto_id = ?' : null,
      whereArgs: motoId != null ? [motoId] : null,
      orderBy: 'date DESC',
      limit: limite,
    );
    return maps.map((m) => Depense.fromMap(m)).toList();
  }

  Future<double> totalDepenses({int? motoId, DateTime? debut, DateTime? fin}) async {
    final db = await database;
    final conditions = <String>[];
    final args = <dynamic>[];
    if (motoId != null) {
      conditions.add('moto_id = ?');
      args.add(motoId);
    }
    if (debut != null) {
      conditions.add('date >= ?');
      args.add(debut.toIso8601String());
    }
    if (fin != null) {
      conditions.add('date <= ?');
      args.add(fin.toIso8601String());
    }
    final where = conditions.isNotEmpty ? 'WHERE ${conditions.join(' AND ')}' : '';
    final result = await db.rawQuery(
      'SELECT COALESCE(SUM(montant), 0) as total FROM depenses $where',
      args,
    );
    return (result.first['total'] as num).toDouble();
  }

  // ---------------------------------------------------------------------
  // PARAMETRES
  // ---------------------------------------------------------------------

  Future<Parametre> obtenirParametres() async {
    final db = await database;
    final maps = await db.query('parametres', where: 'id = ?', whereArgs: [1]);
    if (maps.isEmpty) {
      final p = Parametre();
      await db.insert('parametres', p.toMap());
      return p;
    }
    return Parametre.fromMap(maps.first);
  }

  Future<void> enregistrerParametres(Parametre p) async {
    final db = await database;
    await db.update('parametres', p.toMap(), where: 'id = ?', whereArgs: [1]);
  }

  /// Change la categorie active (null = revient a Motos). Ecriture directe
  /// car [Parametre.copyWith] ne peut pas remettre ce champ a null.
  Future<void> definirCategorieActive(int? categorieId) async {
    final db = await database;
    await db.update('parametres', {'categorie_active_id': categorieId}, where: 'id = ?', whereArgs: [1]);
  }

  // ---------------------------------------------------------------------
  // CATEGORIES D'ACTIVITE GENERIQUES (ex: Boutiques) — separe de Motos.
  // ---------------------------------------------------------------------

  Future<int> insererCategorieActivite(CategorieActivite c) async {
    final db = await database;
    return db.insert('categories_activite', c.toMap()..remove('id'));
  }

  Future<int> modifierCategorieActivite(CategorieActivite c) async {
    final db = await database;
    return db.update('categories_activite', c.toMap(), where: 'id = ?', whereArgs: [c.id]);
  }

  Future<List<CategorieActivite>> listerCategoriesActivite() async {
    final db = await database;
    final maps = await db.query('categories_activite', orderBy: 'nom ASC');
    return maps.map((m) => CategorieActivite.fromMap(m)).toList();
  }

  Future<CategorieActivite?> obtenirCategorieActivite(int id) async {
    final db = await database;
    final maps = await db.query('categories_activite', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return CategorieActivite.fromMap(maps.first);
  }

  /// Supprime definitivement une categorie et tout ce qu'elle contient
  /// (champs, entites, transactions, valeurs). Irreversible. Si c'etait la
  /// categorie active, revient automatiquement sur Motos.
  Future<void> supprimerCategorieActivite(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      final entites = await txn.query('categorie_entites', columns: ['id'], where: 'categorie_id = ?', whereArgs: [id]);
      for (final e in entites) {
        final entiteId = e['id'] as int;
        final transactions = await txn.query('categorie_transactions',
            columns: ['id'], where: 'entite_id = ?', whereArgs: [entiteId]);
        for (final t in transactions) {
          await txn.delete('categorie_transaction_valeurs', where: 'transaction_id = ?', whereArgs: [t['id']]);
        }
        await txn.delete('categorie_transactions', where: 'entite_id = ?', whereArgs: [entiteId]);
        await txn.delete('categorie_entite_valeurs', where: 'entite_id = ?', whereArgs: [entiteId]);
      }
      await txn.delete('categorie_entites', where: 'categorie_id = ?', whereArgs: [id]);
      await txn.delete('categorie_champs', where: 'categorie_id = ?', whereArgs: [id]);
      await txn.delete('categories_activite', where: 'id = ?', whereArgs: [id]);
      await txn.update('parametres', {'categorie_active_id': null},
          where: 'id = ? AND categorie_active_id = ?', whereArgs: [1, id]);
    });
  }

  // -- Entites --

  Future<int> insererEntiteCategorie(CategorieEntite e) async {
    final db = await database;
    return db.insert('categorie_entites', e.toMap()..remove('id'));
  }

  Future<int> modifierEntiteCategorie(CategorieEntite e) async {
    final db = await database;
    return db.update('categorie_entites', e.toMap(), where: 'id = ?', whereArgs: [e.id]);
  }

  /// Supprime une entite et tout son historique (transactions, valeurs de
  /// champs). Irreversible.
  Future<void> supprimerEntiteCategorie(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      final transactions =
          await txn.query('categorie_transactions', columns: ['id'], where: 'entite_id = ?', whereArgs: [id]);
      for (final t in transactions) {
        await txn.delete('categorie_transaction_valeurs', where: 'transaction_id = ?', whereArgs: [t['id']]);
      }
      await txn.delete('categorie_transactions', where: 'entite_id = ?', whereArgs: [id]);
      await txn.delete('categorie_entite_valeurs', where: 'entite_id = ?', whereArgs: [id]);
      await txn.delete('categorie_entites', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<CategorieEntite>> listerEntitesCategorie(int categorieId) async {
    final db = await database;
    final maps = await db.query(
      'categorie_entites',
      where: 'categorie_id = ?',
      whereArgs: [categorieId],
      orderBy: 'date_creation DESC',
    );
    return maps.map((m) => CategorieEntite.fromMap(m)).toList();
  }

  Future<CategorieEntite?> obtenirEntiteCategorie(int id) async {
    final db = await database;
    final maps = await db.query('categorie_entites', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return CategorieEntite.fromMap(maps.first);
  }

  // -- Transactions (revenus/depenses generiques) --

  Future<int> insererTransactionCategorie(CategorieTransaction t) async {
    final db = await database;
    return db.insert('categorie_transactions', t.toMap()..remove('id'));
  }

  Future<int> modifierTransactionCategorie(CategorieTransaction t) async {
    final db = await database;
    return db.update('categorie_transactions', t.toMap(), where: 'id = ?', whereArgs: [t.id]);
  }

  Future<void> supprimerTransactionCategorie(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('categorie_transaction_valeurs', where: 'transaction_id = ?', whereArgs: [id]);
      await txn.delete('categorie_transactions', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<CategorieTransaction>> listerTransactionsEntite(int entiteId) async {
    final db = await database;
    final maps = await db.query(
      'categorie_transactions',
      where: 'entite_id = ?',
      whereArgs: [entiteId],
      orderBy: 'date DESC',
    );
    return maps.map((m) => CategorieTransaction.fromMap(m)).toList();
  }

  /// Toutes les transactions d'une categorie, toutes entites confondues
  /// (utilise pour l'export Excel).
  Future<List<CategorieTransaction>> listerTransactionsCategorie(int categorieId) async {
    final db = await database;
    final maps = await db.rawQuery(
      'SELECT ct.* FROM categorie_transactions ct '
      'JOIN categorie_entites ce ON ce.id = ct.entite_id '
      'WHERE ce.categorie_id = ? ORDER BY ct.date DESC',
      [categorieId],
    );
    return maps.map((m) => CategorieTransaction.fromMap(m)).toList();
  }

  /// Efface les entites et transactions d'une categorie (pas la categorie
  /// elle-meme) — utilise pour un import Excel en mode "tout remplacer"
  /// scope a cette seule categorie.
  Future<void> viderDonneesCategorie(int categorieId) async {
    final db = await database;
    await db.transaction((txn) async {
      final entites =
          await txn.query('categorie_entites', columns: ['id'], where: 'categorie_id = ?', whereArgs: [categorieId]);
      for (final e in entites) {
        await txn.delete('categorie_transactions', where: 'entite_id = ?', whereArgs: [e['id']]);
      }
      await txn.delete('categorie_entites', where: 'categorie_id = ?', whereArgs: [categorieId]);
    });
  }

  // -- Agregats --

  /// Solde d'une entite : total des revenus moins total des depenses.
  Future<double> soldeEntiteCategorie(int entiteId) async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT type, COALESCE(SUM(montant), 0) as total FROM categorie_transactions "
      "WHERE entite_id = ? GROUP BY type",
      [entiteId],
    );
    double revenus = 0;
    double depenses = 0;
    for (final r in result) {
      final total = (r['total'] as num).toDouble();
      if (r['type'] == AppConstants.transactionRevenu) {
        revenus = total;
      } else if (r['type'] == AppConstants.transactionDepense) {
        depenses = total;
      }
    }
    return revenus - depenses;
  }

  /// Totaux (revenus, depenses) sur l'ensemble d'une categorie, toutes
  /// entites confondues — pour le tableau de bord de la categorie.
  Future<({double revenus, double depenses})> totauxCategorie(int categorieId) async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT ct.type as type, COALESCE(SUM(ct.montant), 0) as total "
      "FROM categorie_transactions ct "
      "JOIN categorie_entites ce ON ce.id = ct.entite_id "
      "WHERE ce.categorie_id = ? GROUP BY ct.type",
      [categorieId],
    );
    double revenus = 0;
    double depenses = 0;
    for (final r in result) {
      final total = (r['total'] as num).toDouble();
      if (r['type'] == AppConstants.transactionRevenu) {
        revenus = total;
      } else if (r['type'] == AppConstants.transactionDepense) {
        depenses = total;
      }
    }
    return (revenus: revenus, depenses: depenses);
  }

  // ---------------------------------------------------------------------
  // DETTES (suivi personnel, separe du systeme de categories generique)
  // ---------------------------------------------------------------------

  Future<int> insererDette(Dette d) async {
    final db = await database;
    return db.insert('dettes', d.toMap()..remove('id'));
  }

  Future<int> modifierDette(Dette d) async {
    final db = await database;
    return db.update('dettes', d.toMap(), where: 'id = ?', whereArgs: [d.id]);
  }

  Future<void> supprimerDette(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('dette_remboursements', where: 'dette_id = ?', whereArgs: [id]);
      await txn.delete('dettes', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// Efface toutes les dettes et remboursements — utilise pour un import
  /// Excel en mode "tout remplacer" scope aux dettes.
  Future<void> viderDettes() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('dette_remboursements');
      await txn.delete('dettes');
    });
  }

  Future<List<Dette>> listerDettes() async {
    final db = await database;
    final maps = await db.query('dettes', orderBy: 'date DESC');
    return maps.map((m) => Dette.fromMap(m)).toList();
  }

  /// Dettes rattachees a une moto ou a une entite de categorie precise.
  Future<List<Dette>> listerDettesParLien(String lienType, int lienId) async {
    final db = await database;
    final maps = await db.query(
      'dettes',
      where: 'lien_type = ? AND lien_id = ?',
      whereArgs: [lienType, lienId],
      orderBy: 'date DESC',
    );
    return maps.map((m) => Dette.fromMap(m)).toList();
  }

  Future<Dette?> obtenirDette(int id) async {
    final db = await database;
    final maps = await db.query('dettes', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Dette.fromMap(maps.first);
  }

  Future<int> insererRemboursement(DetteRemboursement r) async {
    final db = await database;
    return db.insert('dette_remboursements', r.toMap()..remove('id'));
  }

  Future<int> modifierRemboursement(DetteRemboursement r) async {
    final db = await database;
    return db.update('dette_remboursements', r.toMap(), where: 'id = ?', whereArgs: [r.id]);
  }

  Future<void> supprimerRemboursement(int id) async {
    final db = await database;
    await db.delete('dette_remboursements', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<DetteRemboursement>> listerRemboursements(int detteId) async {
    final db = await database;
    final maps = await db.query('dette_remboursements', where: 'dette_id = ?', whereArgs: [detteId], orderBy: 'date DESC');
    return maps.map((m) => DetteRemboursement.fromMap(m)).toList();
  }

  /// Montant restant du pour une dette : montant initial moins la somme
  /// des remboursements recus. 0 (ou moins, si trop rembourse) = soldee.
  Future<double> soldeDette(int detteId) async {
    final db = await database;
    final dette = await obtenirDette(detteId);
    if (dette == null) return 0;
    final result = await db.rawQuery(
      'SELECT COALESCE(SUM(montant), 0) as total FROM dette_remboursements WHERE dette_id = ?',
      [detteId],
    );
    final totalRembourse = (result.first['total'] as num).toDouble();
    return dette.montantInitial - totalRembourse;
  }

  /// Somme des montants encore dus, toutes dettes non soldees confondues.
  Future<double> totalDettesEnCours() async {
    final db = await database;
    final dettes = await db.query('dettes');
    double total = 0;
    for (final map in dettes) {
      final dette = Dette.fromMap(map);
      if (dette.id == null) continue;
      final solde = await soldeDette(dette.id!);
      if (solde > 0) total += solde;
    }
    return total;
  }
}
