import 'package:flutter/material.dart';
import '../services/perf_settings.dart';

// ── PerformanceSettingsScreen ────────────────────────────────────────────────
//
// Settings > Performance: memory profile (playback buffer sizing) and the
// optional "real seeds" tracker scrape. Everything lives in PerfSettings.

const Color _accent = Color(0xFFFFCC00);

class PerformanceSettingsScreen extends StatefulWidget {
  const PerformanceSettingsScreen({super.key});

  @override
  State<PerformanceSettingsScreen> createState() =>
      _PerformanceSettingsScreenState();
}

class _PerformanceSettingsScreenState extends State<PerformanceSettingsScreen> {
  late MemoryProfile _profile = PerfSettings.profile;
  late double _customMb = PerfSettings.customBufferMb.toDouble();
  late bool _realSeeds = PerfSettings.realSeeds;

  static const _labels = {
    MemoryProfile.auto: 'Auto',
    MemoryProfile.low: 'Low',
    MemoryProfile.balanced: 'Balanced',
    MemoryProfile.high: 'High',
    MemoryProfile.custom: 'Custom',
  };

  @override
  Widget build(BuildContext context) {
    final bufMb = PerfSettings.bufferMbFor(_profile);
    final backMb = PerfSettings.backBufferMbFor(bufMb);
    final maxMb = PerfSettings.maxCustomMb;

    return Scaffold(
      backgroundColor: const Color(0xFF050508),
      appBar: AppBar(
        backgroundColor: const Color(0xFF050508),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Performance',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          _card(
            child: Row(
              children: [
                const Icon(Icons.memory_rounded, color: _accent, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'This device: ${PerfSettings.totalRamGb.toStringAsFixed(1)} GB RAM'
                    ' · ${PerfSettings.cpuCores} CPU cores',
                    style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _Title('MEMORY'),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Playback memory profile',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in MemoryProfile.values)
                      ChoiceChip(
                        label: Text(_labels[p]!),
                        selected: _profile == p,
                        selectedColor: _accent,
                        backgroundColor: Colors.white10,
                        labelStyle: TextStyle(
                          color: _profile == p ? Colors.black : Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                        side: BorderSide.none,
                        onSelected: (_) async {
                          await PerfSettings.setProfile(p);
                          setState(() => _profile = p);
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Read-ahead buffer: $bufMb MB  ·  back-buffer: $backMb MB'
                  '${_profile == MemoryProfile.auto ? "  (chosen for this device)" : ""}',
                  style: const TextStyle(
                      color: _accent, fontSize: 12, fontWeight: FontWeight.w700),
                ),
                if (_profile == MemoryProfile.custom) ...[
                  Slider(
                    value: _customMb.clamp(16, maxMb.toDouble()).toDouble(),
                    min: 16,
                    max: maxMb.toDouble(),
                    divisions: ((maxMb - 16) ~/ 8).clamp(1, 100).toInt(),
                    label: '${_customMb.round()} MB',
                    activeColor: _accent,
                    onChanged: (v) => setState(() => _customMb = v),
                    onChangeEnd: (v) =>
                        PerfSettings.setCustomBufferMb(v.round()),
                  ),
                  Text(
                    'Up to $maxMb MB on this device. Bigger rides out slow '
                    'patches better but uses more RAM; too big on a low-RAM '
                    'phone can get the app killed in the background.',
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 11, height: 1.4),
                  ),
                ],
                const SizedBox(height: 10),
                const Text(
                  'Android cannot cap an app\'s total RAM - this sizes the '
                  'video buffers, which are the part the app controls. '
                  'Applies from the next playback.',
                  style:
                      TextStyle(color: Colors.white38, fontSize: 11, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const _Title('SOURCES'),
          _card(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              activeColor: _accent,
              title: const Text('Real seed counts',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
              subtitle: const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Asks UDP trackers how many seeders each source really has '
                  'instead of trusting the number Torrentio prints, and uses '
                  'it for the list and the "Best" sort (marked "live"). Takes '
                  '1-2 s after the list opens. Trackers see your IP and the '
                  'hashes you check, like any torrent client. Sources that '
                  'only live on DHT can show 0.',
                  style:
                      TextStyle(color: Colors.white38, fontSize: 11, height: 1.4),
                ),
              ),
              value: _realSeeds,
              onChanged: (v) async {
                await PerfSettings.setRealSeeds(v);
                setState(() => _realSeeds = v);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: child,
      );
}

class _Title extends StatelessWidget {
  final String text;
  const _Title(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(
          text,
          style: const TextStyle(
            color: _accent,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
          ),
        ),
      );
}
