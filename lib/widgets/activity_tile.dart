import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../utils/formatters.dart';

class ActivityTile extends StatelessWidget {
  final IconData icone;
  final String titre;
  final DateTime date;
  final double montant;
  final bool estPositif; // vert (versement encaisse) ou rouge (depense)
  final String devise;

  const ActivityTile({
    super.key,
    required this.icone,
    required this.titre,
    required this.date,
    required this.montant,
    required this.estPositif,
    required this.devise,
  });

  @override
  Widget build(BuildContext context) {
    final couleur = estPositif ? AppColors.succes : AppColors.danger;
    final couleurFond = estPositif ? AppColors.succesFond : AppColors.dangerFond;
    final signe = estPositif ? '+' : '-';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: couleurFond, shape: BoxShape.circle),
            child: Icon(icone, color: couleur, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titre, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                Text(formaterDate(date), style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
              ],
            ),
          ),
          Text(
            '$signe${formaterMontant(montant, devise)}',
            style: TextStyle(color: couleur, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
