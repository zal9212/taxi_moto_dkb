import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../models/categorie_activite.dart';
import '../../models/categorie_entite.dart';
import '../../models/dette.dart';
import '../../models/moto.dart';
import '../../services/database_service.dart';

/// Creation ou modification d'une dette. Le lien optionnel (aucun / une
/// moto / une entite de categorie) peut etre pre-rempli et fige quand
/// l'ecran est ouvert depuis la fiche d'une moto ou d'une entite (le
/// gerant n'a alors rien a choisir).
class AddEditDetteScreen extends StatefulWidget {
  final Dette? detteExistante;
  final String? lienTypeInitial;
  final int? lienIdInitial;
  final String? lienNomInitial;

  const AddEditDetteScreen({
    super.key,
    this.detteExistante,
    this.lienTypeInitial,
    this.lienIdInitial,
    this.lienNomInitial,
  });

  @override
  State<AddEditDetteScreen> createState() => _AddEditDetteScreenState();
}

class _AddEditDetteScreenState extends State<AddEditDetteScreen> {
  final _formKey = GlobalKey<FormState>();
  final _db = DatabaseService.instance;
  late final TextEditingController _nomCtrl;
  late final TextEditingController _montantCtrl;
  late final TextEditingController _notesCtrl;
  late final TextEditingController _deviseCtrl;
  DateTime _date = DateTime.now();

  late bool _lienFige;
  String? _lienType;
  int? _lienId;
  String? _lienNom;
  // Devise du lien choisi (moto : toujours la devise globale : entite de
  // categorie : celle de sa categorie) — affichee a titre informatif tant
  // qu'un lien est actif, le champ devise libre etant alors sans effet.
  String? _deviseLien;
  String _deviseGlobale = AppConstants.devisePardDefaut;
  // Renseigne quand la dette avait un lien enregistre mais que la moto/
  // entite visee n'existe plus : le lien est alors reinitialise a "Aucun"
  // dans le formulaire (sinon le menu deroulant planterait, sa valeur ne
  // correspondant plus a aucun item) et ce message explique pourquoi.
  String? _messageLienSupprime;

  List<Moto> _motos = [];
  List<CategorieActivite> _categories = [];
  List<CategorieEntite> _entitesCategorieChoisie = [];
  int? _categorieChoisieId;

  bool _chargement = true;
  bool _enregistrement = false;

  bool get _modeEdition => widget.detteExistante != null;

  @override
  void initState() {
    super.initState();
    final d = widget.detteExistante;
    _nomCtrl = TextEditingController(text: d?.nomPersonne ?? '');
    _montantCtrl = TextEditingController(text: d?.montantInitial.toStringAsFixed(0) ?? '');
    _notesCtrl = TextEditingController(text: d?.notes ?? '');
    _deviseCtrl = TextEditingController(text: d?.deviseSymbole ?? '');
    // Reconstruit l'ecran a la frappe pour que le libelle du montant
    // ("Montant prete (FG)") reste a jour avec la devise en cours de saisie.
    _deviseCtrl.addListener(() {
      if (mounted) setState(() {});
    });
    if (d != null) _date = d.date;

    _lienType = d?.lienType ?? widget.lienTypeInitial;
    _lienId = d?.lienId ?? widget.lienIdInitial;
    _lienNom = widget.lienNomInitial;
    _lienFige = widget.lienTypeInitial != null;

    _charger();
  }

