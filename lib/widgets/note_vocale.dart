import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../core/theme.dart';

/// Notes vocales des operations (a la place ou en plus de la description
/// ecrite). L'audio est garde dans la base, donc dans les sauvegardes.
// ponytail: 60 s max en AAC 16 kbit/s mono (~120 Ko par note) car la sauvegarde
// Google est limitee a 25 Mo au total ; passer a des fichiers si ca deborde.
const dureeMaxNoteVocale = Duration(seconds: 60);

/// Cree a la premiere lecture seulement.
AudioPlayer? _lecteur;

/// Joue une note. Le lecteur Android lit un fichier : l'audio est d'abord
/// ecrit dans un fichier temporaire.
Future<void> jouerNoteVocale(Uint8List audio) async {
  final lecteur = _lecteur ??= AudioPlayer();
  await lecteur.stop();
  final fichier = File(p.join((await getTemporaryDirectory()).path, 'note_lecture.m4a'));
  await fichier.writeAsBytes(audio, flush: true);
  await lecteur.play(DeviceFileSource(fichier.path));
}

/// Bouton d'enregistrement : enregistrer, arreter, reecouter, effacer.
/// [onChanged] recoit l'audio une fois l'enregistrement arrete (null si
/// efface) ; [onEnregistrement] signale qu'un enregistrement est en cours,
/// pour ne pas enregistrer l'operation sans sa note.
class EnregistreurNoteVocale extends StatefulWidget {
  final ValueChanged<Uint8List?> onChanged;
  final ValueChanged<bool> onEnregistrement;

  const EnregistreurNoteVocale({super.key, required this.onChanged, required this.onEnregistrement});

  @override
  State<EnregistreurNoteVocale> createState() => _EnregistreurNoteVocaleState();
}

class _EnregistreurNoteVocaleState extends State<EnregistreurNoteVocale> {
  final _micro = AudioRecorder();
  Timer? _minuteur;
  int _secondes = 0;
  bool _enCours = false;
  Uint8List? _audio;

  /// Un demarrage ou un arret est deja en route : un double appui (ou
  /// l'arret automatique a 60 s pendant un appui) ne doit pas le relancer,
  /// sinon deux minuteurs tournent ou la note est ecrasee par un second arret.
  bool _occupe = false;

  Future<void> _sansDoublon(Future<void> Function() action) async {
    if (_occupe) return;
    _occupe = true;
    try {
      await action();
    } finally {
      _occupe = false;
    }
  }

  Future<void> _demarrer() async {
    // _enCours : l'appui peut arriver avant que le bouton ne soit redessine.
    if (_enCours) return;
    if (!await _micro.hasPermission()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Autorisez le micro dans les reglages du telephone pour enregistrer.')),
      );
      return;
    }
    await _lecteur?.stop();
    final chemin = p.join((await getTemporaryDirectory()).path, 'note_enregistrement.m4a');
    try {
      await _micro.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 16000, sampleRate: 16000, numChannels: 1),
        path: chemin,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Impossible d\'enregistrer : $e')));
      return;
    }
    if (!mounted) return; // dispose() a deja libere le micro
    _minuteur = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _secondes++);
      if (_secondes >= dureeMaxNoteVocale.inSeconds) _sansDoublon(_arreter);
    });
    setState(() {
      _enCours = true;
      _secondes = 0;
    });
    widget.onEnregistrement(true);
  }

  Future<void> _arreter() async {
    if (!_enCours) return;
    _minuteur?.cancel();
    final chemin = await _micro.stop();
    Uint8List? audio;
    if (chemin != null) {
      final fichier = File(chemin);
      audio = await fichier.readAsBytes();
      // La note vit desormais dans la base : la voix ne doit pas trainer en
      // cache (elle y resterait meme apres suppression de la note).
      await fichier.delete();
    }
    if (!mounted) return;
    setState(() {
      _enCours = false;
      _audio = (audio == null || audio.isEmpty) ? null : audio;
    });
    widget.onEnregistrement(false);
    widget.onChanged(_audio);
  }

  void _effacer() {
    _lecteur?.stop();
    setState(() => _audio = null);
    widget.onChanged(null);
  }

  @override
  void dispose() {
    _minuteur?.cancel();
    if (_enCours) _micro.cancel();
    _micro.dispose();
    _lecteur?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_enCours) {
      return OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
        onPressed: () => _sansDoublon(_arreter),
        icon: const Icon(Icons.stop_circle_outlined),
        label: Text('Arreter ($_secondes s / ${dureeMaxNoteVocale.inSeconds} s)'),
      );
    }
    if (_audio == null) {
      return OutlinedButton.icon(
        onPressed: () => _sansDoublon(_demarrer),
        icon: const Icon(Icons.mic_none),
        label: const Text('Enregistrer une note vocale'),
      );
    }
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => jouerNoteVocale(_audio!),
            icon: const Icon(Icons.play_arrow),
            label: Text('Ecouter la note ($_secondes s)'),
          ),
        ),
        IconButton(
          tooltip: 'Effacer la note',
          onPressed: _effacer,
          icon: const Icon(Icons.delete_outline, color: AppColors.danger),
        ),
      ],
    );
  }
}
