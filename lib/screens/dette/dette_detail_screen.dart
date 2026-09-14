import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../models/dette.dart';
import '../../services/database_service.dart';
import '../../utils/formatters.dart';
import '../categorie/categorie_entite_detail_screen.dart';
import '../moto_detail_screen.dart';
import 'add_edit_dette_screen.dart';

/// Detail d'une dette : montant initial, solde restant du, historique des
/// remboursements recus, et lien optionnel vers la moto ou l'entite
/// concernee.
class DetteDetailScreen extends StatefulWidget {
  final int detteId;
  const DetteDetailScreen({super.key, required this.detteId});

  @override
  State<DetteDetailScreen> createState() => _DetteDetailScreenState();
}

class _DetteDetailScreenState extends State<DetteDetailScreen> {
  final _db = DatabaseService.instance;
  Dette? _dette;
  List<DetteRemboursement> _remboursements = [];
  double _solde = 0;
  String _devise = AppConstants.devisePardDefaut;
  String? _lienNom;
  // true quand la dette a un lien enregistre (lienType/lienId) mais que la
  // moto ou l'entite visee n'existe plus (supprimee depuis) : affiche un
  // message clair au lieu d'un lien muet ou d'un ecran qui ne charge jamais.
  bool _lienSupprime = false;
  bool _chargement = true;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    setState(() => _chargement = true);
    final dette = await _db.obtenirDette(widget.detteId);
    if (dette == null) {
      if (mounted) Navigator.pop(context);
      return;
    }
    final remboursements = await _db.listerRemboursements(widget.detteId);
    final solde = await _db.soldeDette(widget.detteId);
    final devise = await _db.deviseEffectiveDette(dette);

    String? lienNom;
    var lienSupprime = false;
    if (dette.lienType == AppConstants.detteLienMoto && dette.lienId != null) {
      final moto = await _db.obtenirMoto(dette.lienId!);
      lienNom = moto?.nom;
      lienSupprime = moto == null;
    } else if (dette.lienType == AppConstants.detteLienCategorieEntite && dette.lienId != null) {
      final entite = await _db.obtenirEntiteCategorie(dette.lienId!);
      lienNom = entite?.nom;
      lienSupprime = entite == null;
    }

