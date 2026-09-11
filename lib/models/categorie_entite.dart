import '../core/constants.dart';

/// Une entite au sein d'une categorie generique (ex: une boutique precise
/// dans la categorie "Boutiques") — l'equivalent generique d'une Moto.
/// Les champs personnalises de niveau "entite" definis par la categorie
/// sont stockes a part (table categorie_entite_valeurs), pas ici.
class CategorieEntite {
  final int? id;
  final int categorieId;
  final String nom;
  final String statut; // actif | suspendu | archive (mêmes valeurs que Moto)
  final DateTime dateCreation;
  final String? notes;

  CategorieEntite({
    this.id,
    required this.categorieId,
    required this.nom,
    this.statut = AppConstants.motoActive,
    DateTime? dateCreation,
    this.notes,
  }) : dateCreation = dateCreation ?? DateTime.now();

  CategorieEntite copyWith({
    String? nom,
    String? statut,
    String? notes,
  }) {
    return CategorieEntite(
      id: id,
      categorieId: categorieId,
      nom: nom ?? this.nom,
      statut: statut ?? this.statut,
      dateCreation: dateCreation,
      notes: notes ?? this.notes,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'categorie_id': categorieId,
      'nom': nom,
      'statut': statut,
      'date_creation': dateCreation.toIso8601String(),
      'notes': notes,
    };
  }

  factory CategorieEntite.fromMap(Map<String, dynamic> map) {
    return CategorieEntite(
      id: map['id'] as int?,
      categorieId: map['categorie_id'] as int,
      nom: map['nom'] as String,
      statut: map['statut'] as String,
      dateCreation: DateTime.parse(map['date_creation'] as String),
      notes: map['notes'] as String?,
    );
  }
}
