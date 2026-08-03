import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/moto.dart';
import '../services/database_service.dart';
import '../services/notification_service.dart';

/// Formulaire de création/édition d'une moto. Rien n'est en liste fermée :
/// la fréquence propose 3 modes (hebdomadaire / mensuelle / personnalisée)
/// et chacun a son propre paramètre libre. Il n'y a pas de montant total à
/// rembourser : le versement est récurrent et indéfini tant que la moto
/// est active.
class AddEditMotoScreen extends StatefulWidget {
  final Moto? motoExistante;
  const AddEditMotoScreen({super.key, this.motoExistante});

  @override
  State<AddEditMotoScreen> createState() => _AddEditMotoScreenState();
}

class _AddEditMotoScreenState extends State<AddEditMotoScreen> {
  final _formKey = GlobalKey<FormState>();
  final _db = DatabaseService.instance;

  late final TextEditingController _nomCtrl;
  late final TextEditingController _chauffeurCtrl;
  late final TextEditingController _montantVersementCtrl;
  late final TextEditingController _notesCtrl;

  String _frequenceType = AppConstants.freqHebdomadaire;
  int _jourSemaine = DateTime.monday;
  int _jourMois = 1;
  int _intervalleJours = 7;
  DateTime _dateDebut = DateTime.now();
  String _statut = AppConstants.motoActive;

  bool get _modeEdition => widget.motoExistante != null;
  bool _enregistrement = false;

  @override
  void initState() {
    super.initState();
    final m = widget.motoExistante;
    _nomCtrl = TextEditingController(text: m?.nom ?? '');
    _chauffeurCtrl = TextEditingController(text: m?.chauffeur ?? '');
    _montantVersementCtrl = TextEditingController(text: m?.montantVersement.toStringAsFixed(0) ?? '');
    _notesCtrl = TextEditingController(text: m?.notes ?? '');

    if (m != null) {
      _frequenceType = m.frequenceType;
      _dateDebut = m.dateDebut;
      _statut = m.statut;
      switch (m.frequenceType) {
        case AppConstants.freqHebdomadaire:
          _jourSemaine = m.frequenceValeur;
          break;
        case AppConstants.freqMensuelle:
          _jourMois = m.frequenceValeur;
          break;
        case AppConstants.freqPersonnalisee:
          _intervalleJours = m.frequenceValeur;
          break;
      }
    }
  }

  int get _frequenceValeur {
    switch (_frequenceType) {
      case AppConstants.freqHebdomadaire:
        return _jourSemaine;
      case AppConstants.freqMensuelle:
        return _jourMois;
      case AppConstants.freqPersonnalisee:
        return _intervalleJours;
      default:
        return 1;
    }
  }

