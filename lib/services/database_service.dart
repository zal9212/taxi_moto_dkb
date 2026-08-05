import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../core/constants.dart';
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
        delai_notification_heures INTEGER NOT NULL DEFAULT 24
      )
    ''');

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
  Future<void> actualiserRetards() async {
    final db = await database;
    final aujourdHui = DateTime.now().toIso8601String();
    await db.update(
      'versements',
      {'statut': AppConstants.versementEnRetard},
      where: 'statut = ? AND date_echeance < ?',
      whereArgs: [AppConstants.versementEnAttente, aujourdHui],
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

    final duConditions = <String>['date_echeance <= ?'];
    final duArgs = <dynamic>[aujourdHui];
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
}
