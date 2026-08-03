import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../core/constants.dart';
import '../models/moto.dart';
import '../models/versement.dart';
import '../models/depense.dart';
import '../models/parametre.dart';

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
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, AppConstants.dbName);
    return openDatabase(
      path,
      version: AppConstants.dbVersion,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE motos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nom TEXT NOT NULL,
        chauffeur TEXT NOT NULL,
        montant_total REAL NOT NULL,
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

  Future<int> supprimerMoto(int id) async {
    final db = await database;
    return db.delete('motos', where: 'id = ?', whereArgs: [id]);
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

  Future<double> totalEnRetard({int? motoId}) async {
    final db = await database;
    final conditions = <String>["statut = ?"];
    final args = <dynamic>[AppConstants.versementEnRetard];
    if (motoId != null) {
      conditions.add('moto_id = ?');
      args.add(motoId);
    }
    final result = await db.rawQuery(
      'SELECT COALESCE(SUM(montant_prevu), 0) as total FROM versements WHERE ${conditions.join(' AND ')}',
      args,
    );
    return (result.first['total'] as num).toDouble();
  }

  /// Solde restant dû pour une moto = montant total - somme des payés.
  Future<double> soldeRestant(int motoId, double montantTotal) async {
    final paye = await totalEncaisse(motoId: motoId);
    final solde = montantTotal - paye;
    return solde < 0 ? 0 : solde;
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
