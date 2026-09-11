import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/dette.dart';
import '../models/moto.dart';
import '../models/versement.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';
import '../services/pdf_service.dart';
import '../services/schedule_service.dart';
import '../utils/formatters.dart';
import 'add_edit_moto_screen.dart';
import 'dette/add_edit_dette_screen.dart';
import 'dette/dette_detail_screen.dart';

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
  double _totalVerse = 0;
  /// Solde net : negatif = retard (dette), positif = avance (credit).
  double _solde = 0;
  String _devise = AppConstants.devisePardDefaut;
  List<Dette> _dettes = [];
  final Map<int, double> _soldeParDette = {};
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

    // Maintient la fenetre d'echeances a venir pleine (versement recurrent
    // et indefini, pas de montant total a atteindre).
    if (moto.statut == AppConstants.motoActive) {
      await _db.assurerEcheances(moto);
    }

    final versements = await _db.listerVersementsParMoto(widget.motoId);
    final totalVerse = await _db.totalEncaisse(motoId: widget.motoId);
    final solde = await _db.soldeNet(motoId: widget.motoId);
    final params = await _db.obtenirParametres();
    final dettes = await _db.listerDettesParLien(AppConstants.detteLienMoto, widget.motoId);
    _soldeParDette.clear();
    for (final d in dettes) {
      if (d.id != null) _soldeParDette[d.id!] = await _db.soldeDette(d.id!);
    }

    if (!mounted) return;
    setState(() {
      _moto = moto;
      _versements = versements;
      _totalVerse = totalVerse;
      _solde = solde;
      _devise = params.deviseSymbole;
      _dettes = dettes;
      _chargement = false;
    });
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
    if (_moto != null) await _db.assurerEcheances(_moto!);
    _charger();
  }

  Future<void> _exporterPdf() async {
    if (_moto == null) return;
    final depenses = await _db.listerDepensesParMoto(widget.motoId);
    await PdfService.genererEtPartagerReleve(
      moto: _moto!,
      versements: _versements,
      depenses: depenses,
      deviseSymbole: _devise,
    );
  }

  /// Suspend (hors service) ou reactive la moto. Une moto suspendue arrete
  /// de generer de nouvelles echeances, de notifier, et son solde/retard
  /// n'accumule plus rien pendant qu'elle est en pause — sans rien
  /// supprimer, elle peut etre reactivee a tout moment.
  Future<void> _basculerSuspension() async {
    if (_moto?.id == null) return;
    final estActive = _moto!.statut == AppConstants.motoActive;

    if (estActive) {
      final confirme = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Suspendre cette moto ?'),
          content: const Text(
              'Aucune nouvelle echeance ne sera generee et les rappels de '
              'notification seront arretes tant qu\'elle est suspendue. '
              'L\'historique deja paye est conserve. A la reactivation, les '
              'echeances encore en attente ne compteront pas comme du retard '
              '(la moto n\'aura pas travaille pendant la pause) : le suivi '
              'repartira simplement a partir de la date de reactivation.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Suspendre')),
          ],
        ),
      );
      if (confirme != true) return;
    }

    final motoMisAJour = _moto!.copyWith(
      statut: estActive ? AppConstants.motoSuspendue : AppConstants.motoActive,
    );
    await _db.modifierMoto(motoMisAJour);

    // Dans les deux sens, les rappels des echeances encore en attente
    // (celles d'avant le changement de statut) n'ont plus lieu d'etre.
    for (final v in _versements) {
      if (v.statut != AppConstants.versementPaye && v.id != null) {
        await NotificationService.annulerRappel(v.id!);
      }
    }

    if (!estActive) {
      // Reactivation apres une pause : la moto n'a pas travaille pendant
      // ce temps, ses echeances non payees d'avant la pause ne doivent
      // donc pas compter comme du retard - on repart d'une fenetre
      // fraiche a partir d'aujourd'hui plutot que de la date ou elle
      // s'etait arretee.
      await _db.redemarrerEcheancesApresReactivation(motoMisAJour);
      final nouveauxVersements = await _db.listerVersementsParMoto(motoMisAJour.id!);
      final params = await _db.obtenirParametres();
      await NotificationService.synchroniserRappelsMoto(
        moto: motoMisAJour,
        versements: nouveauxVersements,
        delaiHeures: params.delaiNotificationHeures,
      );
    }

    _charger();
  }

  Future<void> _supprimerMoto() async {
    if (_moto?.id == null) return;
    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer cette moto ?'),
        content: Text(
          '"${_moto!.nom}" et tout son historique (versements, depenses) '
          'seront definitivement supprimes. Cette action est irreversible.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirme != true || _moto?.id == null) return;

    try {
      for (final v in _versements) {
        if (v.id != null) {
          // L'annulation du rappel est secondaire : si elle echoue (plugin
          // de notifications), la suppression de la moto ne doit pas etre
          // bloquee pour autant.
          try {
            await NotificationService.annulerRappel(v.id!);
          } catch (_) {}
        }
      }
      await _db.supprimerMoto(_moto!.id!);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erreur lors de la suppression : $e')));
      }
    }
  }

  /// Corrige le montant d'un versement deja valide, ou annule sa
  /// validation (redevient en attente / en retard) en cas d'erreur de
  /// saisie du gerant.
  Future<void> _modifierVersementPaye(Versement v) async {
    if (v.id == null) return;
    final controleur = TextEditingController(
      text: (v.montantPaye ?? v.montantPrevu).toStringAsFixed(0),
    );
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modifier ce versement'),
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
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'annuler_validation'),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Annuler la validation'),
          ),
          TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Fermer')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, 'enregistrer'),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );

    if (action == 'enregistrer') {
      final montant = double.tryParse(controleur.text);
      if (montant == null) return;
      await _db.modifierMontantPaye(v.id!, montant);
      _charger();
    } else if (action == 'annuler_validation') {
      if (!mounted) return;
      final confirme = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Annuler la validation ?'),
          content: const Text(
              'Ce versement redeviendra en attente (ou en retard si l\'echeance est deja passee).'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Non')),
            ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Oui, annuler')),
          ],
        ),
      );
      if (confirme == true) {
        await _db.annulerValidationVersement(v.id!);
        _charger();
      }
    }
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${moto.nom} - ${moto.chauffeur}'),
            if (moto.id != null)
              Text(
                'N°${moto.id}',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.normal),
              ),
          ],
        ),
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
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'suspendre') _basculerSuspension();
              if (v == 'supprimer') _supprimerMoto();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'suspendre',
                child: Text(moto.statut == AppConstants.motoActive
                    ? 'Suspendre (hors service)'
                    : 'Reactiver cette moto'),
              ),
              PopupMenuItem(
                value: 'supprimer',
                child: Text('Supprimer la moto', style: TextStyle(color: AppColors.danger)),
              ),
            ],
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
                  Text('Total encaisse', style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
                  const SizedBox(height: 4),
                  Text(formaterMontant(_totalVerse, _devise),
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    ScheduleService.libelleFrequence(moto.frequenceType, moto.frequenceValeur),
                    style: TextStyle(color: AppColors.texteGris, fontSize: 11),
                  ),
                  if (moto.statut == AppConstants.motoActive && _solde != 0) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(
                          _solde < 0 ? Icons.error_outline : Icons.trending_up,
                          color: _solde < 0 ? const Color(0xFFE2554A) : AppColors.accentLime,
                          size: 14,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _solde < 0
                              ? 'En retard de : ${formaterMontant(-_solde, _devise)}'
                              : 'En avance de : ${formaterMontant(_solde, _devise)}',
                          style: TextStyle(
                            color: _solde < 0 ? const Color(0xFFE2554A) : AppColors.accentLime,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 14),
                  if (moto.statut != AppConstants.motoActive)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.08), borderRadius: BorderRadius.circular(10)),
                      child: Center(
                        child: Text(
                          moto.statut == AppConstants.motoSuspendue ? 'Moto suspendue' : 'Moto archivee',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12),
                        ),
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Dettes liees', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                TextButton.icon(
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AddEditDetteScreen(
                          lienTypeInitial: AppConstants.detteLienMoto,
                          lienIdInitial: widget.motoId,
                          lienNomInitial: moto.nom,
                        ),
                      ),
                    );
                    _charger();
                  },
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Ajouter'),
                ),
              ],
            ),
            if (_dettes.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('Aucune dette liee.', style: TextStyle(color: AppColors.texteGris, fontSize: 12)),
              )
            else
              ..._dettes.map((d) => _ligneDette(d)),
            const SizedBox(height: 20),
            const Text('Historique des versements', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            ..._versements.map((v) => _ligneVersement(v)),
          ],
        ),
      ),
    );
  }

  Widget _ligneDette(Dette d) {
    final solde = _soldeParDette[d.id] ?? d.montantInitial;
    return InkWell(
      onTap: () async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => DetteDetailScreen(detteId: d.id!)));
        _charger();
      },
      child: Container(
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
                  Text(d.nomPersonne, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                  Text(formaterDate(d.date), style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
                ],
              ),
            ),
            Text(
              formaterMontant(solde, _devise),
              style: TextStyle(
                color: solde > 0 ? AppColors.danger : AppColors.succes,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
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

    final estPaye = v.statut == AppConstants.versementPaye;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: estPaye ? () => _modifierVersementPaye(v) : null,
      child: Container(
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
                color: estPaye ? AppColors.succes : AppColors.texteNoir,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
            if (!estPaye) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.check_circle_outline, size: 20),
                color: AppColors.succes,
                onPressed: () => _validerVersement(v),
              ),
            ] else ...[
              const SizedBox(width: 8),
              Icon(Icons.edit_outlined, size: 16, color: AppColors.texteGris),
            ],
          ],
        ),
      ),
    );
  }
}
