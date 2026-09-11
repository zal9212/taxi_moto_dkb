/// Un revenu ou une depense generique rattache a une entite de categorie
/// (ex: la vente du jour d'une boutique). [type] = 'revenu' | 'depense'.
/// Les valeurs des champs personnalises de niveau "transaction" sont
/// stockees a part (table categorie_transaction_valeurs).
class CategorieTransaction {
  final int? id;
  final int entiteId;
  final String type;
  final double montant;
  final DateTime date;
  final String? description;

  CategorieTransaction({
    this.id,
    required this.entiteId,
    required this.type,
    required this.montant,
    required this.date,
    this.description,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'entite_id': entiteId,
      'type': type,
      'montant': montant,
      'date': date.toIso8601String(),
      'description': description,
    };
  }

  factory CategorieTransaction.fromMap(Map<String, dynamic> map) {
    return CategorieTransaction(
      id: map['id'] as int?,
      entiteId: map['entite_id'] as int,
      type: map['type'] as String,
      montant: (map['montant'] as num).toDouble(),
      date: DateTime.parse(map['date'] as String),
      description: map['description'] as String?,
    );
  }
}
