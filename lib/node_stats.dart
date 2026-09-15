part of 'main.dart';

// ============================ ДОСТУПНОСТЬ НОД (публичная статистика) ============================
// GET kNodeStatsUrl → {"generated_at":…,"nodes":[{"name":"🇫🇮 Финляндия","ok":true,
// "rtt_now":40,"series":[[ts,ms],…]}]} — точки ~раз в 5 минут, копятся. Внизу экрана
// «Серверы» рисуем спарклайн доступности за 48 часов по каждой ноде.
// Здесь — модель и ЧИСТАЯ логика (разбор, нормализация series в точки графика, уровень
// цвета по rtt), чтобы она была юнит-тестируема без UI (node_stats_test).

/// Одна нода из публичной статистики.
class NodeStat {
  final String name;      // «🇫🇮 Финляндия» — как в выдаче подписки
  final String id;        // IP ноды (как SubNode.server у прямых узлов) — для сопоставления с флотом
  final bool ok;          // жива ли нода по последнему замеру
  final int? rttNow;      // текущий отклик, мс (null — не измерен)
  /// (unix-секунды, мс); ms null/неположительный — нода в этой точке была мертва (разрыв).
  final List<(int, int?)> series;
  const NodeStat({required this.name, this.id = '', required this.ok, this.rttNow, this.series = const []});
}

/// Весь отчёт: время генерации (для «обновлено N мин назад») + ноды.
class NodeStatsReport {
  final DateTime generatedAt;
  final List<NodeStat> nodes;
  const NodeStatsReport({required this.generatedAt, required this.nodes});
}

/// Разбор тела /public/stats. null — ответ не по форме (UI покажет «данные недоступны»).
NodeStatsReport? parseNodeStats(String body) {
  try {
    final d = jsonDecode(body);
    if (d is! Map) return null;
    final nodesRaw = d['nodes'];
    if (nodesRaw is! List) return null;
    final ts = d['generated_at'];
    final generatedAt = ts is num
        ? DateTime.fromMillisecondsSinceEpoch(ts.toInt() * 1000, isUtc: true)
        : (DateTime.tryParse('$ts') ?? DateTime.now());
    final nodes = <NodeStat>[];
    for (final n in nodesRaw) {
      if (n is! Map) continue;
      final series = <(int, int?)>[];
      final sr = n['series'];
      if (sr is List) {
        for (final p in sr) {
          if (p is! List || p.length < 2) continue;
          final t = p[0];
          if (t is! num) continue;
          final ms = p[1];
          series.add((t.toInt(), ms is num && ms > 0 ? ms.toInt() : null));
        }
      }
      nodes.add(NodeStat(
        name: '${n['name'] ?? ''}',
        id: '${n['id'] ?? ''}',
        ok: n['ok'] == true,
        rttNow: (n['rtt_now'] is num) ? (n['rtt_now'] as num).toInt() : null,
        series: series,
      ));
    }
    return NodeStatsReport(generatedAt: generatedAt, nodes: nodes);
  } catch (_) {
    return null;
  }
}

/// Окно графика — 48 часов, по точке на час.
const int kSparkHours = 48;

/// Нормализация series в [buckets] точек графика по окну [fromSec, toSec] (unix-секунды).
/// Точка бакета — среднее rtt живых замеров бакета; бакет без единого живого замера (все
/// мертвы или точек не было) → null = РАЗРЫВ линии. Чистая функция — покрыта node_stats_test.
List<double?> sparkPoints(List<(int, int?)> series,
    {required int buckets, required int fromSec, required int toSec}) {
  final out = List<double?>.filled(buckets, null);
  if (buckets <= 0 || toSec <= fromSec) return out;
  final sums = List<double>.filled(buckets, 0);
  final counts = List<int>.filled(buckets, 0);
  final span = toSec - fromSec;
  for (final (ts, ms) in series) {
    if (ms == null) continue; // мёртвая точка среднее не сдвигает, но и «живости» не даёт
    var i = ((ts - fromSec) * buckets) ~/ span;
    if (i < 0) i = 0;
    if (i >= buckets) i = buckets - 1; // точку за правым краем клампим в последний бакет
    sums[i] += ms;
    counts[i]++;
  }
  for (var i = 0; i < buckets; i++) {
    if (counts[i] > 0) out[i] = sums[i] / counts[i];
  }
  return out;
}

/// Цвет спарклайна — акцент АКТИВНОЙ темы (это декор, не статус: статус ноды — зелёная/
/// красная точка у имени). На светлой теме неоновый акцент (#FF7A1A и пастели других палитр)
/// выцветает на белых карточках — затемняем тем же правилом, что accentSoftInk (lightness
/// до ≤0.38): тот же источник читаемости, что у остального UI. В тёмной (и «Фосфор») —
/// акцент без изменений. Чистая функция — покрыта node_stats_test.
Color sparkColor(Color accent, {required bool light}) {
  if (!light) return accent;
  final h = HSLColor.fromColor(accent);
  return h.withLightness(math.min(h.lightness, 0.38)).toColor();
}
