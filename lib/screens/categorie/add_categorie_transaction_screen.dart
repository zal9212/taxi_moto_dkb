import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../models/categorie_activite.dart';
import '../../models/categorie_champ.dart';
import '../../models/categorie_entite.dart';
import '../../models/categorie_transaction.dart';
import '../../services/database_service.dart';
import '../../utils/couleur_utils.dart';
import '../../widgets/champ_personnalise_field.dart';

/// Ajoute un revenu ou une depense a une entite. Formulaire dynamique :
/// montant, date, description, plus un champ pour chacun des champs
/// personnalises "transaction" definis par la categorie (ex: categorie de
/// depense).
class AddCategorieTransactionScreen extends StatefulWidget {
  final CategorieActivite categorie;
  final CategorieEntite entite;

  const AddCategorieTransactionScreen({
    super.key,
    required this.categorie,
    required this.entite,
  });

  @override
  State<AddCategorieTransactionScreen> createState() => _AddCategorieTransactionScreenState();
}

class _AddCategorieTransactionScreenState extends State<AddCategorieTransactionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _db = DatabaseService.instance;
  final _montantCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  String _type = AppConstants.transactionRevenu;
  DateTime _date = DateTime.now();

  List<CategorieChamp> _champs = [];
  final Map<int, String> _valeurs = {};
  bool _chargement = true;
  bool _enregistrement = false;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    final champs =
        await _db.listerChampsCategorie(widget.categorie.id!, niveau: AppConstants.niveauChampTransaction);
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
      final id = await _db.insererTransactionCategorie(
        CategorieTransaction(
          entiteId: widget.entite.id!,
          type: _type,
          montant: double.parse(_montantCtrl.text.replaceAll(' ', '')),
          date: _date,
          description: _descriptionCtrl.text.trim().isEmpty ? null : _descriptionCtrl.text.trim(),
        ),
      );
      await _db.definirValeursTransaction(id, _valeurs);

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
      appBar: AppBar(title: const Text('Nouvelle operation')),
      body: _chargement
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _puceType('Revenu', AppConstants.transactionRevenu, AppColors.accentLime),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _puceType('Depense', AppConstants.transactionDepense, const Color(0xFFE2554A)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _montantCtrl,
                      decoration: InputDecoration(labelText: 'Montant (${widget.categorie.deviseSymbole})'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      validator: (v) => (double.tryParse((v ?? '').replaceAll(' ', '')) == null)
                          ? 'Montant invalide'
                          : null,
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
                    ..._champs.map((champ) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: ChampPersonnaliseField(
                            champ: champ,
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
                    TextFormField(
                      controller: _descriptionCtrl,
                      decoration: const InputDecoration(labelText: 'Description (optionnel)'),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 24),
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

  Widget _puceType(String label, String valeur, Color couleur) {
    final actif = _type == valeur;
    return GestureDetector(
      onTap: () => setState(() => _type = valeur),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: actif ? couleur : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: actif ? couleur : AppColors.bordure),
        ),
        child: Text(label,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: actif ? texteContrasteSur(couleur) : AppColors.texteGris,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
      ),
    );
  }
}
