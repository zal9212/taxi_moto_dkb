import 'dart:typed_data';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../core/constants.dart';
import '../models/categorie_activite.dart';
import '../models/categorie_entite.dart';
import '../models/categorie_gerant.dart';
import '../models/categorie_transaction.dart';
import '../models/dette.dart';
import '../models/moto.dart';
import '../models/versement.dart';
import '../models/depense.dart';
import '../models/parametre.dart';
import '../utils/formatters.dart';
import 'schedule_service.dart';

/// Point d'accès unique à la base SQLite locale.
/// Toute lecture/écriture de l'app passe par ce service (singleton).
class DatabaseService {
  DatabaseService._internal();
  static final DatabaseService instance = DatabaseService._internal();

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
    // File neuve : une operation en attente visait la base qu'on ferme (et
    // en test, sa suite peut rester liee a une horloge simulee terminee).
    _fileEcheances = Future.value();
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
        dette_id INTEGER,
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

    await _creerTableDevises(db);
    await db.insert('devises', {'code': AppConstants.devisePardDefaut});
    await _creerTablePaiements(db);
    await _creerTableMontantsMoto(db);
  }

  /// Historique des changements du montant de versement d'une moto (voir
  /// [changerMontant]). [motos.montant_versement] reste le montant de depart.
  Future<void> _creerTableMontantsMoto(Database db) async {
    await db.execute('''
      CREATE TABLE montants_moto (
        moto_id INTEGER NOT NULL,
        depuis TEXT NOT NULL,
        montant REAL NOT NULL,
        PRIMARY KEY (moto_id, depuis)
      )
    ''');
  }

  /// Journal des paiements : une ligne par somme recue, a sa vraie date.
  /// [versements.montant_paye] en reste le total (tenu a jour a chaque
  /// ecriture) ; la caisse par periode et l'activite se lisent ici, pour
  /// qu'une echeance payee en plusieurs fois compte chaque somme le jour ou
  /// elle a ete recue.
  Future<void> _creerTablePaiements(Database db) async {
    await db.execute('''
      CREATE TABLE paiements (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        versement_id INTEGER NOT NULL,
        moto_id INTEGER NOT NULL,
        montant REAL NOT NULL,
        date TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_paiements_versement ON paiements (versement_id)');
  }

  /// Liste des devises proposees dans les menus (Reglages, categories,
  /// dettes) : saisies une fois, puis simplement choisies.
  Future<void> _creerTableDevises(Database db) async {
    await db.execute('CREATE TABLE devises (code TEXT PRIMARY KEY)');
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

    if (oldVersion == 4) {
      // v5 : devise propre a une dette sans lien (une dette liee garde
      // toujours la devise de la moto/entite concernee). Purement additif.
      // Seulement depuis la v4 : avant, la table dettes vient d'etre creee
      // ci-dessus avec cette colonne (l'ajouter a nouveau plantait).
      await db.execute('ALTER TABLE dettes ADD COLUMN devise_symbole TEXT');
    }

    if (oldVersion < 6) {
      // v6 : une echeance non payee peut etre "marquee en dette" (lien vers
      // la dette creee), et liste des devises a choisir. Les devises deja
      // saisies sont normalisees ("fg " -> "FG") puis reprises dans la liste.
      await db.execute('ALTER TABLE versements ADD COLUMN dette_id INTEGER');
      await _creerTableDevises(db);
      await db.execute('UPDATE parametres SET devise_symbole = UPPER(TRIM(devise_symbole))');
      await db.execute('UPDATE categories_activite SET devise_symbole = UPPER(TRIM(devise_symbole))');
      await db.execute(
          'UPDATE dettes SET devise_symbole = UPPER(TRIM(devise_symbole)) WHERE devise_symbole IS NOT NULL');
      await db.execute('''
        INSERT OR IGNORE INTO devises (code)
        SELECT devise_symbole FROM parametres WHERE devise_symbole != ''
        UNION SELECT devise_symbole FROM categories_activite WHERE devise_symbole != ''
        UNION SELECT devise_symbole FROM dettes WHERE devise_symbole IS NOT NULL AND devise_symbole != ''
      ''');
    }

    if (oldVersion < 7) {
      // v7 : journal des paiements. Chaque versement deja paye devient un
      // paiement, date de sa validation (ou de son echeance a defaut).
      await _creerTablePaiements(db);
      await db.rawInsert(
        'INSERT INTO paiements (versement_id, moto_id, montant, date) '
        'SELECT id, moto_id, montant_paye, COALESCE(date_validation, date_echeance) FROM versements '
        'WHERE statut = ? AND montant_paye IS NOT NULL AND montant_paye != 0',
        [AppConstants.versementPaye],
      );
    }

    if (oldVersion < 8) {
      // v8 : comptes par personne (proprietaire + gerants) dans une entite.
      // Les operations existantes restent au proprietaire (gerant_id null).
      await db.execute('ALTER TABLE categorie_transactions ADD COLUMN gerant_id INTEGER');
      await _creerTablesGerantsEtAudios(db);
    }

    if (oldVersion < 9) {
      // v9 : historique des montants de versement. Purement additif : sans
      // changement, le montant de la moto s'applique partout comme avant.
      await _creerTableMontantsMoto(db);
    }

    if (oldVersion < 10) {
      // v10 : une echeance "payee" sans montant (ancien import) compte comme
      // payee en entier dans le retard ; elle entre aussi dans le journal, sinon
      // le total encaisse et les statistiques l'oubliaient.
      final tables =
          (await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'")).map((t) => t['name']).toSet();
      if (tables.containsAll(['versements', 'paiements'])) {
        await db.execute(
          'INSERT INTO paiements (versement_id, moto_id, montant, date) '
          'SELECT id, moto_id, montant_prevu, COALESCE(date_validation, date_echeance) FROM versements '
          "WHERE statut = 'paye' AND montant_paye IS NULL AND id NOT IN (SELECT versement_id FROM paiements)",
        );
        await db.execute(
            "UPDATE versements SET montant_paye = montant_prevu WHERE statut = 'paye' AND montant_paye IS NULL");
      }
    }

    if (oldVersion < 11) {
      // v11 : personne concernee par une dette de boutique (null =
      // proprietaire, comme toutes les dettes d'avant).
      final tables =
          (await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'")).map((t) => t['name']).toSet();
      // Une base tres ancienne recoit deja la colonne en creant la table plus haut.
      final colonnes = tables.contains('dettes')
          ? (await db.rawQuery('PRAGMA table_info(dettes)')).map((c) => c['name']).toSet()
          : <Object?>{};
      if (tables.contains('dettes') && !colonnes.contains('gerant_id')) {
        await db.execute('ALTER TABLE dettes ADD COLUMN gerant_id INTEGER');
      }
    }
  }

  /// Gerants d'une entite et notes vocales des operations (crees dans
  /// [_onCreate] et la migration v8). Une note est a part pour ne pas
  /// charger l'audio a chaque liste d'operations.
  Future<void> _creerTablesGerantsEtAudios(Database db) async {
    await db.execute('''
      CREATE TABLE categorie_transaction_audios (
        transaction_id INTEGER PRIMARY KEY,
        audio BLOB NOT NULL,
        FOREIGN KEY (transaction_id) REFERENCES categorie_transactions (id)
      )
    ''');
    await db.execute('''
      CREATE TABLE categorie_gerants (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entite_id INTEGER NOT NULL,
        nom TEXT NOT NULL,
        statut TEXT NOT NULL,
        date_creation TEXT NOT NULL,
        FOREIGN KEY (entite_id) REFERENCES categorie_entites (id)
      )
    ''');
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
        gerant_id INTEGER,
        FOREIGN KEY (entite_id) REFERENCES categorie_entites (id)
      )
    ''');

    await _creerTablesGerantsEtAudios(db);

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
        lien_id INTEGER,
        devise_symbole TEXT,
        gerant_id INTEGER
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
    final avant = moto.id == null ? null : await obtenirMoto(moto.id!);
    // Mise en pause : une echeance dont le jour est deja arrive est une
    // semaine travaillee - elle reste due (pas une semaine de pause).
    if (avant?.statut == AppConstants.motoActive && moto.statut != AppConstants.motoActive) {
      final aujourdHui = ScheduleService.aujourdHui();
      await db.update(
        'versements',
        {'statut': AppConstants.versementEnRetard},
        where: 'moto_id = ? AND statut = ? AND date_echeance < ?',
        whereArgs: [
          moto.id,
          AppConstants.versementEnAttente,
          DateTime(aujourdHui.year, aujourdHui.month, aujourdHui.day + 1).toIso8601String(),
        ],
      );
    }
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
    final deviseGlobale = (await obtenirParametres()).deviseSymbole;
    await db.transaction((txn) async {
      await _detacherDettesMotos(txn, deviseGlobale, motoId: id);
      await txn.delete('paiements', where: 'moto_id = ?', whereArgs: [id]);
      await txn.delete('versements', where: 'moto_id = ?', whereArgs: [id]);
      await txn.delete('depenses', where: 'moto_id = ?', whereArgs: [id]);
      await txn.delete('montants_moto', where: 'moto_id = ?', whereArgs: [id]);
      await txn.delete('motos', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// Supprime TOUTES les motos, versements et depenses (utilise pour un
  /// import Excel en mode "remplacement complet"). Les reglages et les
  /// categories de depenses sont conserves. Irreversible.
  Future<void> viderToutesLesDonnees() async {
    final db = await database;
    final deviseGlobale = (await obtenirParametres()).deviseSymbole;
    await db.transaction((txn) async {
      await _detacherDettesMotos(txn, deviseGlobale);
      await txn.delete('paiements');
      await txn.delete('versements');
      await txn.delete('depenses');
      await txn.delete('montants_moto');
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

  /// Insere une echeance ; si elle est deja payee (import, saisie d'une
  /// periode passee), son paiement est ecrit dans le journal.
  Future<int> insererVersement(Versement v) async {
    final db = await database;
    return db.transaction((txn) async {
      final id = await txn.insert('versements', v.toMap()..remove('id'));
      await _reecrirePaiements(txn, id, v);
      return id;
    });
  }

  Future<void> _insererVersements(List<Versement> versements) async {
    final db = await database;
    final batch = db.batch();
    for (final v in versements) {
      batch.insert('versements', v.toMap()..remove('id'));
    }
    await batch.commit(noResult: true);
  }

  Future<Versement?> obtenirVersement(int id) async {
    final db = await database;
    final maps = await db.query('versements', where: 'id = ?', whereArgs: [id]);
    return maps.isEmpty ? null : Versement.fromMap(maps.first);
  }

  /// Echeance d'une moto a ce jour : une seule par moto et par date (cle
  /// naturelle, utilisee par l'import pour completer au lieu de dupliquer).
  Future<Versement?> trouverVersement(int motoId, DateTime jour) async {
    final db = await database;
    final debut = ScheduleService.dateSeule(jour);
    final maps = await db.query(
      'versements',
      where: 'moto_id = ? AND date_echeance >= ? AND date_echeance < ?',
      whereArgs: [motoId, debut.toIso8601String(), DateTime(debut.year, debut.month, debut.day + 1).toIso8601String()],
      limit: 1,
    );
    return maps.isEmpty ? null : Versement.fromMap(maps.first);
  }

  /// Rattache une echeance "en dette" a sa dette (import). La dette doit
  /// etre la sienne : meme chauffeur, meme date, meme montant restant, liee a
  /// cette moto ou a rien, et a aucune autre echeance — un [detteId] venant
  /// d'un fichier est verifie de la meme facon (un autre telephone a d'autres
  /// numeros). Sans dette retrouvee, l'echeance redevient due : jamais
  /// comptee a la fois en retard et dans Dettes. Retourne true si reliee.
  Future<bool> lierVersementADette(int versementId, int? detteId) async {
    final db = await database;
    final v = Versement.fromMap((await db.query('versements', where: 'id = ?', whereArgs: [versementId])).first);
    final moto = await obtenirMoto(v.motoId);
    int? id;
    if (moto != null) {
      final candidates = await db.rawQuery(
        'SELECT id FROM dettes WHERE nom_personne = ? AND date = ? AND montant_initial = ? '
        'AND (lien_type IS NULL OR (lien_type = ? AND lien_id = ?)) '
        'AND id NOT IN (SELECT dette_id FROM versements WHERE dette_id IS NOT NULL AND id != ?) '
        '${detteId != null ? 'AND id = ? ' : ''}ORDER BY id LIMIT 1',
        [
          moto.chauffeur,
          v.dateEcheance.toIso8601String(),
          v.montantPrevu - (v.montantPaye ?? 0),
          AppConstants.detteLienMoto,
          v.motoId,
          versementId,
          if (detteId != null) detteId,
        ],
      );
      if (candidates.isNotEmpty) {
        id = candidates.first['id'] as int;
        await db.update('dettes', {'lien_type': AppConstants.detteLienMoto, 'lien_id': v.motoId},
            where: 'id = ?', whereArgs: [id]);
      } else if (detteId != null) {
        return lierVersementADette(versementId, null); // ID d'un autre telephone : on cherche la sienne
      }
    }
    await db.update(
      'versements',
      id != null
          ? {'statut': AppConstants.versementEnDette, 'dette_id': id}
          : {'statut': AppConstants.versementEnRetard, 'dette_id': null},
      where: 'id = ?',
      whereArgs: [versementId],
    );
    return id != null;
  }

  /// Remboursements de chaque dette nee d'une echeance (id de l'echeance ->
  /// sommes recues, avec leur date) : a garder avant un import qui remplace
  /// les dettes.
  Future<Map<int, List<({double montant, String date})>>> remboursementsDesEcheances() async {
    final db = await database;
    final lignes = await db.rawQuery(
      'SELECT v.id AS versement_id, r.montant, r.date FROM versements v '
      'JOIN dette_remboursements r ON r.dette_id = v.dette_id WHERE v.dette_id IS NOT NULL',
    );
    final resultat = <int, List<({double montant, String date})>>{};
    for (final l in lignes) {
      resultat
          .putIfAbsent(l['versement_id'] as int, () => [])
          .add((montant: (l['montant'] as num).toDouble(), date: l['date'] as String));
    }
    return resultat;
  }

  /// Une echeance qui ne retrouve pas sa dette apres un import : les sommes
  /// deja recues sur cette dette deviennent ses paiements, a leur date.
  Future<void> rendreRemboursementsAEcheance(int versementId, List<({double montant, String date})> argent) =>
      _enFile(() async {
        final db = await database;
        final maps = await db.query('versements', where: 'id = ?', whereArgs: [versementId]);
        if (maps.isEmpty) return;
        final v = Versement.fromMap(maps.first);
        await db.transaction((txn) => _rendreEcheanceDue(txn, v, argent: argent));
        await _normaliser(v.motoId);
      });

  /// Dette nee d'une echeance de moto ("Marquer en dette") : son lien et son
  /// montant viennent de l'echeance et ne se modifient pas a la main.
  Future<bool> detteVientDUneEcheance(int detteId) async {
    final db = await database;
    return (await db.query('versements', columns: ['id'], where: 'dette_id = ?', whereArgs: [detteId], limit: 1))
        .isNotEmpty;
  }

  /// Journal des paiements d'une moto : chaque somme recue, a sa date, avec
  /// son echeance (export Excel).
  Future<List<({int versementId, double montant, DateTime date})>> journalPaiements(int motoId) async {
    final db = await database;
    final lignes = await db.query('paiements', where: 'moto_id = ?', whereArgs: [motoId], orderBy: 'date ASC, id ASC');
    return [
      for (final l in lignes)
        (
          versementId: l['versement_id'] as int,
          montant: (l['montant'] as num).toDouble(),
          date: DateTime.parse(l['date'] as String),
        ),
    ];
  }

  /// Remet le journal d'une echeance tel qu'il etait (import Excel) : chaque
  /// somme a sa vraie date. Refuse si le total ne fait pas le montant paye de
  /// l'echeance (le fichier se contredirait). Retourne true si remplace.
  Future<bool> remplacerJournal(int versementId, List<({double montant, DateTime date})> sommes) async {
    final db = await database;
    return db.transaction((txn) async {
      final maps = await txn.query('versements', where: 'id = ?', whereArgs: [versementId]);
      if (maps.isEmpty) return false;
      final v = Versement.fromMap(maps.first);
      final total = sommes.fold<double>(0, (t, s) => t + s.montant);
      if (total != ScheduleService.montantPaye(v)) return false;
      await txn.delete('paiements', where: 'versement_id = ?', whereArgs: [versementId]);
      for (final s in sommes) {
        await txn.insert('paiements',
            {'versement_id': versementId, 'moto_id': v.motoId, 'montant': s.montant, 'date': s.date.toIso8601String()});
      }
      return true;
    });
  }

  /// Echeances passees en dette : id de l'echeance -> id de sa dette.
  Future<Map<int, int>> liensEcheancesDettes() async {
    final db = await database;
    final lignes = await db.query('versements', columns: ['id', 'dette_id'], where: 'dette_id IS NOT NULL');
    return {for (final l in lignes) l['id'] as int: l['dette_id'] as int};
  }

  /// Remplace une echeance (import Excel) ; son paiement est reecrit dans
  /// le journal a partir du total et de la date de validation.
  Future<int> modifierVersement(Versement v) async {
    final db = await database;
    return db.transaction((txn) async {
      final lignes = await txn.update('versements', v.toMap(), where: 'id = ?', whereArgs: [v.id]);
      if (lignes > 0) await _reecrirePaiements(txn, v.id!, v);
      return lignes;
    });
  }

  /// Le journal de cette echeance = un seul paiement de son total, a sa date
  /// de validation (ou d'echeance), si elle est payee ; aucun sinon.
  Future<void> _reecrirePaiements(DatabaseExecutor ex, int versementId, Versement v) async {
    await ex.delete('paiements', where: 'versement_id = ?', whereArgs: [versementId]);
    final montant = v.montantPaye ?? 0;
    if (v.statut != AppConstants.versementPaye || montant == 0) return;
    await ex.insert('paiements', {
      'versement_id': versementId,
      'moto_id': v.motoId,
      'montant': montant,
      'date': (v.dateValidation ?? v.dateEcheance).toIso8601String(),
    });
  }

  /// Valide un versement : marque payé, fixe la date de validation
  /// et permet d'ajuster le montant réellement versé si besoin.
  /// [montantPaye] (par defaut : ce qui reste du) s'AJOUTE a ce qui a deja
  /// ete recu sur l'echeance — jamais d'argent efface. Plus que le reste :
  /// le surplus est une avance, deduite des echeances suivantes (voir
  /// [normaliser]).
  Future<void> validerVersement(int versementId, {double? montantPaye}) => _enFile(() async {
        final db = await database;
        final maps = await db.query('versements', where: 'id = ?', whereArgs: [versementId]);
        if (maps.isEmpty) return;
        final v = Versement.fromMap(maps.first);
        await _ajouterPaiement(versementId, montantPaye ?? ScheduleService.resteDu(v));
        await _normaliser(v.motoId);
      });

  /// Ajoute une somme recue sur une echeance (paiement partiel ou
  /// complement) : une ligne datee dans le journal, et le total de
  /// l'echeance augmente. L'echeance passe en "payee" (partiellement si le
  /// total reste sous le montant prevu).
  Future<void> ajouterPaiement(int versementId, double montant, {DateTime? date}) => _enFile(() async {
        await _ajouterPaiement(versementId, montant, date: date);
        final v = await obtenirVersement(versementId);
        if (v != null) await _normaliser(v.motoId);
      });

  Future<void> _ajouterPaiement(int versementId, double montant, {DateTime? date}) async {
    final db = await database;
    final quand = date ?? DateTime.now();
    await db.transaction((txn) async {
      final maps = await txn.query('versements', where: 'id = ?', whereArgs: [versementId]);
      if (maps.isEmpty) return;
      final v = Versement.fromMap(maps.first);
      await txn.insert('paiements', {
        'versement_id': versementId,
        'moto_id': v.motoId,
        'montant': montant,
        'date': quand.toIso8601String(),
      });
      await txn.update(
        'versements',
        {
          'statut': AppConstants.versementPaye,
          'montant_paye': (v.montantPaye ?? 0) + montant,
          'date_validation': quand.toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [versementId],
      );
    });
  }

  /// Corrige le montant reellement recu pour un versement deja valide
  /// (erreur de saisie du gerant), sans toucher a son statut ni sa date
  /// de validation. Seule la difference est ecrite au journal : ajoutee a la
  /// date du dernier paiement, ou retiree des paiements les plus recents —
  /// les autres sommes gardent leur date (statistiques par mois justes).
  /// A la hausse au-dela du montant prevu : le surplus va aux echeances
  /// suivantes (voir [normaliser]).
  Future<void> modifierMontantPaye(int versementId, double nouveauMontant) => _enFile(() async {
        final motoId = await _modifierMontantPaye(versementId, nouveauMontant);
        if (motoId != null) await _normaliser(motoId);
      });

  Future<int?> _modifierMontantPaye(int versementId, double nouveauMontant) async {
    final db = await database;
    return db.transaction((txn) async {
      final maps = await txn.query('versements', where: 'id = ?', whereArgs: [versementId]);
      if (maps.isEmpty) return null;
      final v = Versement.fromMap(maps.first);
      final dernier = (await txn.rawQuery('SELECT MAX(date) AS d FROM paiements WHERE versement_id = ?', [versementId]))
          .first['d'] as String?;
      final ecart = nouveauMontant - ScheduleService.montantPaye(v);
      if (ecart > 0) {
        await txn.insert('paiements', {
          'versement_id': versementId,
          'moto_id': v.motoId,
          'montant': ecart,
          'date': dernier ?? (v.dateValidation ?? v.dateEcheance).toIso8601String(),
        });
      } else if (ecart < 0) {
        await _retirerArgent(txn, v, -ecart);
      }
      await txn.update('versements', {'montant_paye': nouveauMontant}, where: 'id = ?', whereArgs: [versementId]);
      return v.motoId;
    });
  }

  /// Annule la validation d'un versement marque paye par erreur : il
  /// redevient "en_attente", ou "en_retard" si son echeance est deja
  /// passee.
  Future<void> annulerValidationVersement(int versementId) => _enFile(() async {
        final motoId = await _annulerValidation(versementId);
        if (motoId != null) await _normaliser(motoId);
      });

  Future<int?> _annulerValidation(int versementId) async {
    final db = await database;
    final maps = await db.query('versements', where: 'id = ?', whereArgs: [versementId]);
    if (maps.isEmpty) return null;
    final v = Versement.fromMap(maps.first);
    final nouveauStatut = v.dateEcheance.isBefore(ScheduleService.aujourdHui())
        ? AppConstants.versementEnRetard
        : AppConstants.versementEnAttente;
    await db.transaction((txn) async {
      // Erreur de saisie : l'argent n'a jamais ete recu, il sort du journal.
      await txn.delete('paiements', where: 'versement_id = ?', whereArgs: [versementId]);
      await txn.update(
        'versements',
        {
          'statut': nouveauStatut,
          'date_validation': null,
          'montant_paye': null,
        },
        where: 'id = ?',
        whereArgs: [versementId],
      );
    });
    return v.motoId;
  }

  /// Recalcule les statuts "en_attente" -> "en_retard" pour les échéances
  /// dépassées. À appeler au démarrage de l'app et sur pull-to-refresh.
  /// Ne fait basculer en "en_retard" que les echeances des motos encore
  /// actives : une moto suspendue/archivee (hors service) ne doit plus
  /// accumuler de retard au fil du temps qui passe.
  /// Une échéance n'est en retard qu'à partir du lendemain : le chauffeur a
  /// toute la journée de l'échéance pour payer.
  Future<void> actualiserRetards() async {
    final db = await database;
    final aujourdHui = ScheduleService.aujourdHui().toIso8601String();
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

  /// Prochaine periode a payer et ce qu'il en reste : la plus ancienne non
  /// soldee (meme regle que l'encaissement), partielle comprise.
  Future<({DateTime date, String etat, double reste})?> prochainVersement(int motoId) async {
    final moto = await obtenirMoto(motoId);
    if (moto == null) return null;
    final periodes = ScheduleService.periodesAPayer(
        existants: await listerVersementsParMoto(motoId), moto: moto, aujourdHui: ScheduleService.aujourdHui());
    return periodes.firstOrNull;
  }

  /// Filtre commun du journal des paiements (moto, periode sur la date de
  /// chaque somme recue).
  ({String where, List<Object?> args}) _filtrePaiements(int? motoId, DateTime? debut, DateTime? fin) {
    final conditions = <String>[
      if (motoId != null) 'moto_id = ?',
      if (debut != null) 'date >= ?',
      if (fin != null) 'date <= ?',
    ];
    return (
      where: conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}',
      args: [
        if (motoId != null) motoId,
        if (debut != null) debut.toIso8601String(),
        if (fin != null) fin.toIso8601String(),
      ],
    );
  }

  /// Paiements recus, du plus recent au plus ancien — l'activite recente de
  /// l'accueil (une echeance payee en deux fois apparait deux fois, a la
  /// date de chaque somme).
  Future<List<({DateTime date, double montant, int motoId})>> listerPaiementsRecents({
    int? motoId,
    DateTime? debut,
    DateTime? fin,
    int limite = 20,
  }) async {
    final db = await database;
    final filtre = _filtrePaiements(motoId, debut, fin);
    final lignes = await db.rawQuery(
      'SELECT date, montant, moto_id FROM paiements ${filtre.where} ORDER BY date DESC LIMIT $limite',
      filtre.args,
    );
    return [
      for (final l in lignes)
        (
          date: DateTime.parse(l['date'] as String),
          montant: (l['montant'] as num).toDouble(),
          motoId: l['moto_id'] as int,
        ),
    ];
  }

  /// Caisse : versements payés + remboursements des dettes liées aux motos
  /// (voir [listerRemboursementsMotos]), avec filtres optionnels. Le retard
  /// du chauffeur ([compteMoto]) ne compte, lui, que les versements.
  Future<double> totalEncaisse({int? motoId, DateTime? debut, DateTime? fin}) async =>
      await _totalVersementsPayes(motoId: motoId, debut: debut, fin: fin) +
      await totalRemboursementsMotos(motoId: motoId, debut: debut, fin: fin);

  Future<double> _totalVersementsPayes({int? motoId, DateTime? debut, DateTime? fin}) async {
    final db = await database;
    final filtre = _filtrePaiements(motoId, debut, fin);
    final result = await db.rawQuery(
      'SELECT COALESCE(SUM(montant), 0) as total FROM paiements ${filtre.where}',
      filtre.args,
    );
    return (result.first['total'] as num).toDouble();
  }

  /// Retard et avance d'une moto (voir [ScheduleService.compte], seule
  /// definition).
  Future<CompteMoto> compteMoto({required int motoId}) async {
    final moto = await obtenirMoto(motoId);
    if (moto == null) return (retard: 0.0, avance: 0.0);
    return ScheduleService.compte(moto, await listerVersementsParMoto(motoId), ScheduleService.aujourdHui());
  }

  /// Compte de chaque moto : le retard global de l'accueil additionne les
  /// retards moto par moto — l'avance d'une moto ne compense pas le retard
  /// d'une autre. Une moto suspendue garde ses retards d'avant la pause (sa
  /// pause, elle, n'est jamais due : voir [ScheduleService.estDue]).
  Future<Map<int, CompteMoto>> comptesMotos({int? motoId}) async {
    final motos = await listerMotos();
    return {
      for (final m in motos)
        if (motoId == null || m.id == motoId) m.id!: await compteMoto(motoId: m.id!),
    };
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
          // Jours calendaires : pas de decalage au changement d'heure.
          final lundi = DateTime(d.year, d.month, d.day - (d.weekday - 1));
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
          return DateTime(cle.year, cle.month, cle.day - 7);
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

    final totauxParCle = {for (final c in cles) c: 0.0};
    void ajouter(DateTime date, double montant) {
      final cle = cleDe(date);
      if (totauxParCle.containsKey(cle)) totauxParCle[cle] = totauxParCle[cle]! + montant;
    }

    // Chaque somme recue compte dans sa propre periode (journal des paiements).
    for (final p in await listerPaiementsRecents(motoId: motoId, debut: debut, limite: 1000000)) {
      ajouter(p.date, p.montant);
    }
    // Meme caisse que [totalEncaisse] : les remboursements de dettes liees.
    for (final e in await listerRemboursementsMotos(motoId: motoId, debut: debut)) {
      ajouter(e.remboursement.date, e.remboursement.montant);
    }

    return cles.map((c) => MapEntry(c, totauxParCle[c] ?? 0.0)).toList();
  }

  /// Garantit qu'il existe toujours [ScheduleService.fenetreEcheances]
  /// échéances non payées à venir pour cette moto : génère les suivantes
  /// si besoin, en repartant de la dernière échéance connue (ou de la date
  /// de début, qui est la date du 1er versement, si c'est la toute
  /// première), y compris celles déjà passées qui deviennent des retards.
  /// Retourne le nombre d'échéances créées (pour programmer leurs rappels).
  Future<int> assurerEcheances(Moto moto) => _enFile(() => _assurerEcheances(moto));

  /// File d'attente des opérations sur les échéances (génération,
  /// replanification, réactivation) : deux chargements d'écran simultanés
  /// lisaient les mêmes échéances et créaient chacun les manquantes, en double.
  Future<void> _fileEcheances = Future.value();

  Future<T> _enFile<T>(Future<T> Function() operation) {
    final resultat = _fileEcheances.then((_) => operation());
    _fileEcheances = resultat.then<void>((_) {}, onError: (Object _) {});
    return resultat;
  }

  Future<int> _assurerEcheances(Moto moto) async {
    if (moto.id == null) return 0;
    await _normaliser(moto.id!);
    final existants = await listerVersementsParMoto(moto.id!); // tri date DESC
    final dates = ScheduleService.datesAGenerer(
      existants: existants,
      premiere: existants.isEmpty
          ? moto.dateDebut
          : ScheduleService.echeanceSuivante(
              dateActuelle: existants.first.dateEcheance,
              type: moto.frequenceType,
              valeur: moto.frequenceValeur,
            ),
      type: moto.frequenceType,
      valeur: moto.frequenceValeur,
      aujourdHui: ScheduleService.aujourdHui(),
    );
    if (dates.isNotEmpty) await _insererVersements(await _nouvellesEcheances(moto, dates));
    return dates.length;
  }

  /// Applique une modification du plan d'une moto (date de début,
  /// fréquence ou jour) à ses échéances non payées — voir
  /// [ScheduleService.replanifier] pour les règles. Les versements déjà
  /// payés ne sont jamais touchés.
  Future<void> replanifierEcheances(Moto moto, {required bool depuisDateDebut}) =>
      _enFile(() => _replanifierEcheances(moto, depuisDateDebut));

  Future<void> _replanifierEcheances(Moto moto, bool depuisDateDebut) async {
    if (moto.id == null) return;
    final plan = ScheduleService.replanifier(
      existants: await listerVersementsParMoto(moto.id!),
      moto: moto,
      depuisDateDebut: depuisDateDebut,
      aujourdHui: ScheduleService.aujourdHui(),
    );
    await _remplacerEcheances(plan.aSupprimer, await _nouvellesEcheances(moto, plan.aCreer));
    await _normaliser(moto.id!);
  }

  /// Changements de montant d'une moto, du plus ancien au plus recent (voir
  /// [ScheduleService.montantAu]).
  Future<List<ChangementMontant>> listerChangementsMontant(int motoId) async =>
      _changementsMontant(await database, motoId);

  Future<List<ChangementMontant>> _changementsMontant(DatabaseExecutor db, int motoId) async {
    final lignes = await db.query('montants_moto', where: 'moto_id = ?', whereArgs: [motoId], orderBy: 'depuis ASC');
    return [
      for (final l in lignes)
        (depuis: DateTime.parse(l['depuis'] as String), montant: (l['montant'] as num).toDouble()),
    ];
  }

  /// Nouveau montant de versement en vigueur a partir du jour [depuis]
  /// (passe ou futur), jusqu'au changement suivant s'il y en a un. Les
  /// echeances deja creees sur cette periode passent a ce montant, meme
  /// passees ou payees (payee a l'ancien montant, elle devient partielle ou
  /// en avance, et le solde se recalcule) ; celles creees plus tard, et les
  /// periodes oubliees encaissees apres coup, prennent le montant en vigueur
  /// a leur date. Un changement au meme jour qu'un autre le remplace.
  /// Retourne le nombre d'echeances modifiees.
  Future<int> changerMontant(int motoId, double montant, DateTime depuis) => _enFile(() async {
        final db = await database;
        final modifiees = await db.transaction((txn) async {
          await txn.insert(
            'montants_moto',
            {'moto_id': motoId, 'depuis': ScheduleService.dateSeule(depuis).toIso8601String(), 'montant': montant},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          return _reappliquerMontant(txn, motoId, depuis);
        });
        await _normaliser(motoId);
        return modifiees;
      });

  /// Annule le changement de montant du jour [depuis] : sa periode reprend
  /// le montant d'avant (changement precedent, ou montant de depart).
  Future<int> supprimerChangementMontant(int motoId, DateTime depuis) => _enFile(() async {
        final db = await database;
        final modifiees = await db.transaction((txn) async {
          await txn.delete('montants_moto',
              where: 'moto_id = ? AND depuis = ?',
              whereArgs: [motoId, ScheduleService.dateSeule(depuis).toIso8601String()]);
          return _reappliquerMontant(txn, motoId, depuis);
        });
        await _normaliser(motoId);
        return modifiees;
      });

  /// Remplace tout l'historique des montants d'une moto (import Excel), sans
  /// toucher aux echeances : elles arrivent avec leur propre montant.
  Future<void> remplacerChangementsMontant(int motoId, List<ChangementMontant> changements) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('montants_moto', where: 'moto_id = ?', whereArgs: [motoId]);
      for (final c in changements) {
        await txn.insert(
          'montants_moto',
          {'moto_id': motoId, 'depuis': ScheduleService.dateSeule(c.depuis).toIso8601String(), 'montant': c.montant},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  /// Remet au montant en vigueur le jour [depuis] les echeances de la periode
  /// qui commence ce jour-la et s'arrete au changement suivant. Les
  /// echeances passees en dette ne bougent pas (la dette a son montant).
  Future<int> _reappliquerMontant(Transaction txn, int motoId, DateTime depuis) async {
    final jour = ScheduleService.dateSeule(depuis).toIso8601String();
    final montant = (await txn.rawQuery(
      'SELECT COALESCE('
      '(SELECT montant FROM montants_moto WHERE moto_id = ? AND depuis <= ? ORDER BY depuis DESC LIMIT 1), '
      '(SELECT montant_versement FROM motos WHERE id = ?)) AS montant',
      [motoId, jour, motoId],
    ))
        .first['montant'] as num?;
    if (montant == null) return 0; // moto inconnue
    final suivant = (await txn.rawQuery(
      'SELECT MIN(depuis) AS depuis FROM montants_moto WHERE moto_id = ? AND depuis > ?',
      [motoId, jour],
    ))
        .first['depuis'] as String?;
    // Payee sans montant enregistre (ancien import) = payee a l'ancien
    // montant : on le fige avant de changer montant_prevu.
    return txn.rawUpdate(
      'UPDATE versements SET '
      'montant_paye = COALESCE(montant_paye, CASE WHEN statut = ? THEN montant_prevu END), '
      'montant_prevu = ? '
      'WHERE moto_id = ? AND statut != ? AND date_echeance >= ?${suivant != null ? ' AND date_echeance < ?' : ''}',
      [
        AppConstants.versementPaye,
        montant,
        motoId,
        AppConstants.versementEnDette,
        jour,
        if (suivant != null) suivant,
      ],
    );
  }

  /// A appeler quand une moto est reactivee apres une pause (suspension).
  /// Les echeances tombees pendant la pause ne doivent pas compter : la moto
  /// n'a pas travaille. Elles sont restees "en attente" (une moto suspendue
  /// ne passe plus rien en retard) : ce sont elles qu'on retire, avec les
  /// echeances a venir, avant de repartir d'aujourd'hui. Les versements
  /// payes, les retards d'avant la pause et les dettes restent dus.
  Future<void> redemarrerEcheancesApresReactivation(Moto moto) => _enFile(() => _redemarrerEcheances(moto));

  Future<void> _redemarrerEcheances(Moto moto) async {
    if (moto.id == null) return;
    final existants = await listerVersementsParMoto(moto.id!);
    final aujourdHui = ScheduleService.aujourdHui();
    bool deLaPause(Versement v) => v.statut == AppConstants.versementEnAttente;
    final dates = ScheduleService.datesAGenerer(
      existants: existants.where((v) => !deLaPause(v)).toList(),
      premiere: ScheduleService.premiereEcheance(
        dateDebut: aujourdHui,
        type: moto.frequenceType,
        valeur: moto.frequenceValeur,
      ),
      type: moto.frequenceType,
      valeur: moto.frequenceValeur,
      aujourdHui: aujourdHui,
    );
    await _remplacerEcheances(existants.where(deLaPause).toList(), await _nouvellesEcheances(moto, dates));
    await _normaliser(moto.id!);
  }

  /// "Encaisser un versement" (bouton "Ajouter versement") : le montant
  /// recu paie les periodes [choisies] (null : les plus anciennes d'abord),
  /// le surplus les periodes suivantes du rythme — voir
  /// [ScheduleService.affecterVersement], seul calcul. Une echeance existante
  /// est completee ; une periode future pas encore creee l'est, a sa date et
  /// au montant en vigueur. Chaque part est ecrite dans le journal des
  /// paiements, datee d'aujourd'hui, comme tout versement. Retourne la
  /// repartition (pour le recu).
  Future<List<({DateTime date, double montant})>> encaisser(Moto moto, double montant, {Set<DateTime>? choisies}) =>
      _enFile(() async {
        final existants = await listerVersementsParMoto(moto.id!);
        final changements = await listerChangementsMontant(moto.id!);
        final aujourdHui = ScheduleService.aujourdHui();
        // La plus ancienne d'abord : une semaine impayee ne se saute pas, on
        // la paie ou on la passe en dette avant (l'ecran le demande).
        if (choisies != null && choisies.isNotEmpty) {
          final derniere = choisies.reduce((a, b) => a.isAfter(b) ? a : b);
          final sautees = ScheduleService.impayeesAvant(
                  existants: existants, moto: moto, aujourdHui: aujourdHui, date: derniere)
              .where((p) => !choisies.map(ScheduleService.dateSeule).contains(p.date));
          if (sautees.isNotEmpty) {
            throw ArgumentError('Payer d\'abord la periode du ${sautees.first.date} ou la passer en dette.');
          }
        }
        final affectations = ScheduleService.affecterVersement(
          moto: moto,
          existants: existants,
          changements: changements,
          aujourdHui: aujourdHui,
          montant: montant,
          choisies: choisies,
        );
        final maintenant = DateTime.now();
        for (final a in affectations) {
          final existante = existants
              .where((v) =>
                  ScheduleService.dateSeule(v.dateEcheance) == a.date && v.statut != AppConstants.versementEnDette)
              .firstOrNull;
          final id = existante?.id ??
              await insererVersement(ScheduleService.nouvelleEcheance(moto, changements, a.date, aujourdHui));
          await _ajouterPaiement(id, a.montant, date: maintenant);
        }
        await _normaliser(moto.id!);
        return affectations;
      });

  /// Marque une echeance non payee "en dette" : une dette liee a la moto est
  /// creee dans Dettes (ses remboursements iront dans la caisse de la moto)
  /// et l'echeance ne compte plus dans le retard. Retourne l'id de la dette.
  /// Deja en dette (ex : double appui) : retourne la dette existante.
  Future<int> marquerEnDette(Versement echeance, Moto moto) => _enFile(() async {
        final detteId = await _marquerEnDette(echeance, moto);
        await _normaliser(moto.id!);
        return detteId;
      });

  Future<int> _marquerEnDette(Versement echeance, Moto moto) async {
    final db = await database;
    final deviseGlobale = (await obtenirParametres()).deviseSymbole;
    final d = echeance.dateEcheance;
    final jour = formaterDate(d);
    return db.transaction((txn) async {
      final v = Versement.fromMap((await txn.query('versements', where: 'id = ?', whereArgs: [echeance.id])).first);
      if (v.statut == AppConstants.versementEnDette && v.detteId != null) return v.detteId!;
      if (ScheduleService.resteDu(v) <= 0) {
        throw ArgumentError('Cette echeance est deja soldee : rien a mettre en dette.');
      }
      final detteId = await txn.insert(
        'dettes',
        Dette(
          nomPersonne: moto.chauffeur,
          montantInitial: ScheduleService.resteDu(v),
          date: d,
          notes: 'Versement du $jour non paye (${moto.nom})',
          lienType: AppConstants.detteLienMoto,
          lienId: moto.id,
          deviseSymbole: deviseGlobale,
        ).toMap()
          ..remove('id'),
      );
      await txn.update(
        'versements',
        {'statut': AppConstants.versementEnDette, 'dette_id': detteId},
        where: 'id = ?',
        whereArgs: [v.id],
      );
      return detteId;
    });
  }

  /// Remet le compte d'une moto en regle, apres chaque operation qui touche
  /// l'argent (sans effet si tout est deja en regle) — regles du client :
  /// 1. jamais deux echeances dans la meme semaine du calendrier (aucun
  ///    rythme hebdomadaire ou mensuel n'en cree) : celle en trop est
  ///    supprimee ; l'argent qu'elle avait recu passe a l'echeance gardee,
  ///    puis aux suivantes. Une dette n'est jamais supprimee. Juge a la
  ///    semaine, pas au mois : passer d'hebdomadaire a mensuel garde chaque
  ///    semaine deja due (aucun retard efface).
  /// 2. jamais plus que son montant sur une echeance : le surplus est une
  ///    avance, deduite des echeances suivantes.
  /// 3. toujours la plus ancienne d'abord : jamais une echeance incomplete
  ///    suivie d'une echeance payee (sauf passee en dette). L'argent verse
  ///    sur une semaine plus recente paie d'abord les semaines anterieures
  ///    impayees ; apres un changement de montant, l'avance se redistribue
  ///    selon le nouveau montant. Pour payer une semaine en laissant une
  ///    plus ancienne de cote, il faut d'abord passer celle-ci en dette.
  /// L'argent deplace garde sa date de paiement : le total encaisse et les
  /// statistiques par date ne changent pas.
  Future<void> normaliser(int motoId) => _enFile(() => _normaliser(motoId));

  Future<void> _normaliser(int motoId) async {
    final moto = await obtenirMoto(motoId);
    if (moto == null) return;
    final db = await database;
    await db.transaction((txn) async {
      final lignes =
          (await txn.query('versements', where: 'moto_id = ?', whereArgs: [motoId], orderBy: 'date_echeance ASC'))
              .map(Versement.fromMap)
              .toList();
      final aReporter = <({DateTime depuis, List<({DateTime date, double montant})> argent})>[];

      // 1. Un seul versement par periode. "Tous les N jours" : l'historique
      // a pu suivre un autre rythme, on ne le juge pas.
      if (moto.frequenceType != AppConstants.freqPersonnalisee) {
        Versement? gardee;
        for (final v in [...lignes]) {
          // Semaine du calendrier pour tout l'historique ; en mensuel, une
          // echeance a venir encore vide dans un mois deja pris est aussi en trop
          // (le passe, lui, a pu suivre un rythme hebdomadaire : jamais fusionne au mois).
          final aVenirVide = !v.dateEcheance.isBefore(ScheduleService.aujourdHui()) &&
              v.statut == AppConstants.versementEnAttente &&
              ScheduleService.montantPaye(v) == 0;
          final doublon = gardee != null &&
              (ScheduleService.memePeriode(gardee.dateEcheance, v.dateEcheance,
                      type: AppConstants.freqHebdomadaire, valeur: DateTime.monday) ||
                  (aVenirVide &&
                      ScheduleService.memePeriode(gardee.dateEcheance, v.dateEcheance,
                          type: moto.frequenceType, valeur: moto.frequenceValeur)));
          if (!doublon) {
            gardee = v;
          } else if (v.statut == AppConstants.versementEnDette) {
            continue; // une dette ne disparait jamais
          } else {
            final argent = await _retirerArgent(txn, v, ScheduleService.montantPaye(v));
            await txn.delete('paiements', where: 'versement_id = ?', whereArgs: [v.id]);
            await txn.delete('versements', where: 'id = ?', whereArgs: [v.id]);
            lignes.remove(v);
            if (argent.isNotEmpty) aReporter.add((depuis: gardee.dateEcheance, argent: argent));
          }
        }
      }

      // 2. Jamais plus que son montant sur une echeance.
      for (final v in lignes) {
        if (v.statut != AppConstants.versementPaye) continue;
        final surplus = ScheduleService.montantPaye(v) - v.montantPrevu;
        if (surplus <= 0) continue;
        final argent = await _retirerArgent(txn, v, surplus);
        await txn.update('versements', {'montant_paye': v.montantPrevu}, where: 'id = ?', whereArgs: [v.id]);
        aReporter.add((depuis: v.dateEcheance, argent: argent));
      }

      for (final r in aReporter) {
        await _reporter(txn, moto, r.depuis, r.argent);
      }

      // 3. La plus ancienne d'abord : l'argent des echeances qui suivent la
      // premiere incomplete revient la remplir, puis les suivantes. Ni les
      // dettes ni la pause d'une moto suspendue n'entrent en jeu.
      final enPause = moto.statut != AppConstants.motoActive;
      final aVenir = (await txn.query(
        'versements',
        where: 'moto_id = ? AND statut != ?',
        whereArgs: [motoId, AppConstants.versementEnDette],
        orderBy: 'date_echeance ASC',
      ))
          .map(Versement.fromMap)
          .where((v) => !(enPause && v.statut == AppConstants.versementEnAttente))
          .toList();
      final premiereIncomplete = aVenir.indexWhere((v) => ScheduleService.resteDu(v) > 0);
      if (premiereIncomplete >= 0) {
        final argent = <({DateTime date, double montant})>[];
        for (final v in aVenir.skip(premiereIncomplete + 1)) {
          final paye = ScheduleService.montantPaye(v);
          if (paye <= 0) continue;
          argent.addAll(await _retirerArgent(txn, v, paye));
          await txn.update(
            'versements',
            {
              'statut': v.dateEcheance.isBefore(ScheduleService.aujourdHui())
                  ? AppConstants.versementEnRetard
                  : AppConstants.versementEnAttente,
              'montant_paye': null,
              'date_validation': null,
            },
            where: 'id = ?',
            whereArgs: [v.id],
          );
        }
        if (argent.isNotEmpty) await _reporter(txn, moto, aVenir[premiereIncomplete].dateEcheance, argent);
      }

      // Les echeances a venir creees pour une avance et redevenues vides
      // (avance regroupee) : on n'en garde que la fenetre habituelle, le
      // roulement recree les suivantes aux memes dates.
      final vides = (await txn.query(
        'versements',
        where: 'moto_id = ? AND statut = ? AND montant_paye IS NULL AND date_echeance >= ?',
        whereArgs: [motoId, AppConstants.versementEnAttente, ScheduleService.aujourdHui().toIso8601String()],
        orderBy: 'date_echeance ASC',
      ));
      for (final l in vides.skip(ScheduleService.fenetreEcheances)) {
        await txn.delete('versements', where: 'id = ?', whereArgs: [l['id']]);
      }
    });
  }

  /// Retire [montant] du journal d'une echeance, en commencant par les
  /// paiements les plus recents ; retourne cet argent avec ses dates.
  Future<List<({DateTime date, double montant})>> _retirerArgent(Transaction txn, Versement v, double montant) async {
    final retire = <({DateTime date, double montant})>[];
    var reste = montant;
    final paiements =
        await txn.query('paiements', where: 'versement_id = ?', whereArgs: [v.id], orderBy: 'date DESC, id DESC');
    for (final p in paiements) {
      if (reste <= 0) break;
      final m = (p['montant'] as num).toDouble();
      final part = m <= reste ? m : reste;
      if (part == m) {
        await txn.delete('paiements', where: 'id = ?', whereArgs: [p['id']]);
      } else {
        await txn.update('paiements', {'montant': m - part}, where: 'id = ?', whereArgs: [p['id']]);
      }
      retire.add((date: DateTime.parse(p['date'] as String), montant: part));
      reste -= part;
    }
    // Ancienne echeance sans journal : l'argent date de sa validation.
    if (reste > 0) retire.add((date: v.dateValidation ?? v.dateEcheance, montant: reste));
    return retire;
  }

  /// Paie avec [argent] les echeances a partir du jour [depuis] (voir
  /// [ScheduleService.affecterVersement]), en creant au rythme de la moto
  /// celles qui n'existent pas encore. Chaque part garde la date de son
  /// paiement d'origine.
  Future<void> _reporter(
      Transaction txn, Moto moto, DateTime depuis, List<({DateTime date, double montant})> argent) async {
    final total = argent.fold<double>(0, (t, a) => t + a.montant);
    if (total <= 0) return;
    final existants = (await txn.query('versements', where: 'moto_id = ?', whereArgs: [moto.id]))
        .map(Versement.fromMap)
        .toList();
    final changements = await _changementsMontant(txn, moto.id!);
    final aujourdHui = ScheduleService.aujourdHui();
    final affectations = ScheduleService.affecterVersement(
      moto: moto,
      existants: existants,
      changements: changements,
      aujourdHui: aujourdHui,
      montant: total,
      depuis: depuis,
    );
    final sources = [...argent];
    for (final a in affectations) {
      final existante = existants
          .where(
              (v) => ScheduleService.dateSeule(v.dateEcheance) == a.date && v.statut != AppConstants.versementEnDette)
          .firstOrNull;
      final id = existante?.id ??
          await txn.insert(
            'versements',
            ScheduleService.nouvelleEcheance(moto, changements, a.date, aujourdHui).toMap()..remove('id'),
          );
      var aPayer = a.montant;
      while (aPayer > 0 && sources.isNotEmpty) {
        final s = sources.first;
        final part = s.montant <= aPayer ? s.montant : aPayer;
        await txn.insert(
            'paiements', {'versement_id': id, 'moto_id': moto.id, 'montant': part, 'date': s.date.toIso8601String()});
        final ligne = Versement.fromMap((await txn.query('versements', where: 'id = ?', whereArgs: [id])).first);
        await txn.update(
          'versements',
          {
            'statut': AppConstants.versementPaye,
            'montant_paye': (ligne.montantPaye ?? 0) + part,
            'date_validation': s.date.toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        aPayer -= part;
        if (part == s.montant) {
          sources.removeAt(0);
        } else {
          sources[0] = (date: s.date, montant: s.montant - part);
        }
      }
    }
  }

  /// Echeances a inserer pour ces dates (voir [ScheduleService.nouvelleEcheance]).
  Future<List<Versement>> _nouvellesEcheances(Moto moto, List<DateTime> dates) async {
    if (dates.isEmpty) return [];
    final changements = await listerChangementsMontant(moto.id!);
    final aujourdHui = ScheduleService.aujourdHui();
    return [for (final d in dates) ScheduleService.nouvelleEcheance(moto, changements, d, aujourdHui)];
  }

  /// Supprime puis insere des echeances dans un seul batch (une seule
  /// transaction) : jamais de moto laissee sans ses echeances a mi-chemin.
  Future<void> _remplacerEcheances(List<Versement> aSupprimer, List<Versement> aInserer) async {
    final db = await database;
    final batch = db.batch();
    for (final v in aSupprimer) {
      batch.delete('versements', where: 'id = ?', whereArgs: [v.id]);
    }
    for (final v in aInserer) {
      batch.insert('versements', v.toMap()..remove('id'));
    }
    await batch.commit(noResult: true);
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

  /// Dépenses récentes, avec filtres optionnels par moto et par période
  /// (sur la date de la dépense, comme le filtre de l'accueil).
  Future<List<Depense>> listerDepensesRecentes({int? motoId, DateTime? debut, DateTime? fin, int limite = 20}) async {
    final db = await database;
    final conditions = <String>[
      if (motoId != null) 'moto_id = ?',
      if (debut != null) 'date >= ?',
      if (fin != null) 'date <= ?',
    ];
    final maps = await db.query(
      'depenses',
      where: conditions.isEmpty ? null : conditions.join(' AND '),
      whereArgs: [
        if (motoId != null) motoId,
        if (debut != null) debut.toIso8601String(),
        if (fin != null) fin.toIso8601String(),
      ],
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

  // -- Devises (liste a choisir dans les menus) --

  Future<List<String>> listerDevises() async {
    final db = await database;
    final lignes = await db.query('devises', orderBy: 'code ASC');
    return lignes.map((l) => l['code'] as String).toList();
  }

  /// Ajoute une devise a la liste (normalisee, sans doublon). Retourne le
  /// code enregistre, ou null si la saisie est vide.
  Future<String?> ajouterDevise(String saisie) async {
    final code = normaliserDevise(saisie);
    if (code == null) return null;
    final db = await database;
    await db.insert('devises', {'code': code}, conflictAlgorithm: ConflictAlgorithm.ignore);
    return code;
  }

  /// Retire une devise de la liste. Les montants deja enregistres dans cette
  /// devise ne changent pas (elle reste affichee la ou elle est utilisee).
  Future<void> supprimerDevise(String code) async {
    final db = await database;
    await db.delete('devises', where: 'code = ?', whereArgs: [code]);
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
      await _detacherDettesEntites(txn,
          filtreLienId: 'AND lien_id IN (SELECT id FROM categorie_entites WHERE categorie_id = ?)', args: [id]);
      final entites = await txn.query('categorie_entites', columns: ['id'], where: 'categorie_id = ?', whereArgs: [id]);
      for (final e in entites) {
        await _supprimerContenuEntite(txn, e['id'] as int);
      }
      await txn.delete('categorie_entites', where: 'categorie_id = ?', whereArgs: [id]);
      await txn.delete('categorie_champs', where: 'categorie_id = ?', whereArgs: [id]);
      await txn.delete('categories_activite', where: 'id = ?', whereArgs: [id]);
      await txn.update('parametres', {'categorie_active_id': null},
          where: 'id = ? AND categorie_active_id = ?', whereArgs: [1, id]);
    });
  }

  /// Efface TOUTES les categories d'activite generiques et tout leur
  /// contenu (champs, entites, transactions, valeurs) — utilise pour un
  /// import Excel global en mode "tout remplacer" quand le fichier
  /// contient une feuille "Categories". Revient automatiquement sur Motos
  /// (categorie active remise a null). Irreversible.
  Future<void> viderToutesLesCategoriesActivite() async {
    final db = await database;
    await db.transaction((txn) async {
      await _detacherDettesEntites(txn);
      await txn.delete('categorie_transaction_valeurs');
      await txn.delete('categorie_transaction_audios');
      await txn.delete('categorie_transactions');
      await txn.delete('categorie_gerants');
      await txn.delete('categorie_entite_valeurs');
      await txn.delete('categorie_entites');
      await txn.delete('categorie_champs');
      await txn.delete('categories_activite');
      await txn.update('parametres', {'categorie_active_id': null}, where: 'id = ?', whereArgs: [1]);
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
      await _detacherDettesEntites(txn, filtreLienId: 'AND lien_id = ?', args: [id]);
      await _supprimerContenuEntite(txn, id);
      await txn.delete('categorie_entites', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// Tout ce qui appartient a une entite (operations et leurs valeurs et
  /// notes vocales, valeurs de champs, gerants), mais pas l'entite elle-meme.
  /// Seul endroit qui connait cette liste : une nouvelle table rattachee a
  /// une entite s'ajoute ici, pour toutes les suppressions a la fois.
  Future<void> _supprimerContenuEntite(DatabaseExecutor txn, int entiteId) async {
    const operationsDeLEntite = 'transaction_id IN (SELECT id FROM categorie_transactions WHERE entite_id = ?)';
    await txn.delete('categorie_transaction_valeurs', where: operationsDeLEntite, whereArgs: [entiteId]);
    await txn.delete('categorie_transaction_audios', where: operationsDeLEntite, whereArgs: [entiteId]);
    await txn.delete('categorie_transactions', where: 'entite_id = ?', whereArgs: [entiteId]);
    await txn.delete('categorie_entite_valeurs', where: 'entite_id = ?', whereArgs: [entiteId]);
    await txn.delete('categorie_gerants', where: 'entite_id = ?', whereArgs: [entiteId]);
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

  /// Ajoute une operation, avec sa note vocale eventuelle (les deux ou rien).
  Future<int> insererTransactionCategorie(CategorieTransaction t, {Uint8List? audio}) async {
    final db = await database;
    return db.transaction((txn) async {
      final id = await txn.insert('categorie_transactions', t.toMap()..remove('id'));
      if (audio != null) {
        await txn.insert('categorie_transaction_audios', {'transaction_id': id, 'audio': audio});
      }
      return id;
    });
  }

  Future<CategorieTransaction?> obtenirTransactionCategorie(int id) async {
    final db = await database;
    final maps = await db.query('categorie_transactions', where: 'id = ?', whereArgs: [id]);
    return maps.isEmpty ? null : CategorieTransaction.fromMap(maps.first);
  }

  Future<Uint8List?> obtenirAudioTransaction(int transactionId) async {
    final db = await database;
    final lignes = await db.query('categorie_transaction_audios',
        columns: ['audio'], where: 'transaction_id = ?', whereArgs: [transactionId]);
    return lignes.isEmpty ? null : lignes.first['audio'] as Uint8List;
  }

  /// Operations de l'entite qui ont une note vocale (sans charger l'audio).
  Future<Set<int>> transactionsAvecAudio(int entiteId) async {
    final db = await database;
    final lignes = await db.rawQuery(
      'SELECT a.transaction_id FROM categorie_transaction_audios a '
      'JOIN categorie_transactions t ON t.id = a.transaction_id WHERE t.entite_id = ?',
      [entiteId],
    );
    return {for (final l in lignes) l['transaction_id'] as int};
  }

  Future<int> modifierTransactionCategorie(CategorieTransaction t) async {
    final db = await database;
    return db.update('categorie_transactions', t.toMap(), where: 'id = ?', whereArgs: [t.id]);
  }

  Future<void> supprimerTransactionCategorie(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('categorie_transaction_valeurs', where: 'transaction_id = ?', whereArgs: [id]);
      await txn.delete('categorie_transaction_audios', where: 'transaction_id = ?', whereArgs: [id]);
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
      // Comme supprimerEntiteCategorie : les dettes liees restent, detachees.
      await _detacherDettesEntites(txn,
          filtreLienId: 'AND lien_id IN (SELECT id FROM categorie_entites WHERE categorie_id = ?)',
          args: [categorieId]);
      final entites =
          await txn.query('categorie_entites', columns: ['id'], where: 'categorie_id = ?', whereArgs: [categorieId]);
      for (final e in entites) {
        await _supprimerContenuEntite(txn, e['id'] as int);
      }
      await txn.delete('categorie_entites', where: 'categorie_id = ?', whereArgs: [categorieId]);
    });
  }

  /// Dettes liees aux entites (d'une categorie, ou de toutes) : id de la
  /// dette -> (categorie, entite) par leurs noms. A garder avant un import qui
  /// recree les entites (nouveaux numeros), pour les relier ensuite.
  Future<Map<int, ({String categorie, String entite, String? gerant})>> liensDettesEntites({int? categorieId}) async {
    final db = await database;
    final lignes = await db.rawQuery(
      'SELECT d.id, c.nom AS categorie, e.nom AS entite, g.nom AS gerant FROM dettes d '
      'JOIN categorie_entites e ON e.id = d.lien_id JOIN categories_activite c ON c.id = e.categorie_id '
      'LEFT JOIN categorie_gerants g ON g.id = d.gerant_id '
      'WHERE d.lien_type = ?${categorieId != null ? ' AND c.id = ?' : ''}',
      [AppConstants.detteLienCategorieEntite, if (categorieId != null) categorieId],
    );
    return {
      for (final l in lignes)
        l['id'] as int: (
          categorie: (l['categorie'] as String).toLowerCase(),
          entite: (l['entite'] as String).toLowerCase(),
          gerant: (l['gerant'] as String?)?.toLowerCase(),
        ),
    };
  }

  /// Relie chaque dette a l'entite du meme nom (dans la categorie du meme
  /// nom), et a la meme personne, apres un import : elle reste dans le solde
  /// de la boutique. Une dette dont l'entite n'existe plus reste detachee.
  Future<void> relierDettesAuxEntites(Map<int, ({String categorie, String entite, String? gerant})> liens) async {
    final db = await database;
    for (final lien in liens.entries) {
      final entite = await db.rawQuery(
        'SELECT e.id FROM categorie_entites e JOIN categories_activite c ON c.id = e.categorie_id '
        'WHERE LOWER(c.nom) = ? AND LOWER(e.nom) = ? LIMIT 1',
        [lien.value.categorie, lien.value.entite],
      );
      if (entite.isEmpty) continue;
      final entiteId = entite.first['id'] as int;
      // La personne concernee, retrouvee par son nom (sinon le proprietaire).
      final gerant = lien.value.gerant == null
          ? null
          : (await listerGerants(entiteId)).where((g) => g.nom.toLowerCase() == lien.value.gerant).firstOrNull?.id;
      await db.update(
        'dettes',
        {'lien_type': AppConstants.detteLienCategorieEntite, 'lien_id': entiteId, 'gerant_id': gerant},
        where: 'id = ? AND (lien_type IS NULL OR lien_type = ?)',
        whereArgs: [lien.key, AppConstants.detteLienCategorieEntite],
      );
    }
  }

  // -- Gerants (comptes par personne) --

  Future<int> insererGerant(CategorieGerant g) async {
    final db = await database;
    final nom = await _verifierNomGerant(db, g);
    return db.insert('categorie_gerants', (g.copyWith(nom: nom).toMap())..remove('id'));
  }

  /// Renommer ou archiver un gerant.
  Future<int> modifierGerant(CategorieGerant g) async {
    final db = await database;
    final nom = await _verifierNomGerant(db, g);
    return db.update('categorie_gerants', g.copyWith(nom: nom).toMap(), where: 'id = ?', whereArgs: [g.id]);
  }

  /// Nom nettoye, unique dans l'entite (l'import Excel retrouve un gerant
  /// par son nom : deux gerants homonymes y seraient fusionnes) et distinct
  /// du compte du proprietaire.
  Future<String> _verifierNomGerant(Database db, CategorieGerant g) async {
    final nom = g.nom.trim();
    if (nom.isEmpty) throw Exception('Le nom du gerant est obligatoire.');
    if (nom.toLowerCase() == AppConstants.libelleProprietaire.toLowerCase()) {
      throw Exception('"$nom" est reserve au compte du proprietaire.');
    }
    // Comparaison en Dart, comme l'import Excel (LOWER de SQLite ignore les accents).
    // Pas de null en argument (sqflite le refusera) : nouveau gerant = sans id.
    final autres = await db.query('categorie_gerants',
        columns: ['nom'],
        where: g.id == null ? 'entite_id = ?' : 'entite_id = ? AND id != ?',
        whereArgs: [g.entiteId, if (g.id != null) g.id]);
    if (autres.any((a) => (a['nom'] as String).trim().toLowerCase() == nom.toLowerCase())) {
      throw Exception('Un gerant nomme "$nom" existe deja.');
    }
    return nom;
  }

  Future<List<CategorieGerant>> listerGerants(int entiteId) async {
    final db = await database;
    final maps = await db.query('categorie_gerants',
        where: 'entite_id = ?', whereArgs: [entiteId], orderBy: 'date_creation, id');
    return maps.map(CategorieGerant.fromMap).toList();
  }

  /// Refuse de supprimer un gerant qui a des operations : elles sortiraient
  /// du total general. Il faut alors l'archiver.
  Future<void> supprimerGerant(int id) async {
    final db = await database;
    final operations = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT (SELECT COUNT(*) FROM categorie_transactions WHERE gerant_id = ?) + '
        '(SELECT COUNT(*) FROM dettes WHERE gerant_id = ? AND lien_type = ?)',
        [id, id, AppConstants.detteLienCategorieEntite]));
    if ((operations ?? 0) > 0) {
      throw Exception('Ce gerant a des operations ou des dettes : archivez-le au lieu de le supprimer.');
    }
    await db.delete('categorie_gerants', where: 'id = ?', whereArgs: [id]);
  }

  /// Solde de chaque personne de l'entite (ajouts moins sorties). Cle null =
  /// le proprietaire. Une dette accordee par une personne sort de son compte,
  /// ses remboursements y reviennent ([dettesEntites]). Seules les personnes
  /// ayant des mouvements y figurent ; la somme des valeurs est
  /// [soldeEntiteCategorie].
  Future<Map<int?, double>> soldesParPersonne(int entiteId) async {
    final db = await database;
    final lignes = await db.rawQuery(
      'SELECT gerant_id, COALESCE(SUM(CASE WHEN type = ? THEN montant ELSE -montant END), 0) as solde '
      'FROM categorie_transactions WHERE entite_id = ? GROUP BY gerant_id',
      [AppConstants.transactionRevenu, entiteId],
    );
    final soldes = {for (final l in lignes) l['gerant_id'] as int?: (l['solde'] as num).toDouble()};
    for (final d in await dettesEntites(entiteId: entiteId)) {
      soldes[d.gerant] = (soldes[d.gerant] ?? 0) - d.accorde + d.rembourse;
    }
    return soldes;
  }

  /// Dettes liees aux entites, par entite et par personne (null =
  /// proprietaire) : montant accorde (sorti de la boutique) et rembourse
  /// (revenu). Seule formule des dettes d'une boutique ; d'une entite ou de
  /// toute une categorie, dans la devise de sa categorie.
  Future<List<({int entite, int? gerant, double accorde, double rembourse})>> dettesEntites(
      {int? entiteId, int? categorieId}) async {
    final db = await database;
    final lignes = await db.rawQuery(
      'SELECT d.lien_id AS entite, d.gerant_id AS gerant, SUM(d.montant_initial) AS accorde, '
      'SUM(COALESCE((SELECT SUM(r.montant) FROM dette_remboursements r WHERE r.dette_id = d.id), 0)) AS rembourse '
      'FROM dettes d WHERE d.lien_type = ?${entiteId != null ? ' AND d.lien_id = ?' : ''}'
      '${categorieId != null ? ' AND d.lien_id IN (SELECT id FROM categorie_entites WHERE categorie_id = ?)' : ''} '
      'GROUP BY d.lien_id, d.gerant_id',
      [AppConstants.detteLienCategorieEntite, if (entiteId != null) entiteId, if (categorieId != null) categorieId],
    );
    return [
      for (final l in lignes)
        (
          entite: l['entite'] as int,
          gerant: l['gerant'] as int?,
          accorde: (l['accorde'] as num).toDouble(),
          rembourse: (l['rembourse'] as num).toDouble(),
        ),
    ];
  }

  // -- Agregats --

  /// Solde d'une entite : total des revenus moins total des depenses — la
  /// somme des comptes de chaque personne ([soldesParPersonne], seule formule).
  Future<double> soldeEntiteCategorie(int entiteId) async =>
      (await soldesParPersonne(entiteId)).values.fold<double>(0, (t, s) => t + s);

  /// Totaux (revenus, depenses) sur l'ensemble d'une categorie, toutes
  /// entites confondues — pour le tableau de bord de la categorie.
  /// [dettes] : accordees par ses entites (sorties) ; [remboursements] : ce
  /// qui en est revenu. Solde de la categorie = revenus - depenses - dettes
  /// + remboursements = somme de ses entites.
  Future<({double revenus, double depenses, double dettes, double remboursements})> totauxCategorie(
      int categorieId) async {
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
    final dettes = await dettesEntites(categorieId: categorieId);
    return (
      revenus: revenus,
      depenses: depenses,
      dettes: dettes.fold<double>(0, (t, d) => t + d.accorde),
      remboursements: dettes.fold<double>(0, (t, d) => t + d.rembourse),
    );
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

  /// Supprime une dette et ses remboursements. Si elle venait d'une echeance
  /// "marquee en dette", l'echeance redevient un retard : rien n'est perdu.
  /// Une dette venant d'une echeance : l'echeance redevient due, et les
  /// remboursements deja recus deviennent ses paiements, a leur date —
  /// jamais d'argent perdu.
  Future<void> supprimerDette(int id) => _enFile(() async {
        final db = await database;
        final motoIds = <int>{};
        await db.transaction((txn) async {
          final echeances =
              (await txn.query('versements', where: 'dette_id = ?', whereArgs: [id])).map(Versement.fromMap).toList();
          final argent = [
            for (final r in await txn.query('dette_remboursements', where: 'dette_id = ?', whereArgs: [id]))
              (montant: (r['montant'] as num).toDouble(), date: r['date'] as String),
          ];
          // Dette ajoutee a la main : l'argent recu ne disparait pas en silence.
          if (echeances.isEmpty && argent.isNotEmpty) {
            throw StateError('Cette dette a deja recu des remboursements : supprimez-les d\'abord.');
          }
          for (final v in echeances) {
            motoIds.add(v.motoId);
            await _rendreEcheanceDue(txn, v, argent: argent);
          }
          await txn.delete('dette_remboursements', where: 'dette_id = ?', whereArgs: [id]);
          await txn.delete('dettes', where: 'id = ?', whereArgs: [id]);
        });
        for (final m in motoIds) {
          await _normaliser(m);
        }
      });

  /// Echeance qui sort de sa dette : elle redevient due, et l'[argent] deja
  /// recu sur la dette devient ses paiements, a leur date.
  Future<void> _rendreEcheanceDue(Transaction txn, Versement v,
      {required List<({double montant, String date})> argent}) async {
    var paye = v.montantPaye ?? 0;
    String? derniereDate;
    for (final r in argent) {
      final montant = r.montant;
      final date = r.date;
      await txn.insert('paiements', {'versement_id': v.id, 'moto_id': v.motoId, 'montant': montant, 'date': date});
      paye += montant;
      if (derniereDate == null || date.compareTo(derniereDate) > 0) derniereDate = date;
    }
    final aujourdHui = ScheduleService.aujourdHui();
    await txn.update(
      'versements',
      {
        'statut': paye > 0
            ? AppConstants.versementPaye
            : v.dateEcheance.isBefore(aujourdHui)
                ? AppConstants.versementEnRetard
                : AppConstants.versementEnAttente,
        'montant_paye': paye > 0 ? paye : null,
        'date_validation': derniereDate ?? v.dateValidation?.toIso8601String(),
        'dette_id': null,
      },
      where: 'id = ?',
      whereArgs: [v.id],
    );
  }

  /// Detache les dettes liees aux motos qui vont etre supprimees ([motoId],
  /// ou toutes) : l'argent reste du, la dette devient independante et garde
  /// sa devise (la devise globale, celle des motos). Sans ca, elle pointait
  /// vers une moto disparue.
  Future<void> _detacherDettesMotos(DatabaseExecutor ex, String deviseGlobale, {int? motoId}) async {
    await ex.rawUpdate(
      'UPDATE dettes SET lien_type = NULL, lien_id = NULL, devise_symbole = ? '
      'WHERE lien_type = ?${motoId != null ? ' AND lien_id = ?' : ''}',
      [deviseGlobale, AppConstants.detteLienMoto, if (motoId != null) motoId],
    );
  }

  /// Meme chose pour les dettes liees aux entites de categorie qui vont etre
  /// supprimees ([filtreLienId] : condition SQL sur lien_id, sinon toutes) :
  /// elles gardent la devise de leur categorie. A appeler AVANT de supprimer
  /// les entites, pour que la devise de la categorie soit encore lisible.
  Future<void> _detacherDettesEntites(DatabaseExecutor ex,
      {String filtreLienId = '', List<Object?> args = const []}) async {
    await ex.rawUpdate(
      'UPDATE dettes SET devise_symbole = COALESCE((SELECT c.devise_symbole FROM categorie_entites e '
      'JOIN categories_activite c ON c.id = e.categorie_id WHERE e.id = dettes.lien_id), devise_symbole), '
      'lien_type = NULL, lien_id = NULL '
      'WHERE lien_type = ? $filtreLienId',
      [AppConstants.detteLienCategorieEntite, ...args],
    );
  }

  /// Efface toutes les dettes et remboursements — utilise pour un import
  /// Excel en mode "tout remplacer" scope aux dettes.
  Future<void> viderDettes() async {
    final db = await database;
    await db.transaction((txn) async {
      // Comme supprimerDette : une echeance marquee en dette redevient un retard.
      await txn.update(
        'versements',
        {'statut': AppConstants.versementEnRetard, 'dette_id': null},
        where: 'dette_id IS NOT NULL',
      );
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
    final maps =
        await db.query('dette_remboursements', where: 'dette_id = ?', whereArgs: [detteId], orderBy: 'date DESC');
    return maps.map((m) => DetteRemboursement.fromMap(m)).toList();
  }

  /// Remboursements des dettes liees a une moto (encore existante), du plus
  /// recent au plus ancien, avec leur dette : un chauffeur qui rembourse une
  /// dette liee a sa moto paie dans la caisse de cette moto (voir
  /// [totalEncaisse]). Filtres optionnels par moto et par date du remboursement.
  Future<List<({DetteRemboursement remboursement, Dette dette})>> listerRemboursementsMotos({
    int? motoId,
    DateTime? debut,
    DateTime? fin,
    int? limite,
  }) async {
    final db = await database;
    final conditions = <String>['d.lien_type = ?', 'd.lien_id IN (SELECT id FROM motos)'];
    final args = <Object?>[AppConstants.detteLienMoto];
    if (motoId != null) {
      conditions.add('d.lien_id = ?');
      args.add(motoId);
    }
    if (debut != null) {
      conditions.add('r.date >= ?');
      args.add(debut.toIso8601String());
    }
    if (fin != null) {
      conditions.add('r.date <= ?');
      args.add(fin.toIso8601String());
    }
    final lignes = await db.rawQuery(
      'SELECT d.*, r.id AS r_id, r.dette_id, r.montant, r.date AS r_date, r.notes AS r_notes '
      'FROM dette_remboursements r JOIN dettes d ON d.id = r.dette_id '
      'WHERE ${conditions.join(' AND ')} ORDER BY r.date DESC${limite != null ? ' LIMIT $limite' : ''}',
      args,
    );
    return [
      for (final l in lignes)
        (
          remboursement: DetteRemboursement(
            id: l['r_id'] as int,
            detteId: l['dette_id'] as int,
            montant: (l['montant'] as num).toDouble(),
            date: DateTime.parse(l['r_date'] as String),
            notes: l['r_notes'] as String?,
          ),
          dette: Dette.fromMap(l),
        ),
    ];
  }

  /// Total des remboursements de dettes encaisses par une moto (ou toutes).
  Future<double> totalRemboursementsMotos({int? motoId, DateTime? debut, DateTime? fin}) async {
    final remboursements = await listerRemboursementsMotos(motoId: motoId, debut: debut, fin: fin);
    return remboursements.fold<double>(0, (total, e) => total + e.remboursement.montant);
  }

  /// Montant restant du pour une dette : montant initial moins la somme
  /// des remboursements recus. 0 (ou moins, si trop rembourse) = soldee.
  Future<double> soldeDette(int detteId) async => (await soldesDettes(detteId: detteId))[detteId] ?? 0;

  /// Solde restant de chaque dette (montant initial moins ses
  /// remboursements), en une seule requete pour toutes les dettes.
  /// Seule formule du solde d'une dette ([detteId] : une seule).
  Future<Map<int, double>> soldesDettes({int? detteId}) async {
    final db = await database;
    final lignes = await db.rawQuery(
      'SELECT d.id, d.montant_initial - COALESCE(SUM(r.montant), 0) AS solde '
      'FROM dettes d LEFT JOIN dette_remboursements r ON r.dette_id = d.id'
      '${detteId != null ? ' WHERE d.id = ?' : ''} GROUP BY d.id',
      [if (detteId != null) detteId],
    );
    return {for (final l in lignes) l['id'] as int: (l['solde'] as num).toDouble()};
  }

  /// Devise effective d'une dette — voir [_resolveurDeviseDette].
  Future<String> deviseEffectiveDette(Dette dette) async => (await _resolveurDeviseDette())(dette);

  /// Devise effective de plusieurs dettes en 2 requetes au total.
  Future<Map<int, String>> devisesEffectivesDettes(List<Dette> dettes) async {
    final devise = await _resolveurDeviseDette();
    return {
      for (final d in dettes)
        if (d.id != null) d.id!: devise(d)
    };
  }

  /// Regle unique de la devise d'une dette : celle de la moto ou de l'entite
  /// liee si elle en a une (une moto utilise toujours la devise globale, une
  /// entite celle de sa categorie) — jamais celle stockee sur la dette
  /// elle-meme dans ce cas. Sans lien, c'est la devise propre choisie a la
  /// creation ([Dette.deviseSymbole]), ou la devise globale en repli (dette
  /// creee avant l'ajout de ce champ, ou jamais renseignee).
  Future<String Function(Dette)> _resolveurDeviseDette() async {
    final deviseGlobale = (await obtenirParametres()).deviseSymbole;
    final db = await database;
    final lignes = await db.rawQuery(
      'SELECT e.id, c.devise_symbole FROM categorie_entites e JOIN categories_activite c ON c.id = e.categorie_id',
    );
    final deviseParEntite = {for (final l in lignes) l['id'] as int: l['devise_symbole'] as String};
    return (Dette dette) {
      if (dette.lienType == AppConstants.detteLienMoto) return deviseGlobale;
      if (dette.lienType == AppConstants.detteLienCategorieEntite) {
        final devise = deviseParEntite[dette.lienId];
        if (devise != null) return devise;
      }
      final propre = dette.deviseSymbole;
      return propre != null && propre.isNotEmpty ? propre : deviseGlobale;
    };
  }

  /// Totaux des soldes encore dus, groupes par devise : une dette en FG et
  /// une en FCFA ne s'additionnent jamais. Partage avec l'ecran des dettes.
  static Map<String, double> totauxEnCoursParDevise(Map<int, double> soldes, Map<int, String> devises) {
    final totaux = <String, double>{};
    soldes.forEach((id, solde) {
      final devise = devises[id];
      if (solde <= 0 || devise == null) return;
      totaux[devise] = (totaux[devise] ?? 0) + solde;
    });
    return totaux;
  }

  /// Somme des montants encore dus, toutes dettes non soldees confondues,
  /// groupee par devise effective.
  Future<Map<String, double>> totauxDettesEnCoursParDevise() async =>
      totauxEnCoursParDevise(await soldesDettes(), await devisesEffectivesDettes(await listerDettes()));
}
