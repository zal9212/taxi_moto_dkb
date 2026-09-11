import 'dart:convert';

/// Definition d'un champ personnalise pour une categorie d'activite.
/// [niveau] = 'entite' (rempli une fois par entite, ex: "Responsable" pour
/// une boutique) ou 'transaction' (rempli a chaque revenu/depense, ex:
/// "Type de depense"). [type] = 'texte' | 'montant' | 'date' | 'liste'.
/// [options] n'est utilise que pour le type 'liste' (choix proposes).
class CategorieChamp {
  final int? id;
  final int categorieId;
  final String niveau;
  final String nom;
  final String type;
  final List<String>? options;
  final int ordre;

  CategorieChamp({
    this.id,
    required this.categorieId,
    required this.niveau,
    required this.nom,
    required this.type,
    this.options,
    this.ordre = 0,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'categorie_id': categorieId,
      'niveau': niveau,
      'nom': nom,
      'type': type,
      'options': options != null ? jsonEncode(options) : null,
      'ordre': ordre,
    };
  }

  factory CategorieChamp.fromMap(Map<String, dynamic> map) {
    final optionsBrutes = map['options'] as String?;
    return CategorieChamp(
      id: map['id'] as int?,
      categorieId: map['categorie_id'] as int,
      niveau: map['niveau'] as String,
      nom: map['nom'] as String,
      type: map['type'] as String,
      options: optionsBrutes != null ? List<String>.from(jsonDecode(optionsBrutes) as List) : null,
      ordre: map['ordre'] as int,
    );
  }
}
