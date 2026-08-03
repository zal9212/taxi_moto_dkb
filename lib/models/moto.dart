import '../core/constants.dart';

/// Représente une moto-taxi et son plan de versements récurrents.
/// Il n'y a pas de "montant total à rembourser" : le gérant collecte un
/// versement fixe à chaque échéance, indéfiniment, tant que la moto est
/// active. Tous les paramètres (montant, fréquence, jour de référence)
/// sont configurables librement à la création et modifiables ensuite.
class Moto {
  final int? id;
  final String nom;
  final String chauffeur;
  final double montantVersement;

  /// AppConstants.freqHebdomadaire | freqMensuelle | freqPersonnalisee
  final String frequenceType;

  /// Sens selon frequenceType :
  /// - hebdomadaire : jour de la semaine, 1 (Lundi) à 7 (Dimanche)
  /// - mensuelle    : jour du mois, 1 à 31
  /// - personnalisee: intervalle en nombre de jours entre deux versements
  final int frequenceValeur;

  final DateTime dateDebut;
  final String statut; // actif | suspendu | archive
  final DateTime dateCreation;
  final String? notes;

  Moto({
    this.id,
    required this.nom,
    required this.chauffeur,
    required this.montantVersement,
    required this.frequenceType,
    required this.frequenceValeur,
    required this.dateDebut,
    this.statut = AppConstants.motoActive,
    DateTime? dateCreation,
    this.notes,
  }) : dateCreation = dateCreation ?? DateTime.now();

  Moto copyWith({
    int? id,
    String? nom,
    String? chauffeur,
    double? montantVersement,
    String? frequenceType,
    int? frequenceValeur,
    DateTime? dateDebut,
    String? statut,
    String? notes,
  }) {
    return Moto(
      id: id ?? this.id,
      nom: nom ?? this.nom,
      chauffeur: chauffeur ?? this.chauffeur,
      montantVersement: montantVersement ?? this.montantVersement,
      frequenceType: frequenceType ?? this.frequenceType,
      frequenceValeur: frequenceValeur ?? this.frequenceValeur,
      dateDebut: dateDebut ?? this.dateDebut,
      statut: statut ?? this.statut,
      dateCreation: dateCreation,
      notes: notes ?? this.notes,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'nom': nom,
      'chauffeur': chauffeur,
      'montant_versement': montantVersement,
      'frequence_type': frequenceType,
      'frequence_valeur': frequenceValeur,
      'date_debut': dateDebut.toIso8601String(),
      'statut': statut,
      'date_creation': dateCreation.toIso8601String(),
      'notes': notes,
    };
  }

  factory Moto.fromMap(Map<String, dynamic> map) {
    return Moto(
      id: map['id'] as int?,
      nom: map['nom'] as String,
      chauffeur: map['chauffeur'] as String,
      montantVersement: (map['montant_versement'] as num).toDouble(),
      frequenceType: map['frequence_type'] as String,
      frequenceValeur: map['frequence_valeur'] as int,
      dateDebut: DateTime.parse(map['date_debut'] as String),
      statut: map['statut'] as String,
      dateCreation: DateTime.parse(map['date_creation'] as String),
      notes: map['notes'] as String?,
    );
  }
}
