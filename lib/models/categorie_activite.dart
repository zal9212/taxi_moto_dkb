/// Une categorie d'activite generique creee par l'utilisateur (ex:
/// "Boutiques"), a cote de Motos qui reste un systeme specialise separe.
/// Chaque categorie a sa propre devise (jamais melangee avec une autre) et
/// sa propre couleur d'accent, appliquee a tout l'app quand elle est active.
class CategorieActivite {
  final int? id;
  final String nom;
  final String couleur; // hex, ex '#2D6CDF'
  final String deviseSymbole;
  final DateTime dateCreation;

  CategorieActivite({
    this.id,
    required this.nom,
    required this.couleur,
    required this.deviseSymbole,
    DateTime? dateCreation,
  }) : dateCreation = dateCreation ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'nom': nom,
      'couleur': couleur,
      'devise_symbole': deviseSymbole,
      'date_creation': dateCreation.toIso8601String(),
    };
  }

  factory CategorieActivite.fromMap(Map<String, dynamic> map) {
    return CategorieActivite(
      id: map['id'] as int?,
      nom: map['nom'] as String,
      couleur: map['couleur'] as String,
      deviseSymbole: map['devise_symbole'] as String,
      dateCreation: DateTime.parse(map['date_creation'] as String),
    );
  }
}