  Future<void> _charger() async {
    final motos = await _db.listerMotos();
    final categories = await _db.listerCategoriesActivite();
    final params = await _db.obtenirParametres();
    if (!mounted) return;
    setState(() {
      _motos = motos;
      _categories = categories;
      _deviseGlobale = params.deviseSymbole;
      // Devise libre par defaut = devise globale, uniquement si rien n'est
      // deja saisi (nouvelle dette, ou ancienne dette sans devise stockee) ;
      // sans effet si la dette finit par etre liee a une moto/entite.
      if (_deviseCtrl.text.isEmpty) _deviseCtrl.text = params.deviseSymbole;
      _chargement = false;
    });

    // Mode edition sans pre-remplissage direct : retrouve le nom du lien
    // existant pour l'affichage, et pour une entite de categorie, pre-
    // selectionne aussi sa categorie pour que le menu deroulant "Entite"
    // propose bien l'entite actuellement liee.
    if (_modeEdition && _lienNom == null && _lienType != null && _lienId != null) {
      if (_lienType == AppConstants.detteLienMoto) {
        final moto = motos.where((m) => m.id == _lienId).toList();
        if (moto.isNotEmpty && mounted) {
          setState(() => _lienNom = moto.first.nom);
        } else if (mounted) {
          setState(() {
            _lienType = null;
            _lienId = null;
            _messageLienSupprime =
                'La moto liee a cette dette a ete supprimee. Choisissez-en une autre ou laissez sans lien.';
          });
        }
      } else if (_lienType == AppConstants.detteLienCategorieEntite) {
        final entite = await _db.obtenirEntiteCategorie(_lienId!);
        if (entite != null && mounted) {
          setState(() => _lienNom = entite.nom);
          setState(() => _categorieChoisieId = entite.categorieId);
          await _choisirCategorieEntite();
        } else if (mounted) {
          setState(() {
            _lienType = null;
            _lienId = null;
            _messageLienSupprime =
                'L\'entite liee a cette dette a ete supprimee. Choisissez-en une autre ou laissez sans lien.';
          });
        }
      }
    }

    // Devise du lien deja connu au chargement (lien fige depuis une fiche
    // moto/entite, ou dette existante deja liee) : resolue directement via
    // _lienId, disponible dans les deux cas (contrairement a
    // _categorieChoisieId, rempli seulement en mode edition ci-dessus).
    if (_lienType == AppConstants.detteLienMoto && _lienId != null) {
      setState(() => _deviseLien = params.deviseSymbole);
    } else if (_lienType == AppConstants.detteLienCategorieEntite && _lienId != null) {
      final entite = await _db.obtenirEntiteCategorie(_lienId!);
      if (entite != null) {
        final categorie = categories.where((c) => c.id == entite.categorieId).toList();
        if (categorie.isNotEmpty && mounted) setState(() => _deviseLien = categorie.first.deviseSymbole);
      }
    }
  }

  void _mettreAJourDeviseCategorie() {
    final categorie = _categories.where((c) => c.id == _categorieChoisieId).toList();
    if (categorie.isNotEmpty) setState(() => _deviseLien = categorie.first.deviseSymbole);
  }

  /// Devise a afficher a titre indicatif pres du montant : celle du lien
  /// actif s'il y en a un, sinon celle saisie librement (ou la globale par
  /// defaut tant que rien n'est encore tape).
  String _deviseEffectiveAffichee() {
    if (_deviseLien != null) return _deviseLien!;
    final saisie = _deviseCtrl.text.trim();
    return saisie.isEmpty ? _deviseGlobale : saisie;
  }

  Future<void> _choisirCategorieEntite() async {
    if (_categorieChoisieId == null) return;
    final entites = await _db.listerEntitesCategorie(_categorieChoisieId!);
    if (!mounted) return;
    setState(() => _entitesCategorieChoisie = entites);
  }

