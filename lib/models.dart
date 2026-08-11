part of 'main.dart';

// ============================ CONSTANTS / ENDPOINTS ============================
// Реальные ссылки/бэкенд
const kBot = 'https://t.me/bitaps_vpn_auth_bot';
const kSupport = 'https://t.me/bitapssupport';
// Боевой туннель ВКЛ: движок — xray (десктоп: процесс рядом с приложением + системный прокси;
// Android: внутри системного VpnService плагина flutter_v2ray_client; см. engine.dart). Там, где
// движка нет, TunnelEngine.kind() == none и connect() честно бросает TunnelUnavailable — фейкового
// «Подключено» не рисуем; демо-сессия существует только по явному тумблеру в Настройках.
const bool kRealTunnel = true;

// Настоящий ли туннель поднят ПРЯМО СЕЙЧАС. kRealTunnel — лишь разрешение пытаться; фактически
// движок есть не на каждой платформе (на десктопе рядом лежит xray, на мобильных нужна нативная
// сторона). Интерфейс красит «защищено» зелёным только по этому флагу, чтобы демо-сессия никогда
// не выглядела как реальная защита.
bool gEngineReal = false;
// Сборка для Google Play (CI: --dart-define=STORE_BUILD=true → bitaps-play.aab).
// Anti-steering: в store-сборке НЕ показываем внешние способы оплаты (бот/сайт) — только Play Billing.
const bool kStoreBuild = bool.fromEnvironment('STORE_BUILD');
// Базовый URL edge-функций (functions/v1) — вынесен, чтобы не повторять один и тот же префикс
// в каждом эндпоинте. Значения эндпоинтов идентичны прежним полным литералам.
const kFnBase = 'https://bjkozsukvifkxriojxrz.supabase.co/functions/v1/';
const kNotify = '${kFnBase}notify';
const kApiKey = 'sb_publishable_X2CJWgjqeZtbNelAri9ofw_trbfWF9Z';
const kDemoKey = 'vless://3a7c9f1e-0b2d-4e6f-9a1c-7b3e2f8d4c5a@vpn.bitaps.app:443?security=reality&type=tcp&sni=www.microsoft.com&fp=chrome&pbk=DEMObitapsPLACEHOLDERkey00000000000000000000000&sid=88#bitaps%20VPN';
const kAppLogin = '${kFnBase}app-login';
const kAppSub = '${kFnBase}app-sub';
const kAppPair = '${kFnBase}app-pair';
const kRotateSecret = '${kFnBase}rotate-secret';

// Авто-проверка обновлений: CI вшивает номер сборки через --dart-define и кладёт build_number.txt в релиз.
// Локальная/дев-сборка → 0 (проверку не делаем, чтобы не звать «обновись» в дебаге).
const int kBuildNumber = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);
// Номер последней сборки и сами файлы отдаём со СВОЕГО сервера: сторонний хостинг для
// пользователя из РФ — лишние редиректы и риск блокировки, а нам не нужен посредник.
const kBuildNumberUrl = 'https://origin.bit-core.online/dl/build_number.txt';
// Публичная статистика доступности нод (спарклайны на «Серверы»): generated_at + per-node
// ok/rtt_now/series. Публичный эндпоинт — без токена и hwid, ничего личного не уходит.
const kNodeStatsUrl = 'https://origin.bit-core.online/public/stats';
const kDownloadUrl = 'https://bitapsvpn.com/app.html';

// «Что нового»: changelog.json на сайте (репо bitaps-web). Формат: {"entries":[{"build":N,
// "date":"YYYY-MM-DD","ru":["…"],"en":["…"]}]}. Фетч fail-soft: сбой → экран показывает
// последнюю закэшированную версию или дружелюбную заглушку.
const kChangelogUrl = 'https://bitapsvpn.com/changelog.json';

// Кастомная URL-схема приложения (deep-link): bitaps://import?key=… и bitaps://login?secret=…
// Нативная регистрация схемы — CI-патчами платформ (см. build.yml) / .desktop+reg при первом
// запуске; приём — через app_links в ShellState._initDeepLinks().
const kUrlScheme = 'bitaps';

