import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../models/categorie_activite.dart';
import '../../models/categorie_champ.dart';
import '../../models/categorie_entite.dart';
import '../../services/database_service.dart';
import '../../utils/couleur_utils.dart';
import '../../widgets/champ_personnalise_field.dart';

/// Creation ou modification d'une entite generique (ex: une boutique
/// precise). Formulaire dynamique : en plus du nom, affiche un champ pour
/// chacun des champs personnalises "entite" definis par la categorie.
class AddEditCategorieEntiteScreen extends StatefulWidget {
  final CategorieActivite categorie;
  final CategorieEntite? entiteExistante;

  const AddEditCategorieEntiteScreen({
    super.key,
    required this.categorie,
    this.entiteExistante,
  });

  @override
  State<AddEditCategorieEntiteScreen> createState() => _AddEditCategorieEntiteScreenState();
}

class _AddEditCategorieEntiteScreenState extends State<AddEditCategorieEntiteScreen> {
  final _formKey = GlobalKey<FormState>();
  final _db = DatabaseService.instance;
  late final TextEditingController _nomCtrl;
  String _statut = AppConstants.motoActive;

  List<CategorieChamp> _champs = [];
  final Map<int, String> _valeurs = {};
  bool _chargement = true;
  bool _enregistrement = false;

  bool get _modeEdition => widget.entiteExistante != null;

  @override
  void initState() {
    super.initState();
    _nomCtrl = TextEditingController(text: widget.entiteExistante?.nom ?? '');
    if (widget.entiteExistante != null) _statut = widget.entiteExistante!.statut;
    _charger();
  }

  Future<void> _charger() async {
    final champs = await _db.listerChampsCategorie(widget.categorie.id!, niveau: AppConstants.niveauChampEntite);
    if (widget.entiteExistante?.id != null) {
      final valeurs = await _db.obtenirValeursEntite(widget.entiteExistante!.id!);
      _valeurs.addAll(valeurs);
    }
    if (!mounted) return;
    setState(() {
      _champs = champs;
      _chargement = false;
    });
  }

  Future<void> _enregistrer() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _enregistrement = true);
    try {
      final entite = CategorieEntite(
        id: widget.entiteExistante?.id,
        categorieId: widget.categorie.id!,
        nom: _nomCtrl.text.trim(),
        statut: _statut,
        dateCreation: widget.entiteExistante?.dateCreation,
      );

      int entiteId;
      if (_modeEdition) {
        await _db.modifierEntiteCategorie(entite);
        entiteId = entite.id!;
      } else {
        entiteId = await _db.insererEntiteCategorie(entite);
      }
      await _db.definirValeursEntite(entiteId, _valeurs);

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
    final couleur = couleurDepuisHex(widget.categorie.couleur);
    return Scaffold(
      appBar: AppBar(title: Text(_modeEdition ? 'Modifier' : 'Nouvelle entite')),
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
                      decoration: const InputDecoration(labelText: 'Nom'),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Champ requis' : null,
                    ),
                    const SizedBox(height: 12),
                    ..._champs.map((champ) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: ChampPersonnaliseField(
                            champ: champ,
                            valeurInitiale: champ.id != null ? _valeurs[champ.id!] : null,
                            onChanged: (v) {
                              if (champ.id == null) return;
                              if (v == null) {
                                _valeurs.remove(champ.id!);
                              } else {
                                _valeurs[champ.id!] = v;
                              }
                            },
                          ),
                        )),
                    if (_modeEdition) ...[
                      DropdownButtonFormField<String>(
                        initialValue: _statut,
                        decoration: const InputDecoration(labelText: 'Statut'),
                        items: const [
                          DropdownMenuItem(value: AppConstants.motoActive, child: Text('Actif')),
                          DropdownMenuItem(value: AppConstants.motoSuspendue, child: Text('Suspendu')),
                          DropdownMenuItem(value: AppConstants.motoArchivee, child: Text('Archive')),
                        ],
                        onChanged: (v) => setState(() => _statut = v ?? AppConstants.motoActive),
                      ),
                      const SizedBox(height: 12),
                    ],
                    const SizedBox(height: 12),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: couleur, foregroundColor: Colors.white),
                      onPressed: _enregistrement ? null : _enregistrer,
                      child: Text(_enregistrement ? 'Enregistrement...' : 'Enregistrer'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