  Future<void> _enregistrer() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _enregistrement = true);
    try {
      final dette = Dette(
        id: widget.detteExistante?.id,
        nomPersonne: _nomCtrl.text.trim(),
        montantInitial: double.parse(_montantCtrl.text.replaceAll(' ', '')),
        date: _date,
        notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        dateCreation: widget.detteExistante?.dateCreation,
        lienType: _lienId != null ? _lienType : null,
        lienId: _lienId,
        // Sans effet des qu'un lien est actif (la devise vient alors de la
        // moto/entite liee) : n'a d'importance que pour une dette independante.
        deviseSymbole: _deviseCtrl.text.trim().isEmpty ? null : _deviseCtrl.text.trim(),
      );

      if (_modeEdition) {
        await _db.modifierDette(dette);
      } else {
        await _db.insererDette(dette);
      }

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _enregistrement = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erreur lors de l\'enregistrement : $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_modeEdition ? 'Modifier la dette' : 'Nouvelle dette')),
      body: _chargement
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    TextFormField(
                      controller: _nomCtrl,
                      decoration: const InputDecoration(labelText: 'Nom de la personne'),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Champ requis' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _montantCtrl,
                      decoration: InputDecoration(labelText: 'Montant prete (${_deviseEffectiveAffichee()})'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      validator: (v) =>
                          (double.tryParse((v ?? '').replaceAll(' ', '')) == null) ? 'Montant invalide' : null,
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Date', style: TextStyle(fontSize: 13)),
                      subtitle: Text('${_date.day}/${_date.month}/${_date.year}'),
                      trailing: const Icon(Icons.calendar_today_outlined, size: 18),
                      onTap: () async {
                        final choisie = await showDatePicker(
                          context: context,
                          initialDate: _date,
                          firstDate: DateTime(2015),
                          lastDate: DateTime(2100),
                        );
                        if (choisie != null) setState(() => _date = choisie);
                      },
                    ),
                    const Divider(),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _notesCtrl,
                      decoration: const InputDecoration(labelText: 'Motif (optionnel)'),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 20),
                    const Text('Lien (optionnel)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(
                      'Si cet argent concerne une moto ou une boutique precise, '
                      'rattachez la dette pour la retrouver depuis sa fiche.',
                      style: TextStyle(color: AppColors.texteGris, fontSize: 10),
                    ),
                    const SizedBox(height: 10),
                    if (_messageLienSupprime != null) ...[
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.dangerFond,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.link_off, size: 15, color: AppColors.danger),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(_messageLienSupprime!,
                                  style: const TextStyle(color: AppColors.danger, fontSize: 11)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (_lienFige)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.bordure, width: 0.6),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.link, size: 16, color: AppColors.texteGris),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(_lienNom ?? '...',
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                            ),
                            if (_deviseLien != null)
                              Text('devise : $_deviseLien',
                                  style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
                          ],
                        ),
                      )
                    else ...[
                      Row(
                        children: [
                          Expanded(child: _puceLien('Aucun', null)),
                          const SizedBox(width: 8),
                          Expanded(child: _puceLien('Une moto', AppConstants.detteLienMoto)),
                          const SizedBox(width: 8),
                          Expanded(child: _puceLien('Une categorie', AppConstants.detteLienCategorieEntite)),
                        ],
                      ),
                      if (_lienType == null) ...[
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _deviseCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Devise',
                            helperText: 'Ex: FG, FCFA, GNF — propre a cette dette independante',
                          ),
                        ),
                      ],
                      if (_lienType == AppConstants.detteLienMoto) ...[
                        const SizedBox(height: 10),
                        DropdownButtonFormField<int>(
                          initialValue: _lienId,
                          decoration: const InputDecoration(labelText: 'Moto'),
                          items: _motos
                              .map((m) => DropdownMenuItem(value: m.id, child: Text('${m.nom} - ${m.chauffeur}')))
                              .toList(),
                          onChanged: (v) => setState(() => _lienId = v),
                        ),
                      ],
                      if (_lienType == AppConstants.detteLienCategorieEntite) ...[
                        const SizedBox(height: 10),
                        DropdownButtonFormField<int>(
                          initialValue: _categorieChoisieId,
                          decoration: const InputDecoration(labelText: 'Categorie'),
                          items: _categories
                              .map((c) => DropdownMenuItem(value: c.id, child: Text(c.nom)))
                              .toList(),
                          onChanged: (v) {
                            setState(() {
                              _categorieChoisieId = v;
                              _lienId = null;
                              _entitesCategorieChoisie = [];
                            });
                            _choisirCategorieEntite();
                            _mettreAJourDeviseCategorie();
                          },
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<int>(
                          initialValue: _lienId,
                          decoration: const InputDecoration(labelText: 'Entite'),
                          items: _entitesCategorieChoisie
                              .map((e) => DropdownMenuItem(value: e.id, child: Text(e.nom)))
                              .toList(),
                          onChanged: (v) => setState(() => _lienId = v),
                        ),
                        if (_deviseLien != null) ...[
                          const SizedBox(height: 6),
                          Text('Devise de cette categorie : $_deviseLien',
                              style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
                        ],
                      ],
                    ],
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: _enregistrement ? null : _enregistrer,
                      child: Text(_enregistrement ? 'Enregistrement...' : 'Enregistrer'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _puceLien(String label, String? valeur) {
    final actif = _lienType == valeur;
    return GestureDetector(
      onTap: () => setState(() {
        _lienType = valeur;
        _lienId = null;
        _categorieChoisieId = null;
        _entitesCategorieChoisie = [];
        // Une moto est toujours dans la devise globale, connue tout de
        // suite ; une categorie n'a pas encore ete choisie a ce stade.
        _deviseLien = valeur == AppConstants.detteLienMoto ? _deviseGlobale : null;
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: actif ? AppColors.carteNoire : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: actif ? AppColors.carteNoire : AppColors.bordure),
        ),
        child: Text(label,
            textAlign: TextAlign.center,
            style: TextStyle(color: actif ? Colors.white : AppColors.texteGris, fontSize: 11)),
      ),
    );
  }
}