// Дефолтный глобальный хоткей подключения (десктоп): Cmd+Shift+B (macOS) / Ctrl+Shift+B (иначе).
// Хранится в prefs как строка вида "meta+shift+keyB"; рекордер в Настройках переопределяет.
const kDefaultHotkey = 'mod+shift+keyB';

// ── Тарифы (КАНОН, зеркало _shared/plans.ts бэкенда) ──
// Сетевого источника цен у приложения нет (edge-функции прайс не отдают), поэтому конструктор
// пейвола использует константы канона: 399/999/1790/2990 ₽, +50 ₽/мес за доп-устройство,
// максимум 10 устройств. Менять ТОЛЬКО синхронно с ~/bitaps-vpn/supabase/functions/_shared/plans.ts.
class PlanDef {
  final String code, title; // code = код тарифа бэкенда (mo/q/h/yr), title — по _planNames
  final int months, base;   // months — срок, base — цена за 1 устройство, ₽
  const PlanDef(this.code, this.title, this.months, this.base);
}

const List<PlanDef> kPlanDefs = [
  PlanDef('mo', '1 месяц', 1, 399),
  PlanDef('q', '3 месяца', 3, 999),
  PlanDef('h', '6 месяцев', 6, 1790),
  PlanDef('yr', '12 месяцев', 12, 2990),
];
// Доп-устройство за рубли принимают ОБА чекаута: web-pay (device_limit) и бот
// (subscribe_<plan>_<dev>, выбор 1..10, каждое дополнительное +50 ₽/мес к тому же счёту).
// Менять ТОЛЬКО синхронно с каноном (_shared/plans.ts).
const int kExtraPerMonthRub = 50; // доп-устройство = +50 ₽ за каждый месяц срока (канон)
const int kMaxDevices = 10;       // максимум устройств («не обсуждается»)
const kPayUrl = 'https://bitapsvpn.com/pay.html'; // веб-оплата (аккаунты с отрицательным tgId)

// Персонализация: акцентные темы (имя, основной, мягкий) + стили кнопки.
// 6-я «Phosphor» (CRT-зелёный) — СЕКРЕТНАЯ: свотч скрыт в Настройках, пока не разблокирована
// пасхалкой (7 тапов по мини-лого шапки). Индекс палитры = kPhosphorAccent.
const List<(String, Color, Color)> accentThemes = [
  ('Sunset', Color(0xFFFF7A1A), Color(0xFFFFB347)),
  ('Neon', Color(0xFF2DE2FF), Color(0xFF6AA8FF)),
  ('Emerald', Color(0xFF19D98A), Color(0xFF6FF0BD)),
  ('Lavender', Color(0xFFA779FF), Color(0xFFD0B3FF)),
  ('Crimson', Color(0xFFFF4D6D), Color(0xFFFF9BAD)),
  ('Phosphor', Color(0xFF33FF66), Color(0xFF8BFFA8)), // секретная — люминофор ЭЛТ
];
// Индекс секретной палитры «Phosphor» в accentThemes (последний элемент). Свотч показывается
// в Настройках только после разблокировки (флаг phosphorUnlocked, персист в prefs).
const int kPhosphorAccent = 5;
const btnStyleNames = ['Шестерёнка', 'Кольцо', 'Орб', 'Пульс'];
// Порог разового предупреждения о большом расходе за сессию (тумблер «Лимит трафика»)
const double kTrafficWarnMB = 5120; // 5 ГБ
// Демо: реального трафика нет, а условные скорости мелкие — порог 5 ГБ иначе НЕДОСТИЖИМ и тумблер
// «Лимит трафика» невозможно продемонстрировать. В демо ускоряем накопление, чтобы за пару минут
// демо-сессии счётчик правдоподобно дошёл до порога. Боевой путь (реальные байты движка) — множитель 1.
const double kDemoTrafficBoost = 1200;

// ============================ TOKENS / SECURE STORAGE ============================
// Секреты (vpn_key/appToken/loginSecret/appPin) храним в зашифрованном хранилище ОС
// (Keychain / DPAPI / libsecret), а не в plaintext SharedPreferences. Defensive: если secure storage
// недоступно (напр. нет libsecret на Linux) — падаем на prefs (как раньше), без локаута/потери сессии.
const _secure = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));

