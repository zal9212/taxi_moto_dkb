class CategorieDepense {
  final int? id;
  final String nom;
  final String icone; // nom d'icône logique (droplet, tool, gas_station...)

  CategorieDepense({this.id, required this.nom, required this.icone});

  Map<String, dynamic> toMap() => {'id': id, 'nom': nom, 'icone': icone};

  factory CategorieDepense.fromMap(Map<String, dynamic> map) {
    return CategorieDepense(
      id: map['id'] as int?,
      nom: map['nom'] as String,
      icone: map['icone'] as String,
    );
  }
}

/// Une dépense liée à une moto (huile, réparation, ou toute catégorie
/// créée par l'utilisateur).
class Depense {
  final int? id;
  final int motoId;
  final int categorieId;
  final double montant;
  final DateTime date;
  final String? description;

  Depense({
    this.id,
    required this.motoId,
    required this.categorieId,
    required this.montant,
    required this.date,
    this.description,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'moto_id': motoId,
      'categorie_id': categorieId,
      'montant': montant,
      'date': date.toIso8601String(),
      'description': description,
    };
  }

  factory Depense.fromMap(Map<String, dynamic> map) {
    return Depense(
      id: map['id'] as int?,
      motoId: map['moto_id'] as int,
      categorieId: map['categorie_id'] as int,
      montant: (map['montant'] as num).toDouble(),
      date: DateTime.parse(map['date'] as String),
      description: map['description'] as String?,
    );
  }
}
