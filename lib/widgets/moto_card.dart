import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/moto.dart';
import '../models/versement.dart';
import '../utils/formatters.dart';

class MotoCard extends StatelessWidget {
  final Moto moto;
  final double totalVerse;
  /// Solde net : negatif = retard (dette), positif = avance (credit).
  final double solde;
  final Versement? prochainVersement;
  final String devise;
  final VoidCallback onTap;

  const MotoCard({
    super.key,
    required this.moto,
    required this.totalVerse,
    required this.solde,
    required this.prochainVersement,
    required this.devise,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final estEnRetard = solde < 0;
    final estEnAvance = solde > 0;
    final estInactive = moto.statut != AppConstants.motoActive;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.bordure, width: 0.6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${moto.nom} - ${moto.chauffeur}',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (moto.id != null) ...[
                  Text(
                    'N°${moto.id}',
                    style: TextStyle(color: AppColors.texteGris, fontSize: 10),
                  ),
                  const SizedBox(width: 8),
                ],
                _badgeStatut(estInactive, estEnRetard),
              ],
            ),
            const SizedBox(height: 10),
            Text('Total encaisse', style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
            const SizedBox(height: 2),
            Text(
              formaterMontant(totalVerse, devise),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            if (!estInactive && (estEnRetard || estEnAvance)) ...[
              const SizedBox(height: 4),
              Text(
                estEnRetard
                    ? 'En retard de ${formaterMontant(-solde, devise)}'
                    : 'En avance de ${formaterMontant(solde, devise)}',
                style: TextStyle(
                  color: estEnRetard ? AppColors.danger : AppColors.succes,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 8),
            if (prochainVersement != null && !estInactive)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Prochain: ${formaterDate(prochainVersement!.dateEcheance)}',
                    style: TextStyle(color: AppColors.texteGris, fontSize: 10),
                  ),
                  Text(
                    formaterMontant(prochainVersement!.montantPrevu, devise),
                    style: TextStyle(color: AppColors.texteGris, fontSize: 10),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _badgeStatut(bool estInactive, bool estEnRetard) {
    late Color fond;
    late Color texte;
    late String libelle;

    if (estInactive) {
      fond = AppColors.bordure;
      texte = AppColors.texteGris;
      libelle = moto.statut == AppConstants.motoSuspendue ? 'Suspendu' : 'Archive';
    } else if (estEnRetard) {
      fond = AppColors.dangerFond;
      texte = AppColors.danger;
      libelle = 'En retard';
    } else {
      fond = AppColors.succesFond;
      texte = AppColors.succes;
      libelle = 'A jour';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: fond, borderRadius: BorderRadius.circular(6)),
      child: Text(libelle, style: TextStyle(color: texte, fontSize: 9, fontWeight: FontWeight.w600)),
    );
  }
}
