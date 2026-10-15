import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/moto.dart';
import '../services/schedule_service.dart';
import '../utils/formatters.dart';

class MotoCard extends StatelessWidget {
  final Moto moto;
  final double totalVerse;
  /// Retard et avance (voir [ScheduleService.compte]).
  final CompteMoto compte;
  /// Prochaine periode a payer et ce qu'il en reste (la plus ancienne d'abord).
  final ({DateTime date, String etat, double reste})? prochainVersement;
  final String devise;
  final VoidCallback onTap;

  const MotoCard({
    super.key,
    required this.moto,
    required this.totalVerse,
    required this.compte,
    required this.prochainVersement,
    required this.devise,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final estEnRetard = compte.retard > 0;
    final estEnAvance = compte.avance > 0;
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
            // Moto suspendue : ses retards d'avant la pause restent dus.
            if (estEnRetard) ...[
              const SizedBox(height: 4),
              Text(
                'En retard de ${formaterMontant(compte.retard, devise)}',
                style: const TextStyle(color: AppColors.danger, fontSize: 10, fontWeight: FontWeight.w600),
              ),
            ],
            if (estEnAvance) ...[
              const SizedBox(height: 4),
              Text(
                'Paye d\'avance : ${formaterMontant(compte.avance, devise)}',
                style: const TextStyle(color: AppColors.succes, fontSize: 10, fontWeight: FontWeight.w600),
              ),
            ],
            const SizedBox(height: 8),
            if (prochainVersement != null && !estInactive)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Prochain: ${formaterDate(prochainVersement!.date)}',
                    style: TextStyle(color: AppColors.texteGris, fontSize: 10),
                  ),
                  Text(
                    formaterMontant(prochainVersement!.reste, devise),
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