// Чтение секрета: secure → если пусто, миграция старого plaintext prefs в secure → иначе prefs-фолбэк.
Future<String?> _secRead(SharedPreferences p, String k) async {
  try {
    final v = await _secure.read(key: k);
    if (v != null && v.isNotEmpty) return v;
    final old = p.getString(k); // было в plaintext (старая версия) → перенести и стереть
    if (old != null && old.isNotEmpty) {
      try { await _secure.write(key: k, value: old); await p.remove(k); } catch (_) {}
      return old;
    }
    return null;
  } catch (_) {
    return p.getString(k); // secure недоступно → как раньше
  }
}

// Запись секрета: в secure + удаляем plaintext-копию из prefs. Сбой secure → пишем в prefs (не теряем сессию).
Future<void> _secWrite(SharedPreferences p, String k, String? v) async {
  // Раздельные try: plaintext-фолбэк выполняется ТОЛЬКО при сбое самой secure-записи, а НЕ при
  // сбое очистки prefs. Иначе (secure записал, а p.remove упал) в catch дописывался plaintext —
  // секрет оказывался И в secure, И в открытых prefs, ровно та утечка, что _secWrite предотвращает.
  bool secureOk = false;
  try {
    if (v != null && v.isNotEmpty) { await _secure.write(key: k, value: v); } else { await _secure.delete(key: k); }
    secureOk = true;
  } catch (_) {
    // secure реально недоступно (напр. нет libsecret) → фолбэк в prefs, чтобы не потерять сессию
    if (v != null && v.isNotEmpty) { await p.setString(k, v); } else { await p.remove(k); }
  }
  // secure-запись прошла → только чистим plaintext-копию; её отсутствие НЕ триггерит дозапись секрета
  if (secureOk) { try { await p.remove(k); } catch (_) {/* не критично: секрет уже в secure */} }
}

