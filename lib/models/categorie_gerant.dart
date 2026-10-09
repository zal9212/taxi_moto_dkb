import '../core/constants.dart';

/// Un gerant d'une entite (ex: le gerant d'une boutique). Chaque operation
/// de l'entite est rattachee a une personne : un gerant, ou le proprietaire
/// (CategorieTransaction.gerantId null). Chaque personne a ainsi son propre
/// solde, et le total general de l'entite est la somme de ces soldes.
class CategorieGerant {
  final int? id;
  final int entiteId;
  final String nom;
  final String statut; // actif | archive (memes valeurs que Moto)
  final DateTime dateCreation;

  CategorieGerant({
    this.id,
    required this.entiteId,
    required this.nom,
    this.statut = AppConstants.motoActive,
    DateTime? dateCreation,
  }) : dateCreation = dateCreation ?? DateTime.now();

  CategorieGerant copyWith({String? nom, String? statut}) => CategorieGerant(
        id: id,
        entiteId: entiteId,
        nom: nom ?? this.nom,
        statut: statut ?? this.statut,
        dateCreation: dateCreation,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'entite_id': entiteId,
        'nom': nom,
        'statut': statut,
        'date_creation': dateCreation.toIso8601String(),
      };

  factory CategorieGerant.fromMap(Map<String, dynamic> map) => CategorieGerant(
        id: map['id'] as int?,
        entiteId: map['entite_id'] as int,
        nom: map['nom'] as String,
        statut: map['statut'] as String,
        dateCreation: DateTime.parse(map['date_creation'] as String),
      );
}