  Future<void> _enregistrer() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _enregistrement = true);

    try {
      final montantVersement = double.parse(_montantVersementCtrl.text.replaceAll(' ', ''));

      final moto = Moto(
        id: widget.motoExistante?.id,
        nom: _nomCtrl.text.trim(),
        chauffeur: _chauffeurCtrl.text.trim(),
        montantVersement: montantVersement,
        frequenceType: _frequenceType,
        frequenceValeur: _frequenceValeur,
        dateDebut: _dateDebut,
        statut: _statut,
        dateCreation: widget.motoExistante?.dateCreation,
        notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
      );

      if (!_modeEdition) {
        final id = await _db.insererMoto(moto);
        final motoAvecId = moto.copyWith(id: id);
        await _db.assurerEcheances(motoAvecId);
        await _planifierNotifications(motoAvecId);
      } else {
        final ancien = widget.motoExistante!;
        final changementPlan = ancien.montantVersement != montantVersement ||
            ancien.frequenceType != _frequenceType ||
            ancien.frequenceValeur != _frequenceValeur ||
            ancien.dateDebut != _dateDebut;

        await _db.modifierMoto(moto);

        if (changementPlan && mounted) {
          final confirme = await _confirmerRegeneration();
          if (confirme == true) {
            await _regenererEcheancesNonPayees(moto);
          }
        }
        await _planifierNotifications(moto);
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

  Future<bool?> _confirmerRegeneration() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mettre a jour les echeances ?'),
        content: const Text(
            'Le montant ou la frequence a change. Les versements deja payes '
            'sont conserves. Voulez-vous regenerer les echeances a venir selon '
            'les nouveaux parametres ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Non, garder telles quelles')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Oui, regenerer')),
        ],
      ),
    );
  }

  Future<void> _regenererEcheancesNonPayees(Moto moto) async {
    if (moto.id == null) return;
    final tousLesVersements = await _db.listerVersementsParMoto(moto.id!);
    final nonPayes = tousLesVersements.where((v) => v.statut != AppConstants.versementPaye).toList();

    for (final v in nonPayes) {
      if (v.id != null) {
        await NotificationService.annulerRappel(v.id!);
      }
    }
    final db = await _db.database;
    await db.delete('versements',
        where: 'moto_id = ? AND statut != ?', whereArgs: [moto.id, AppConstants.versementPaye]);

    await _db.assurerEcheances(moto);
  }

  Future<void> _planifierNotifications(Moto moto) async {
    if (moto.id == null) return;
    final params = await _db.obtenirParametres();
    final versements = await _db.listerVersementsParMoto(moto.id!);
    for (final v in versements.where((v) => v.statut != AppConstants.versementPaye)) {
      await NotificationService.planifierRappel(
        versement: v,
        moto: moto,
        delaiHeures: params.delaiNotificationHeures,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_modeEdition ? 'Modifier la moto' : 'Nouvelle moto')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: _nomCtrl,
                decoration: const InputDecoration(labelText: 'Nom de la moto'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Champ requis' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _chauffeurCtrl,
                decoration: const InputDecoration(labelText: 'Chauffeur'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Champ requis' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _montantVersementCtrl,
                decoration: const InputDecoration(labelText: 'Montant par versement'),
                keyboardType: TextInputType.number,
                validator: (v) => (double.tryParse(v ?? '') == null) ? 'Montant invalide' : null,
              ),
              const SizedBox(height: 20),
              const Text('Frequence de versement', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 8),
              _selecteurFrequenceType(),
              const SizedBox(height: 12),
              _parametreFrequence(),
              const SizedBox(height: 20),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Date de debut', style: TextStyle(fontSize: 13)),
                subtitle: Text('${_dateDebut.day}/${_dateDebut.month}/${_dateDebut.year}'),
                trailing: const Icon(Icons.calendar_today_outlined, size: 18),
                onTap: () async {
                  final choisie = await showDatePicker(
                    context: context,
                    initialDate: _dateDebut,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                  );
                  if (choisie != null) setState(() => _dateDebut = choisie);
                },
              ),
              const Divider(),
              const SizedBox(height: 8),
              TextFormField(
                controller: _notesCtrl,
                decoration: const InputDecoration(labelText: 'Notes (optionnel)'),
                maxLines: 2,
              ),
              if (_modeEdition) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _statut,
                  decoration: const InputDecoration(labelText: 'Statut'),
                  items: const [
                    DropdownMenuItem(value: AppConstants.motoActive, child: Text('Actif')),
                    DropdownMenuItem(value: AppConstants.motoSuspendue, child: Text('Suspendu')),
                    DropdownMenuItem(value: AppConstants.motoArchivee, child: Text('Archive')),
                  ],
                  onChanged: (v) => setState(() => _statut = v!),
                ),
              ],
              const SizedBox(height: 28),
              ElevatedButton(
                onPressed: _enregistrement ? null : _enregistrer,
                child: Text(_enregistrement ? 'Enregistrement...' : 'Enregistrer'),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _selecteurFrequenceType() {
    Widget puce(String label, String valeur) {
      final actif = _frequenceType == valeur;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _frequenceType = valeur),
          child: Container(
            margin: const EdgeInsets.only(right: 6),
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
        ),
      );
    }

    return Row(
      children: [
        puce('Hebdomadaire', AppConstants.freqHebdomadaire),
        puce('Mensuelle', AppConstants.freqMensuelle),
        puce('Personnalisee', AppConstants.freqPersonnalisee),
      ],
    );
  }

  Widget _parametreFrequence() {
    switch (_frequenceType) {
      case AppConstants.freqHebdomadaire:
        return DropdownButtonFormField<int>(
          initialValue: _jourSemaine,
          decoration: const InputDecoration(labelText: 'Jour de la semaine'),
          items: List.generate(
            7,
            (i) => DropdownMenuItem(value: i + 1, child: Text(AppConstants.joursSemaine[i])),
          ),
          onChanged: (v) => setState(() => _jourSemaine = v!),
        );
      case AppConstants.freqMensuelle:
        return DropdownButtonFormField<int>(
          initialValue: _jourMois,
          decoration: const InputDecoration(labelText: 'Jour du mois'),
          items: List.generate(31, (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}'))),
          onChanged: (v) => setState(() => _jourMois = v!),
        );
      case AppConstants.freqPersonnalisee:
      default:
        return TextFormField(
          initialValue: _intervalleJours.toString(),
          decoration: const InputDecoration(labelText: 'Intervalle en jours (ex: tous les 10 jours)'),
          keyboardType: TextInputType.number,
          onChanged: (v) => _intervalleJours = int.tryParse(v) ?? _intervalleJours,
        );
    }
  }
}
