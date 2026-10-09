import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../models/categorie_activite.dart';
import '../../models/categorie_entite.dart';
import '../../models/categorie_gerant.dart';
import '../../models/categorie_transaction.dart';
import '../../models/dette.dart';
import '../../services/database_service.dart';
import '../../utils/couleur_utils.dart';
import '../../utils/formatters.dart';
import '../../widgets/note_vocale.dart';
import '../dette/add_edit_dette_screen.dart';
import '../dette/dette_detail_screen.dart';
import 'add_categorie_transaction_screen.dart';
import 'add_edit_categorie_entite_screen.dart';

/// Detail d'une entite generique (ex: une boutique precise) : son solde
/// (total general), le compte de chaque personne (proprietaire et gerants),
/// l'historique de ses revenus/depenses, et les dettes qui lui sont
/// rattachees. Equivalent generique de MotoDetailScreen.
class CategorieEntiteDetailScreen extends StatefulWidget {
  final int entiteId;
  final CategorieActivite categorie;

  const CategorieEntiteDetailScreen({super.key, required this.entiteId, required this.categorie});

  @override
  State<CategorieEntiteDetailScreen> createState() => _CategorieEntiteDetailScreenState();
}

class _CategorieEntiteDetailScreenState extends State<CategorieEntiteDetailScreen> {
  final _db = DatabaseService.instance;
  CategorieEntite? _entite;
  List<CategorieTransaction> _transactions = [];
  List<Dette> _dettes = [];
  final Map<int, double> _soldeParDette = {};
  double _solde = 0;
  List<CategorieGerant> _gerants = [];
  Map<int?, double> _soldesPersonnes = {};
  Set<int> _avecAudio = {};

  /// Personne dont on affiche l'historique (gerantId null = proprietaire) ;
  /// null = tout l'historique.
  ({int? gerantId})? _filtre;
  bool _chargement = true;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    setState(() => _chargement = true);
    final entite = await _db.obtenirEntiteCategorie(widget.entiteId);
    if (entite == null) {
      // Entite supprimee entre-temps (ex: lien depuis une dette vers une
      // entite qui n'existe plus) : referme l'ecran au lieu de rester
      // bloque en chargement infini.
      if (mounted) Navigator.pop(context);
      return;
    }
    final transactions = await _db.listerTransactionsEntite(widget.entiteId);
    final solde = await _db.soldeEntiteCategorie(widget.entiteId);
    final gerants = await _db.listerGerants(widget.entiteId);
    final soldesPersonnes = await _db.soldesParPersonne(widget.entiteId);
    final avecAudio = await _db.transactionsAvecAudio(widget.entiteId);
    final dettes = await _db.listerDettesParLien(AppConstants.detteLienCategorieEntite, widget.entiteId);
    _soldeParDette.clear();
    for (final d in dettes) {
      if (d.id != null) _soldeParDette[d.id!] = await _db.soldeDette(d.id!);
    }