// ============================ ИДЕНТИФИКАТОР УСТРОЙСТВА ============================
// Сервис подписки считает устройства по заголовку x-hwid: сколько разных hwid обратилось за
// подпиской, столько устройств занято по тарифу. Значит идентификатор обязан быть СТАБИЛЬНЫМ
// для установки (иначе каждый запуск съедал бы новый слот) и не нести ничего о железе
// пользователя — просто случайное число, живущее в prefs рядом с остальными настройками.
// Формат — hex: сервис принимает только [A-Za-z0-9=-], hex попадает в этот алфавит гарантированно.
String genHwid() {
  final r = math.Random.secure();
  return List<int>.generate(16, (_) => r.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}

// ============================ MODELS / MOCK ============================
class Server {
  final String id, city, country, flag, proto;
  final int ping, load;
  final bool premium, available;
  const Server(this.id, this.city, this.country, this.flag, this.ping, this.load,
      {this.premium = false, this.available = true, this.proto = 'Reality'});

  /// Копия с изменённой доступностью: узел, который не пропускает трафик на этой сети,
  /// выбирать нечего, и это решается уже после разбора подписки.
  Server copyWith({bool? available}) => Server(id, city, country, flag, ping, load,
      premium: premium, available: available ?? this.available, proto: proto);
}

/// «Сервер не выбран». Заглушка на время, пока подписка не загрузилась: выбирать нечего.
///
/// Раньше на этом месте стоял выдуманный список — Москва, Санкт-Петербург, Екатеринбург и
/// четыре зарубежных под замком «PRO». Серверов в России у нас нет вовсе, а «PRO» ничего не
/// значит: подписка одна. Пользователь с оплаченной подпиской видел эту заглушку как реальный
/// список — три недоступных «российских» узла и четыре нажатых-но-не-выбираемых. Показывать
/// можно ТОЛЬКО узлы из подписки; если их нет — честно говорим почему (см. экран «Серверы»).
const kNoServer = Server('', '—', '', '🌐', 0, 0, available: false);

/// Узел подписки → строка списка серверов. Раньше список был захардкожен (Москва/СПб/…),
/// то есть показывал пользователю несуществующие серверы; теперь берём реальные узлы выдачи.
/// Метка вида «🇫🇮 Финляндия» / «🛡️ Нидерланды · БС» — флаг отделяем от названия по первому пробелу.
Server serverFromSubNode(SubNode n, {int ping = 0}) {
  final parts = n.remark.trim().split(' ');
  final flag = parts.isNotEmpty ? parts.first : '🌐';
  var city = parts.length > 1 ? parts.sublist(1).join(' ') : n.remark;
  // Хвост рельсы («· LTE», «· БС», «· CDN») из названия убираем: он и так виден по заголовку
  // группы («устойчивый · CDN»), а склеенный с названием мешал переводу — «Румыния · LTE»
  // в словаре стран не находится, и в английском интерфейсе строка оставалась русской.
  city = city.replaceFirst(RegExp(r'\s*·\s*(LTE|БС|CDN)\s*$', caseSensitive: false), '');
  return Server(
    n.tag, city, '', flag, ping, 0,
    // «LTE» вместо «БС»: так узлы белого списка названы и в подписке, и в кабинете
    proto: n.singboxReady ? 'Reality' : 'LTE · CDN',
  );
}

/// Кто «лучше» из двух узлов — для режима «лучший сервер» и для сортировки списка.
///
/// Наивное сравнение по пингу выбирало ХУДШЕЕ: у незамеренного узла отклик равен нулю, ноль
/// меньше всех — и «лучшим сервером» назначался тот, до которого мы ни разу не дозвонились.
/// На практике это была рельса через CDN, которая по замыслу медленнее прямой, то есть режим
/// систематически подсовывал самый медленный путь. Незамеренные уходят в конец, а при прочих
/// равных выигрывает прямой узел: CDN — обход блокировки, а не первый выбор.
/// [stateOf] — что мы знаем про узел на текущей сети (см. node_probe.dart). Проверенно рабочие
/// всегда впереди непроверенных, а непригодные — всегда позади: «лучшим» не может быть сервер,
/// через который заведомо ничего не грузится.
/// [cdnFirst] — режим «ограниченная сеть» (пре-флайт, engine.dart): прямые ноды в этой сети
/// мертвы, поэтому ВСЕ рельсы «LTE · CDN» идут впереди прямых независимо от пинга, а прямые —
/// в конец. Ранг приговора всё равно сильнее: мёртвая рельса не обгонит работающую прямую.
int compareServers(Server a, Server b, int Function(Server) ping,
    {NodeState Function(Server)? stateOf, bool cdnFirst = false}) {
  if (stateOf != null) {
    int rank(Server s) => switch (stateOf(s)) {
          NodeState.works => 0,
          NodeState.unknown => 1,
          NodeState.blocked => 2,
        };
    final ra = rank(a), rb = rank(b);
    if (ra != rb) return ra.compareTo(rb);
  }
  if (cdnFirst) {
    final ca = a.proto.startsWith('LTE') ? 0 : 1, cb = b.proto.startsWith('LTE') ? 0 : 1;
    if (ca != cb) return ca.compareTo(cb);
  }
  final pa = ping(a), pb = ping(b);
  if (pa > 0 && pb > 0 && pa != pb) return pa.compareTo(pb);
  if ((pa > 0) != (pb > 0)) return pa > 0 ? -1 : 1; // замеренный всегда впереди незамеренного
  final ca = a.proto.startsWith('LTE') ? 1 : 0, cb = b.proto.startsWith('LTE') ? 1 : 0;
  return ca.compareTo(cb);
}

class Faq {
  final String q, a;
  const Faq(this.q, this.a);
}

const faqs = [
  // Число устройств — от 1 до 10, выбирается при покупке в том же чекауте (бот или сайт),
  // каждое дополнительное +50 ₽/мес. Не «одно + докупка за токены», как было раньше.
  Faq('Сколько устройств можно подключить?',
      'От 1 до 10 — число выбираешь при покупке (в боте или на сайте). Каждое дополнительное: +50 ₽/мес.'),
  Faq('Вы ведёте логи?', 'Нет. Мы не храним логи активности — только техническую информацию для работы сервиса.'),
  Faq('Как продлить подписку?', 'В «Кабинете» нажми «Продлить» — оплата через Telegram, СБП или крипту.'),
  Faq('VPN не подключается?', 'Смени локацию, проверь интернет и что подписка активна. Не помогло — напиши в поддержку.'),
];

const modeLabels = ['Авто', 'Стрим', 'Игры', 'Прив.'];
