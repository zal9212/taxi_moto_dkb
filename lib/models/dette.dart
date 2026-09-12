/// Une dette : de l'argent qu'une personne doit a l'utilisateur, suivie
/// independamment du systeme de categories generique. Peut optionnellement
/// etre rattachee a une moto ou a une entite de categorie (via [lienType]
/// + [lienId]) quand la dette concerne cette activite precise (ex: le
/// chauffeur d'une moto qui doit de l'argent en plus de ses versements) ;
/// laissee sans lien pour un pret personnel sans rapport avec l'app.
///
/// La devise n'est jamais fixe : une dette liee a une moto ou a une entite
/// de categorie affiche toujours la devise de ce a quoi elle est liee (les
/// motos utilisent la devise globale, une entite celle de sa categorie) —
/// voir DatabaseService.deviseEffectiveDette(). [deviseSymbole] n'est utilise
/// que pour une dette SANS lien, ou elle est choisie librement a la creation.
class Dette {
  final int? id;
  final String nomPersonne;
  final double montantInitial;
  final DateTime date;
  final String? notes;
  final DateTime dateCreation;
  /// AppConstants.detteLienMoto | detteLienCategorieEntite | null
  final String? lienType;
  final int? lienId;
  /// Devise propre a une dette SANS lien ; ignoree (et sans effet) si
  /// [lienType] est renseigne, la devise venant alors du lien.
  final String? deviseSymbole;

  Dette({
    this.id,
    required this.nomPersonne,
    required this.montantInitial,
    required this.date,
    this.notes,
    DateTime? dateCreation,
    this.lienType,
    this.lienId,
    this.deviseSymbole,
  }) : dateCreation = dateCreation ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'nom_personne': nomPersonne,
      'montant_initial': montantInitial,
      'date': date.toIso8601String(),
      'notes': notes,
      'date_creation': dateCreation.toIso8601String(),
      'lien_type': lienType,
      'lien_id': lienId,
      'devise_symbole': deviseSymbole,
    };
  }

  factory Dette.fromMap(Map<String, dynamic> map) {
    return Dette(
      id: map['id'] as int?,
      nomPersonne: map['nom_personne'] as String,
      montantInitial: (map['montant_initial'] as num).toDouble(),
      date: DateTime.parse(map['date'] as String),
      notes: map['notes'] as String?,
      dateCreation: DateTime.parse(map['date_creation'] as String),
      lienType: map['lien_type'] as String?,
      lienId: map['lien_id'] as int?,
      deviseSymbole: map['devise_symbole'] as String?,
    );
  }
}

/// Un remboursement recu pour une [Dette].
class DetteRemboursement {
  final int? id;
  final int detteId;
  final double montant;
  final DateTime date;
  final String? notes;

  DetteRemboursement({
    this.id,
    required this.detteId,
    required this.montant,
    required this.date,
    this.notes,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'dette_id': detteId,
      'montant': montant,
      'date': date.toIso8601String(),
      'notes': notes,
    };
  }

  factory DetteRemboursement.fromMap(Map<String, dynamic> map) {
    return DetteRemboursement(
      id: map['id'] as int?,
      detteId: map['dette_id'] as int,
      montant: (map['montant'] as num).toDouble(),
      date: DateTime.parse(map['date'] as String),
      notes: map['notes'] as String?,
    );
  }
}