    if (!mounted) return;
    setState(() {
      _entite = entite;
      _transactions = transactions;
      _solde = solde;
      _gerants = gerants;
      _soldesPersonnes = soldesPersonnes;
      _avecAudio = avecAudio;
      // Filtre sur un gerant supprime entre-temps : on revient a tout.
      if (_filtre?.gerantId != null && !gerants.any((g) => g.id == _filtre!.gerantId)) _filtre = null;
      _dettes = dettes;
      _chargement = false;
    });
  }

  /// Demande confirmation puis supprime. Appele par confirmDismiss : en cas
  /// d'annulation, la ligne glissee revient a sa place.
  Future<bool> _supprimerTransaction(CategorieTransaction t) async {
    if (t.id == null) return false;
    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer cette operation ?'),
        content: const Text('Cette action est irreversible.'),
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
    if (confirme != true) return false;
    await _db.supprimerTransactionCategorie(t.id!);
    _charger();
    return true;
  }

  String _nomPersonne(int? gerantId) =>
      _gerants.where((g) => g.id == gerantId).firstOrNull?.nom ?? AppConstants.libelleProprietaire;

  Future<void> _ecouter(CategorieTransaction t) async {
    try {
      final audio = await _db.obtenirAudioTransaction(t.id!);
      if (audio != null) await jouerNoteVocale(audio);
    } catch (e) {
      _afficherErreur(e);
    }
  }

  void _afficherErreur(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
  }

  Future<String?> _demanderNom(String titre, {String initial = ''}) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(titre),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Nom'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
          ElevatedButton(onPressed: () => Navigator.pop(context, ctrl.text), child: const Text('Valider')),
        ],
      ),
    );
  }

  /// Enregistre une modification des gerants puis recharge ; un refus (nom
  /// deja pris, gerant qui a des operations...) est affiche.
  Future<void> _modifierGerants(Future<void> Function() modification) async {
    try {
      await modification();
      _charger();
    } catch (e) {
      _afficherErreur(e);
    }
  }

  Future<void> _ajouterGerant() async {
    final nom = await _demanderNom('Nouveau gerant');
    if (nom == null) return;
    await _modifierGerants(() => _db.insererGerant(CategorieGerant(entiteId: widget.entiteId, nom: nom)));
  }

  Future<void> _renommerGerant(CategorieGerant g) async {
    final nom = await _demanderNom('Renommer le gerant', initial: g.nom);
    if (nom == null) return;
    await _modifierGerants(() => _db.modifierGerant(g.copyWith(nom: nom)));
  }

  Future<void> _supprimerEntite() async {
    if (_entite?.id == null) return;
    final confirme = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Supprimer cette entite ?'),
        content: Text(
          '"${_entite!.nom}" et tout son historique seront definitivement supprimes. '
          'Cette action est irreversible.'
          '${_dettes.isEmpty ? '' : '\n\n${_dettes.length} dette(s) liee(s) seront conservee(s), detachee(s) de cette entite.'}',
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
    if (confirme != true) return;
    await _db.supprimerEntiteCategorie(_entite!.id!);
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_chargement || _entite == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final entite = _entite!;
    final couleur = couleurDepuisHex(widget.categorie.couleur);
    final devise = widget.categorie.deviseSymbole;

    return Scaffold(
      appBar: AppBar(
        title: Text(entite.nom),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AddEditCategorieEntiteScreen(categorie: widget.categorie, entiteExistante: entite),
                ),
              );
              _charger();
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: _supprimerEntite,
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
                  Text(_gerants.isEmpty ? 'Solde' : 'Total general',
                      style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
                  const SizedBox(height: 4),
                  Text(formaterMontant(_solde, devise),
                      style: TextStyle(
                          color: _solde < 0 ? const Color(0xFFE2554A) : Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: couleur, foregroundColor: Colors.white),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Ajouter un revenu / une depense'),
                      onPressed: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => AddCategorieTransactionScreen(
                              categorie: widget.categorie,
                              entite: entite,
                              gerants: _gerants.where((g) => g.statut == AppConstants.motoActive).toList(),
                              gerantInitial: _filtre?.gerantId,
                            ),
                          ),
                        );
                        _charger();
                      },
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Comptes', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                TextButton.icon(
                  onPressed: _ajouterGerant,
                  icon: const Icon(Icons.person_add_alt, size: 16),
                  label: const Text('Ajouter un gerant'),
                ),
              ],
            ),
            if (_gerants.isNotEmpty) ...[
              _ligneCompte(null, devise),
              ..._gerants.map((g) => _ligneCompte(g, devise)),
            ],
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
                          lienTypeInitial: AppConstants.detteLienCategorieEntite,
                          lienIdInitial: widget.entiteId,
                          lienNomInitial: entite.nom,
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
              ..._dettes.map((d) => _ligneDette(d, devise)),
            const SizedBox(height: 20),
            Text(_filtre == null ? 'Historique' : 'Historique - ${_nomPersonne(_filtre!.gerantId)}',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (_transactionsAffichees.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text('Aucune operation pour le moment.',
                      style: TextStyle(color: AppColors.texteGris, fontSize: 12)),
                ),
              )
            else
              ..._transactionsAffichees.map((t) => _ligneTransaction(t, devise)),
          ],
        ),
      ),
    );
  }

  List<CategorieTransaction> get _transactionsAffichees => _filtre == null
      ? _transactions
      : _transactions.where((t) => t.gerantId == _filtre!.gerantId).toList();

  /// Compte d'une personne ([g] null = proprietaire). Toucher la ligne filtre
  /// l'historique sur elle (toucher a nouveau l'enleve).
  Widget _ligneCompte(CategorieGerant? g, String devise) {
    final solde = _soldesPersonnes[g?.id] ?? 0;
    final archive = g?.statut == AppConstants.motoArchivee;
    final selectionne = _filtre != null && _filtre!.gerantId == g?.id;
    return InkWell(
      onTap: () => setState(() => _filtre = selectionne ? null : (gerantId: g?.id)),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.only(left: 12, top: 6, bottom: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: selectionne ? couleurDepuisHex(widget.categorie.couleur) : AppColors.bordure,
              width: selectionne ? 1.5 : 0.6),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                g == null ? AppConstants.libelleProprietaire : '${g.nom}${archive ? ' (archive)' : ''}',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w500, color: archive ? AppColors.texteGris : null),
              ),
            ),
            Text(
              formaterMontant(solde, devise),
              style: TextStyle(
                color: solde < 0 ? AppColors.danger : null,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
            if (g == null)
              const SizedBox(width: 48, height: 36)
            else
              PopupMenuButton<VoidCallback>(
                onSelected: (action) => action(),
                itemBuilder: (_) => [
                  PopupMenuItem(value: () => _renommerGerant(g), child: const Text('Renommer')),
                  PopupMenuItem(
                    value: () => _modifierGerants(() => _db.modifierGerant(
                        g.copyWith(statut: archive ? AppConstants.motoActive : AppConstants.motoArchivee))),
                    child: Text(archive ? 'Reactiver' : 'Archiver'),
                  ),
                  PopupMenuItem(
                    value: () => _modifierGerants(() => _db.supprimerGerant(g.id!)),
                    child: const Text('Supprimer'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _ligneDette(Dette d, String devise) {
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
              formaterMontant(solde, devise),
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

  Widget _ligneTransaction(CategorieTransaction t, String devise) {
    final estRevenu = t.type == AppConstants.transactionRevenu;
    return Dismissible(
      key: ValueKey(t.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        decoration: BoxDecoration(color: AppColors.dangerFond, borderRadius: BorderRadius.circular(10)),
        child: const Icon(Icons.delete_outline, color: AppColors.danger),
      ),
      confirmDismiss: (_) => _supprimerTransaction(t),
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
                  Text(
                      _gerants.isEmpty ? formaterDate(t.date) : '${formaterDate(t.date)} - ${_nomPersonne(t.gerantId)}',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                  if (t.description != null && t.description!.isNotEmpty)
                    Text(t.description!, style: TextStyle(color: AppColors.texteGris, fontSize: 10)),
                ],
              ),
            ),
            if (_avecAudio.contains(t.id))
              IconButton(
                tooltip: 'Ecouter la note vocale',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.play_circle_outline, size: 22),
                onPressed: () => _ecouter(t),
              ),
            Text(
              '${estRevenu ? '+' : '-'}${formaterMontant(t.montant, devise)}',
              style: TextStyle(
                color: estRevenu ? AppColors.succes : AppColors.danger,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
