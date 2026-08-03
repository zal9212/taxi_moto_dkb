import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/moto.dart';
import '../models/versement.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';
import '../services/pdf_service.dart';
import '../services/schedule_service.dart';
import '../utils/formatters.dart';
import 'add_edit_moto_screen.dart';

class MotoDetailScreen extends StatefulWidget {
  final int motoId;
  const MotoDetailScreen({super.key, required this.motoId});

  @override
  State<MotoDetailScreen> createState() => _MotoDetailScreenState();
}

class _MotoDetailScreenState extends State<MotoDetailScreen> {
  final _db = DatabaseService.instance;
  Moto? _moto;
  List<Versement> _versements = [];
  double _solde = 0;
  String _devise = AppConstants.devisePardDefaut;
  bool _chargement = true;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    setState(() => _chargement = true);
    final moto = await _db.obtenirMoto(widget.motoId);
    if (moto == null) return;
    final versements = await _db.listerVersementsParMoto(widget.motoId);
    final solde = await _db.soldeRestant(widget.motoId, moto.montantTotal);
    final params = await _db.obtenirParametres();

    if (!mounted) return;
    setState(() {
      _moto = moto;
      _versements = versements;
      _solde = solde;
      _devise = params.deviseSymbole;
      _chargement = false;
    });

    // Moto entierement remboursee -> statut "solde" automatique
    if (solde <= 0 && moto.statut != AppConstants.motoSoldee) {
      await _db.modifierMoto(moto.copyWith(statut: AppConstants.motoSoldee));
    }
  }

  Versement? get _prochain {
    final enAttente = _versements
        .where((v) => v.statut != AppConstants.versementPaye)
        .toList()
      ..sort((a, b) => a.dateEcheance.compareTo(b.dateEcheance));
    return enAttente.isNotEmpty ? enAttente.first : null;
  }

  Future<void> _validerVersement(Versement v) async {
    final controleur = TextEditingController(text: v.montantPrevu.toStringAsFixed(0));
    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Valider le versement'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Echeance du ${formaterDate(v.dateEcheance)}',
                style: TextStyle(color: AppColors.texteGris, fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: controleur,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Montant verse'),
            ),
            const SizedBox(height: 4),
            Text('Modifiable si le chauffeur a verse un montant different',
                style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Valider')),
        ],
      ),
    );

    if (confirme != true) return;
    final montant = double.tryParse(controleur.text) ?? v.montantPrevu;
    await _db.validerVersement(v.id!, montantPaye: montant);
    if (v.id != null) await NotificationService.annulerRappel(v.id!);
    _charger();
  }

  Future<void> _exporterPdf() async {
    if (_moto == null) return;
    final depenses = await _db.listerDepensesParMoto(widget.motoId);
    await PdfService.genererEtPartagerReleve(
      moto: _moto!,
      versements: _versements,
      depenses: depenses,
      soldeRestant: _solde,
      deviseSymbole: _devise,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_chargement || _moto == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final moto = _moto!;
    final prochain = _prochain;

    return Scaffold(
      appBar: AppBar(
        title: Text('${moto.nom} - ${moto.chauffeur}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf_outlined),
            tooltip: 'Exporter le releve',
            onPressed: _exporterPdf,
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => AddEditMotoScreen(motoExistante: moto)),
              );
              _charger();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _charger,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: AppColors.carteNoire, borderRadius: BorderRadius.circular(14)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Solde restant sur ${formaterMontant(moto.montantTotal, _devise)}',
                    style: TextStyle(color: AppColors.texteGris, fontSize: 10),
                  ),
                  const SizedBox(height: 4),
                  Text(formaterMontant(_solde, _devise),
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    ScheduleService.libelleFrequence(moto.frequenceType, moto.frequenceValeur),
                    style: TextStyle(color: AppColors.texteGris, fontSize: 11),
                  ),
                  const SizedBox(height: 14),
                  if (moto.statut == AppConstants.motoSoldee)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                          color: AppColors.accentLime.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(10)),
                      child: const Center(
                        child: Text('Moto entierement remboursee',
                            style: TextStyle(color: AppColors.accentLime, fontWeight: FontWeight.w600, fontSize: 12)),
                      ),
                    )
                  else if (prochain != null)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => _validerVersement(prochain),
                        icon: const Icon(Icons.check, size: 16),
                        label: Text(
                            'Valider versement (${formaterMontant(prochain.montantPrevu, _devise)})'),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Text('Historique des versements', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ..._versements.map((v) => _ligneVersement(v)),
          ],
        ),
      ),
    );
  }

  Widget _ligneVersement(Versement v) {
    late Color couleur;
    late String libelle;
    switch (v.statut) {
      case AppConstants.versementPaye:
        couleur = AppColors.succes;
        libelle = 'Paye';
        break;
      case AppConstants.versementEnRetard:
        couleur = AppColors.danger;
        libelle = 'En retard';
        break;
      default:
        couleur = AppColors.texteGris;
        libelle = 'A venir';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.bordure, width: 0.6),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(formaterDate(v.dateEcheance), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                Text(libelle, style: TextStyle(color: couleur, fontSize: 10)),
              ],
            ),
          ),
          Text(
            formaterMontant(v.montantPaye ?? v.montantPrevu, _devise),
            style: TextStyle(
              color: v.statut == AppConstants.versementPaye ? AppColors.succes : AppColors.texteNoir,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
          if (v.statut != AppConstants.versementPaye) ...[
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.check_circle_outline, size: 20),
              color: AppColors.succes,
              onPressed: () => _validerVersement(v),
            ),
          ],
        ],
      ),
    );
  }
}
