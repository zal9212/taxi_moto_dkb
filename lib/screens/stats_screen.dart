import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/moto.dart';
import '../services/database_service.dart';
import '../utils/formatters.dart';

enum _Periode { semaine, mois, annee }

/// Vue d'ensemble des versements reçus, agrégés par semaine / mois / année,
/// pour donner une vision complète de l'activité au fil du temps.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  final _db = DatabaseService.instance;

  _Periode _periode = _Periode.semaine;
  int? _motoFiltreId;
  List<Moto> _motos = [];
  List<MapEntry<DateTime, double>> _donnees = [];
  String _devise = AppConstants.devisePardDefaut;
  bool _chargement = true;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  String get _cleApi {
    switch (_periode) {
      case _Periode.semaine:
        return 'semaine';
      case _Periode.mois:
        return 'mois';
      case _Periode.annee:
        return 'annee';
    }
  }

  int get _nombrePeriodes {
    switch (_periode) {
      case _Periode.semaine:
        return 8;
      case _Periode.mois:
        return 12;
      case _Periode.annee:
        return 5;
    }
  }

  Future<void> _charger() async {
    setState(() => _chargement = true);
    final motos = await _db.listerMotos();
    final params = await _db.obtenirParametres();
    final donnees = await _db.totalEncaisseParPeriode(
      periode: _cleApi,
      motoId: _motoFiltreId,
      nombrePeriodes: _nombrePeriodes,
    );
    if (!mounted) return;
    setState(() {
      _motos = motos;
      _devise = params.deviseSymbole;
      _donnees = donnees;
      _chargement = false;
    });
  }

  String _libelleBucket(DateTime d) {
    switch (_periode) {
      case _Periode.semaine:
        return formaterDateCourte(d);
      case _Periode.mois:
        return '${_moisCourt(d.month)} ${d.year.toString().substring(2)}';
      case _Periode.annee:
        return d.year.toString();
    }
  }

  static const _moisCourts = [
    'Jan', 'Fev', 'Mar', 'Avr', 'Mai', 'Jun', 'Jul', 'Aou', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  String _moisCourt(int mois) => _moisCourts[mois - 1];

  double get _total => _donnees.fold(0, (s, e) => s + e.value);
  double get _maxValeur {
    final max = _donnees.fold<double>(0, (m, e) => e.value > m ? e.value : m);
    return max <= 0 ? 1 : max;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Statistiques')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _charger,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _selecteurPeriode(),
              const SizedBox(height: 12),
              _selecteurMoto(),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: AppColors.carteNoire, borderRadius: BorderRadius.circular(14)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Total verse sur la periode', style: TextStyle(color: AppColors.texteGris, fontSize: 11)),
                    const SizedBox(height: 4),
                    Text(formaterMontant(_total, _devise),
                        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (_chargement)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 60),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                _graphique(),
                const SizedBox(height: 20),
                const Text('Detail par periode', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                ..._donnees.reversed.map((e) => _ligneDetail(e.key, e.value)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _selecteurPeriode() {
    Widget puce(String label, _Periode valeur) {
      final actif = _periode == valeur;
      return Expanded(
        child: GestureDetector(
          onTap: () {
            setState(() => _periode = valeur);
            _charger();
          },
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
                style: TextStyle(color: actif ? Colors.white : AppColors.texteGris, fontSize: 12)),
          ),
        ),
      );
    }

    return Row(
      children: [
        puce('Semaine', _Periode.semaine),
        puce('Mois', _Periode.mois),
        puce('Annee', _Periode.annee),
      ],
    );
  }

  Widget _selecteurMoto() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _puceMoto('Toutes les motos', null),
          ..._motos.map((m) => Padding(
                padding: const EdgeInsets.only(left: 8),
                child: _puceMoto(m.nom, m.id),
              )),
        ],
      ),
    );
  }

  Widget _puceMoto(String label, int? id) {
    final actif = _motoFiltreId == id;
    return InkWell(
      onTap: () {
        setState(() => _motoFiltreId = id);
        _charger();
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: actif ? AppColors.carteNoire : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: actif ? AppColors.carteNoire : AppColors.bordure),
        ),
        child: Text(label, style: TextStyle(color: actif ? Colors.white : AppColors.texteGris, fontSize: 11)),
      ),
    );
  }

  Widget _graphique() {
    if (_donnees.every((e) => e.value == 0)) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 40),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.bordure, width: 0.6),
        ),
        child: Center(
          child: Text('Aucun versement recu sur cette periode',
              style: TextStyle(color: AppColors.texteGris, fontSize: 12)),
        ),
      );
    }

    return Container(
      height: 220,
      padding: const EdgeInsets.fromLTRB(8, 16, 12, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.bordure, width: 0.6),
      ),
      child: BarChart(
        BarChartData(
          maxY: _maxValeur * 1.2,
          alignment: BarChartAlignment.spaceAround,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: _maxValeur / 3,
            getDrawingHorizontalLine: (_) => FlLine(color: AppColors.bordure, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  if (i < 0 || i >= _donnees.length) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(_libelleBucket(_donnees[i].key),
                        style: TextStyle(color: AppColors.texteGris, fontSize: 9)),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => AppColors.carteNoire,
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final entree = _donnees[groupIndex];
                return BarTooltipItem(
                  '${_libelleBucket(entree.key)}\n${formaterMontant(entree.value, _devise)}',
                  const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                );
              },
            ),
          ),
          barGroups: List.generate(_donnees.length, (i) {
            final estDernier = i == _donnees.length - 1;
            return BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: _donnees[i].value,
                  color: estDernier ? AppColors.accentLime : AppColors.carteNoire,
                  width: 16,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }

  Widget _ligneDetail(DateTime cle, double valeur) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.bordure, width: 0.6),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(_libelleBucket(cle), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          Text(formaterMontant(valeur, _devise),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
