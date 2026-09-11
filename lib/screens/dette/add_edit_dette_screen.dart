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
  DateTime _date = DateTime.now();

  late bool _lienFige;
  String? _lienType;
  int? _lienId;
  String? _lienNom;

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
    if (!mounted) return;
    setState(() {
      _motos = motos;
      _categories = categories;
      _chargement = false;
    });

    // Mode edition sans pre-remplissage direct : retrouve le nom du lien
    // existant pour l'affichage, et pour une entite de categorie, pre-
    // selectionne aussi sa categorie pour que le menu deroulant "Entite"
    // propose bien l'entite actuellement liee.
    if (_modeEdition && _lienNom == null && _lienType != null && _lienId != null) {
      if (_lienType == AppConstants.detteLienMoto) {
        final moto = motos.where((m) => m.id == _lienId).toList();
        if (moto.isNotEmpty && mounted) setState(() => _lienNom = moto.first.nom);
      } else if (_lienType == AppConstants.detteLienCategorieEntite) {
        final entite = await _db.obtenirEntiteCategorie(_lienId!);
        if (entite != null && mounted) {
          setState(() => _lienNom = entite.nom);
          setState(() => _categorieChoisieId = entite.categorieId);
          await _choisirCategorieEntite();
        }
      }
    }
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
                      decoration: const InputDecoration(labelText: 'Montant prete'),
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
                            Text(_lienNom ?? '...', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
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
