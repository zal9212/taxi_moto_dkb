import '../core/constants.dart';

/// Un versement = une échéance du plan de remboursement d'une moto.
/// `montantPrevu` garde la trace du montant configuré au moment de la
/// génération de l'échéance ; `montantPaye` peut différer si le gérant
/// l'ajuste au moment de la validation (paiement partiel ou différent).
class Versement {
  final int? id;
  final int motoId;
  final DateTime dateEcheance;
  final DateTime? dateValidation;
  final double montantPrevu;
  final double? montantPaye;
  final String statut; // en_attente | paye | en_retard
  final String? notes;

  Versement({
    this.id,
    required this.motoId,
    required this.dateEcheance,
    this.dateValidation,
    required this.montantPrevu,
    this.montantPaye,
    this.statut = AppConstants.versementEnAttente,
    this.notes,
  });

  Versement copyWith({
    DateTime? dateValidation,
    double? montantPaye,
    String? statut,
    String? notes,
  }) {
    return Versement(
      id: id,
      motoId: motoId,
      dateEcheance: dateEcheance,
      dateValidation: dateValidation ?? this.dateValidation,
      montantPrevu: montantPrevu,
      montantPaye: montantPaye ?? this.montantPaye,
      statut: statut ?? this.statut,
      notes: notes ?? this.notes,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'moto_id': motoId,
      'date_echeance': dateEcheance.toIso8601String(),
      'date_validation': dateValidation?.toIso8601String(),
      'montant_prevu': montantPrevu,
      'montant_paye': montantPaye,
      'statut': statut,
      'notes': notes,
    };
  }

  factory Versement.fromMap(Map<String, dynamic> map) {
    return Versement(
      id: map['id'] as int?,
      motoId: map['moto_id'] as int,
      dateEcheance: DateTime.parse(map['date_echeance'] as String),
      dateValidation: map['date_validation'] != null
          ? DateTime.parse(map['date_validation'] as String)
          : null,
      montantPrevu: (map['montant_prevu'] as num).toDouble(),
      montantPaye:
          map['montant_paye'] != null ? (map['montant_paye'] as num).toDouble() : null,
      statut: map['statut'] as String,
      notes: map['notes'] as String?,
    );
  }
}