    if (!mounted) return;
    setState(() {
      _dette = dette;
      _remboursements = remboursements;
      _solde = solde;
      _devise = devise;
      _lienNom = lienNom;
      _lienSupprime = lienSupprime;
      _chargement = false;
    });
  }

  Future<void> _ouvrirLien() async {
    final dette = _dette;
    if (dette?.lienType == null || dette?.lienId == null) return;
    if (dette!.lienType == AppConstants.detteLienMoto) {
      final moto = await _db.obtenirMoto(dette.lienId!);
      if (moto == null) {
        if (mounted) _afficherLienSupprime('Cette moto a ete supprimee.');
        return;
      }
      if (!mounted) return;
      await Navigator.push(context, MaterialPageRoute(builder: (_) => MotoDetailScreen(motoId: dette.lienId!)));
    } else if (dette.lienType == AppConstants.detteLienCategorieEntite) {
      final entite = await _db.obtenirEntiteCategorie(dette.lienId!);
      if (entite == null) {
        if (mounted) _afficherLienSupprime('Cette entite (boutique, etc.) a ete supprimee.');
        return;
      }
      final categorie = await _db.obtenirCategorieActivite(entite.categorieId);
      if (categorie == null || !mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => CategorieEntiteDetailScreen(entiteId: entite.id!, categorie: categorie)),
      );
    }
    _charger();
  }

  void _afficherLienSupprime(String message) {
    // Le lien enregistre pointe sur un id qui n'existe plus en base :
    // recharge l'ecran pour refleter l'etat "supprime" a l'affichage,
    // plutot que de rester sur l'ancien libelle en cache.
    _charger();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _ajouterRemboursement() async {
    final montantCtrl = TextEditingController();
    DateTime date = DateTime.now();
    final formKey = GlobalKey<FormState>();

    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          title: const Text('Ajouter un remboursement'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: montantCtrl,
                  autofocus: true,
                  decoration: InputDecoration(labelText: 'Montant ($_devise)'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) =>
                      (double.tryParse((v ?? '').replaceAll(' ', '')) == null) ? 'Montant invalide' : null,
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Date', style: TextStyle(fontSize: 13)),
                  subtitle: Text(formaterDate(date)),
                  trailing: const Icon(Icons.calendar_today_outlined, size: 18),
                  onTap: () async {
                    final choisie = await showDatePicker(
                      context: context,
                      initialDate: date,
                      firstDate: DateTime(2015),
                      lastDate: DateTime(2100),
                    );
                    if (choisie != null) setStateDialog(() => date = choisie);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
            TextButton(
              onPressed: () {
                if (formKey.currentState!.validate()) Navigator.pop(context, true);
              },
              child: const Text('Ajouter'),
            ),
          ],
        ),
      ),
    );

    if (confirme != true) return;
    await _db.insererRemboursement(DetteRemboursement(
      detteId: widget.detteId,
      montant: double.parse(montantCtrl.text.replaceAll(' ', '')),
      date: date,
    ));
    _charger();
  }

  Future<void> _supprimerRemboursement(DetteRemboursement r) async {
    if (r.id == null) return;
    await _db.supprimerRemboursement(r.id!);
    _charger();
  }

  Future<void> _supprimerDette() async {
    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer cette dette ?'),
        content: const Text('Cette dette et tous ses remboursements seront definitivement supprimes.'),
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
    if (confirme != true) return;
    await _db.supprimerDette(widget.detteId);
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_chargement || _dette == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final dette = _dette!;
    final soldee = _solde <= 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(dette.nomPersonne),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => AddEditDetteScreen(detteExistante: dette)),
              );
              _charger();
            },
          ),
          IconButton(icon: const Icon(Icons.delete_outline), onPressed: _supprimerDette),
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
                  Text(soldee ? 'Dette soldee' : 'Reste du', style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
                  const SizedBox(height: 4),
                  Text(formaterMontant(_solde < 0 ? 0 : _solde, _devise),
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('Montant prete : ${formaterMontant(dette.montantInitial, _devise)}',
                      style: TextStyle(color: AppColors.texteGris, fontSize: 11)),
                  if (dette.notes != null && dette.notes!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(dette.notes!, style: TextStyle(color: AppColors.texteGris, fontSize: 11)),
                  ],
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Ajouter un remboursement'),
                      onPressed: _ajouterRemboursement,
                    ),
                  ),
                ],
              ),
            ),
            if (dette.lienType != null && dette.lienId != null) ...[
              const SizedBox(height: 12),
              InkWell(
                onTap: _ouvrirLien,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _lienSupprime ? AppColors.dangerFond : Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _lienSupprime ? AppColors.danger : AppColors.bordure, width: 0.6),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _lienSupprime ? Icons.link_off : Icons.link,
                        size: 16,
                        color: _lienSupprime ? AppColors.danger : AppColors.texteGris,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _lienSupprime
                              ? (dette.lienType == AppConstants.detteLienMoto
                                  ? 'Moto supprimee'
                                  : 'Entite supprimee')
                              : (_lienNom ?? '...'),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _lienSupprime ? AppColors.danger : null,
                          ),
                        ),
                      ),
                      Icon(Icons.chevron_right, size: 18, color: _lienSupprime ? AppColors.danger : AppColors.texteGris),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            const Text('Remboursements', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (_remboursements.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text('Aucun remboursement pour le moment.',
                      style: TextStyle(color: AppColors.texteGris, fontSize: 12)),
                ),
              )
            else
              ..._remboursements.map((r) => _ligneRemboursement(r)),
          ],
        ),
      ),
    );
  }

  Widget _ligneRemboursement(DetteRemboursement r) {
    return Dismissible(
      key: ValueKey(r.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        decoration: BoxDecoration(color: AppColors.dangerFond, borderRadius: BorderRadius.circular(10)),
        child: const Icon(Icons.delete_outline, color: AppColors.danger),
      ),
      onDismissed: (_) => _supprimerRemboursement(r),
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
              child: Text(formaterDate(r.date), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
            ),
            Text('+${formaterMontant(r.montant, _devise)}',
                style: const TextStyle(color: AppColors.succes, fontWeight: FontWeight.w600, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
