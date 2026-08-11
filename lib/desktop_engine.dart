// Движок туннеля для ДЕСКТОПА: запускаем рядом лежащий xray-core на конфиге подписки.
//
// Почему xray, а не sing-box: узлы «белого списка» ходят транспортом xhttp, которого в sing-box
// нет. xray понимает все наши узлы, а записи подписки сами по себе уже его конфиги.
//
// Что здесь есть и чего намеренно нет:
//   • запуск/остановка процесса движка, ожидание готовности локального socks-входа;
//   • системный прокси (Windows/macOS/Linux) — включаем на время сессии и ОБЯЗАТЕЛЬНО снимаем;
//   • честные ошибки: не нашли движок / не поднялся / не встал прокси — говорим прямо.
// TUN-режим (полный перехват трафика всей системы) требует прав администратора и драйвера —
// это отдельный шаг; здесь режим системного прокси, который работает без прав и покрывает
// браузеры и большинство приложений, уважающих системные настройки.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:shared_preferences/shared_preferences.dart';

/// Не нашли или не смогли запустить движок — вызывающий показывает текст пользователю.
class EngineUnavailable implements Exception {
  final String message;
  EngineUnavailable(this.message);
  @override
  String toString() => message;
}

/// Поиск бинаря движка. Порядок: рядом с исполняемым файлом (так его кладёт сборка),
/// затем каталог данных приложения (куда его можно доложить). PATH — ТОЛЬКО в debug:
/// на проде любой чужой xray из PATH подхватился бы и повёл трафик (аудит, LOW).
class XrayBinary {
  static const String _name = 'xray';

  static String? locate({String? extraDir}) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final suffix = Platform.isWindows ? '.exe' : '';
    final candidates = <String>[
      if (extraDir != null) '$extraDir${Platform.pathSeparator}$_name$suffix',
      '$exeDir${Platform.pathSeparator}$_name$suffix',
      '$exeDir${Platform.pathSeparator}bin${Platform.pathSeparator}$_name$suffix',
      // Linux AppImage/tar.gz кладут бинарь рядом с data/
      '$exeDir${Platform.pathSeparator}data${Platform.pathSeparator}$_name$suffix',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    // PATH — запасной путь для разработки (dev-машина, установленный вручную xray);
    // в release ветка мертва (kDebugMode == false) и выкидывается компилятором.
    if (kDebugMode) {
      final path = Platform.environment['PATH'] ?? '';
      for (final dir in path.split(Platform.isWindows ? ';' : ':')) {
        if (dir.isEmpty) continue;
        final c = '$dir${Platform.pathSeparator}$_name$suffix';
        if (File(c).existsSync()) return c;
      }
    }
    return null;
  }
}

/// Процесс движка с конфигом подписки.
class XrayProcess {
  XrayProcess._(this._proc, this.socksPort);

  final Process _proc;
  final int socksPort;
  final List<String> _errLines = [];
  bool _stopped = false;

  /// Последние строки лога движка — идут в текст ошибки, чтобы сбой был диагностируемым.
  String get lastError => _errLines.isEmpty ? '' : _errLines.take(4).join('\n');

  /// Запустить движок на готовом конфиге. Бросает [EngineUnavailable] с внятной причиной.
  /// [onDied] — смерть процесса ВНЕ штатной остановки (краш, kill, OOM): без неё обрыв посреди
  /// сессии на десктопе нигде не отражался — туннель мёртв, а UI тикает «Подключено». Своя
  /// остановка (stop/disconnect/failClosed) колбэка не даёт.
  static Future<XrayProcess> start(
    String configJson, {
    required int socksPort,
    String? binaryPath,
    Duration readyTimeout = const Duration(seconds: 12),
    void Function(XrayProcess proc, int code)? onDied,
  }) async {
    final bin = binaryPath ?? XrayBinary.locate();
    if (bin == null) {
      throw EngineUnavailable('VPN-движок не найден в сборке');
    }
    // Конфиг отдаём движку через stdin (`-c stdin:`), а не файлом: в нём личный UUID подписки,
    // и на диске он не должен оказываться даже во временном каталоге.
    // XRAY_LOCATION_ASSET — каталог с geoip.dat/geosite.dat, они лежат рядом с бинарём;
    // без них правила «российские сайты мимо туннеля» не сработают.
    final engineDir = File(bin).parent.path;
    Process proc;
    try {
      proc = await Process.start(
        bin,
        ['run', '-c', 'stdin:'],
        runInShell: false,
        workingDirectory: engineDir,
        environment: {'XRAY_LOCATION_ASSET': engineDir},
      );
      proc.stdin.write(configJson);
      await proc.stdin.flush();
      await proc.stdin.close();
    } catch (e) {
      throw EngineUnavailable('не удалось запустить движок: $e');
    }
    final p = XrayProcess._(proc, socksPort);
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(p._onLog);
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(p._onLog);
    // Смерть процесса вне stop(): помечаем, пишем в лог и сообщаем подписчику (onDied) —
    // контроллер подключения услышит обрыв и запустит авто-реконнект. Без пометки цикл
    // готовности ниже ждал бы весь таймаут уже умерший движок.
    proc.exitCode.then((code) {
      if (p._stopped) return; // своя остановка — не событие
      p._exited = true;
      p._onLog('xray exited: $code');
      onDied?.call(p, code);
    });
    // Готовность = локальный socks реально принимает соединения. Пока порт не слушает,
    // включать системный прокси нельзя — иначе весь трафик уедет в закрытый порт.
    final deadline = DateTime.now().add(readyTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await p._socksReady()) return p;
      if (p._exited) {
        throw EngineUnavailable('движок завершился на старте:\n${p.lastError}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await p.stop();
    throw EngineUnavailable('движок не поднял локальный порт за ${readyTimeout.inSeconds} с');
  }

  bool _exited = false;

  void _onLog(String line) {
    if (line.trim().isEmpty) return;
    _errLines.insert(0, line.trim());
    if (_errLines.length > 20) _errLines.removeLast();
  }

  Future<bool> _socksReady() async {
    try {
      final s = await Socket.connect('127.0.0.1', socksPort,
          timeout: const Duration(milliseconds: 400));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Остановить движок и убрать временный конфиг. Идемпотентно.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _proc.kill(ProcessSignal.sigterm);
    // не ждём вечно: если движок завис, добиваем
    await _proc.exitCode.timeout(const Duration(seconds: 4), onTimeout: () {
      _proc.kill(ProcessSignal.sigkill);
      return -1;
    });
    _cleanup();
  }

  void _cleanup() {
    _exited = true; // конфиг жил только в stdin — удалять нечего
  }
}

/// Показания движка: счётчики трафика и задержки узлов. Движок отдаёт их сам по HTTP на
/// localhost (metrics.listen → /debug/vars), поэтому опрос дешёвый — без запуска процессов.
/// Считаем только узлы туннеля (node-*): прямой трафик мимо туннеля к «скорости VPN»
/// отношения не имеет.
class XrayStats {
  static Future<({int up, int down, Map<String, int?> pings})?> read(int metricsPort) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.getUrl(Uri.parse('http://127.0.0.1:$metricsPort/debug/vars'));
      final resp = await req.close().timeout(const Duration(seconds: 3));
      final body = await resp.transform(utf8.decoder).join();
      return parse(body);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Разбор ответа /debug/vars. Формат observatory в xray-core: per-outbound {alive, delay},
  /// у мёртвого узла alive отсутствует (proto3 опускает значение по умолчанию), а задержка
  /// приходит заглушкой 99999999 — показывать её как пинг нельзя. Чистая функция — покрыта
  /// fleet_probe_test.
  static ({int up, int down, Map<String, int?> pings})? parse(String body) {
    try {
      final decoded = json.decode(body);
      if (decoded is! Map) return null;
      var up = 0, down = 0;
      final outbound = (decoded['stats'] as Map?)?['outbound'];
      if (outbound is Map) {
        outbound.forEach((tag, v) {
          if (tag is! String || !tag.startsWith('node-') || v is! Map) return;
          up += (v['uplink'] as num?)?.toInt() ?? 0;
          down += (v['downlink'] as num?)?.toInt() ?? 0;
        });
      }
      final pings = <String, int?>{};
      final obs = decoded['observatory'];
      if (obs is Map) {
        obs.forEach((tag, v) {
          if (tag is! String || v is! Map) return;
          final delay = (v['delay'] as num?)?.toInt();
          pings[tag] = (v['alive'] == true && delay != null && delay < 99999999) ? delay : null;
        });
      }
      return (up: up, down: down, pings: pings);
    } catch (_) {
      return null;
    }
  }
}

/// Исход стартовой уборки за прошлой сессией (см. SystemProxy.cleanupStale).
enum StaleCleanup {
  /// В системе нет нашего прокси — убирать нечего.
  nothing,

  /// Прокси наш, но порт движка слушает: туннель принадлежит другой ЖИВОЙ копии —
  /// не трогаем (снять = fail-open).
  keptAlive,

  /// Протухший прокси снят, осиротевший движок добит.
  cleaned,
}

/// Системный прокси на время сессии. Включаем ТОЛЬКО после готовности движка и снимаем всегда,
/// в том числе при падении: иначе пользователь останется без интернета с указателем в мёртвый порт.
class SystemProxy {
  static bool _enabled = false;
  static List<String> _macServices = [];

  // Снимок настроек прокси ДО нашего включения (у части пользователей свой прокси уже стоял):
  // disable() вернёт его, а не безусловное «выкл». null/пусто — снимка нет (свежий процесс,
  // напр. уборка за упавшей сессией) → прежнее поведение: просто снять.
  static Map<String, String>? _winSaved; // ProxyEnable (0/1) + ProxyServer
  static Map<String, String>? _linuxSaved; // mode + http host/port
  static final Map<String, Map<String, List<String>>> _macSaved = {}; // сервис → тип → строки вывода -get*proxy

  static bool get enabled => _enabled;

  /// Обертка: после успешного включения персистим НАШИ порты — по ним looksOurs отличает
  /// наш прокси от чужого localhost-прокси (Happ на 127.0.0.1:10808 и т.п., багхант MED).
  static Future<bool> enable({required int socksPort, required int httpPort}) async {
    final ok = await _enableInner(socksPort: socksPort, httpPort: httpPort);
    if (ok) await _saveOwnPorts(socksPort, httpPort);
    return ok;
  }

  static Future<bool> _enableInner({required int socksPort, required int httpPort}) async {
    try {
      // Снимок чужих настроек — ТОЛЬКО если текущий системный прокси НЕ наш. Иначе (реконнект
      // из блокировки килл-свитча, повторное включение поверх своего) снимок с реальными
      // настройками пользователя затирался нашим же мёртвым 127.0.0.1:<порт>, и disable() →
      // _restore() вписывал мёртвый порт обратно как «настройки пользователя» — «нет интернета»
      // после отключения (багхант, CRIT).
      if (snapshotNeeded(await looksOurs())) await _snapshot(); // до любой записи: вернуть как было
      if (Platform.isMacOS) {
        _macServices = await _macNetworkServices();
        if (_macServices.isEmpty) return false;
        final cmds = <List<String>>[
          for (final s in _macServices) ...[
            ['-setsocksfirewallproxy', s, '127.0.0.1', '$socksPort'],
            ['-setsocksfirewallproxystate', s, 'on'],
            ['-setwebproxy', s, '127.0.0.1', '$httpPort'],
            ['-setwebproxystate', s, 'on'],
            ['-setsecurewebproxy', s, '127.0.0.1', '$httpPort'],
            ['-setsecurewebproxystate', s, 'on'],
          ],
        ];
        await _macRun(cmds);
        _enabled = await _macApplied(socksPort);
        return _enabled;
      }
      if (Platform.isWindows) {
        // WinINet: прокси пользователя (без прав администратора). http/https обязательны —
        // многие приложения socks-строку игнорируют.
        const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
        final value = 'http=127.0.0.1:$httpPort;https=127.0.0.1:$httpPort;socks=127.0.0.1:$socksPort';
        await Process.run('reg', ['add', key, '/v', 'ProxyServer', '/t', 'REG_SZ', '/d', value, '/f']);
        // Обход прокси для локальных адресов (localhost/интранет идут напрямую, аудит п.5).
        // Чужие записи обхода не теряем: сливаем со снятыми в снимок — _restore вернёт как было.
        final ovr = winProxyOverride(_winSaved?['override'] ?? '');
        await Process.run('reg', ['add', key, '/v', 'ProxyOverride', '/t', 'REG_SZ', '/d', ovr, '/f']);
        await Process.run('reg', ['add', key, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '1', '/f']);
        _enabled = await _winApplied(httpPort);
        _winNotifyProxyChanged(); // иначе WinINet-клиенты держат старые настройки до перезапуска
        return _enabled;
      }
      if (Platform.isLinux) {
        // gsettings читают только GTK-окружения. На KDE/LXQt и прочих запись «проходит», но
        // настройку никто не применяет (см. _linuxApplied — она читает те же ключи, что пишет,
        // и потому там врёт). Честно говорим «не поддержано» вместо ложного «защищено».
        final de = (Platform.environment['XDG_CURRENT_DESKTOP'] ?? '').toUpperCase();
        const gtk = ['GNOME', 'UNITY', 'PANTHEON', 'CINNAMON', 'BUDGIE', 'MATE', 'XFCE'];
        // Пустое/незнакомое DE — тоже «не поддержано»: readback своих же ключей gsettings
        // ничего не доказывает о реальном применении, а fail-open с зелёным статусом хуже
        // честной ошибки (TunnelUnavailable покажет текст пользователю).
        if (de.isEmpty || !gtk.any(de.contains)) {
          stderr.writeln('system proxy: окружение «${de.isEmpty ? 'неизвестно' : de}» не читает gsettings — режим прокси не поддержан');
          return false;
        }
        await Process.run('gsettings', ['set', 'org.gnome.system.proxy', 'mode', 'manual']);
        for (final e in {'http': httpPort, 'https': httpPort, 'socks': socksPort}.entries) {
          await Process.run('gsettings', ['set', 'org.gnome.system.proxy.${e.key}', 'host', '127.0.0.1']);
          await Process.run('gsettings', ['set', 'org.gnome.system.proxy.${e.key}', 'port', '${e.value}']);
        }
        // На KDE и прочих не-GNOME средах команды проходят, но настройку никто не читает —
        // объявлять «защищено» в этом случае нельзя, поэтому проверяем чтением.
        _enabled = await _linuxApplied(socksPort);
        return _enabled;
      }
    } catch (_) {/* ниже вернём false — вызывающий честно скажет, что прокси не встал */}
    return false;
  }

  /// Снять системный прокси. Намеренно НЕ смотрим на флаг в памяти: после падения приложения
  /// (или его убийства) флаг сброшен, а прокси в системе остался — это ровно тот случай, когда
  /// уборка нужнее всего. Чужие настройки не трогаем: снимаем, только если прокси указывает на
  /// локальный адрес, то есть это наш.
  static Future<void> disable() async {
    _enabled = false;
    _clearOwnPorts(); // прокси снят — записи о «наших» портах больше нет
    try {
      // Есть снимок: возвращаем чужие настройки ТОЛЬКО если текущие всё ещё наши (localhost).
      // Прокси сменился под нами — человек настроил свой сам: его выбор не трогаем вовсе.
      if (_winSaved != null || _linuxSaved != null || _macSaved.isNotEmpty) {
        if (await looksOurs()) await _restore();
        _winSaved = null;
        _linuxSaved = null;
        _macSaved.clear();
        _macServices = [];
        return;
      }
      if (Platform.isMacOS) {
        // Уборка — ВСЕГДА по полному списку сервисов: looksOurs() сужает _macServices до
        // первого совпадения, и снятие только с него оставляло бы протухший прокси на втором
        // сервисе (Ethernet vs Wi-Fi) — «нет интернета» при рабочем кабеле (аудит, HIGH).
        final services = macCleanupServices(await _macNetworkServices(), _macServices);
        await _macRun([
          for (final s in services) ...[
            ['-setsocksfirewallproxystate', s, 'off'],
            ['-setwebproxystate', s, 'off'],
            ['-setsecurewebproxystate', s, 'off'],
          ],
        ]);
        _macServices = [];
        return;
      }
      if (Platform.isWindows) {
        const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
        await Process.run('reg', ['add', key, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0', '/f']);
        _winNotifyProxyChanged();
        return;
      }
      if (Platform.isLinux) {
        await Process.run('gsettings', ['set', 'org.gnome.system.proxy', 'mode', 'none']);
        return;
      }
    } catch (_) {/* при выключении ошибки глотаем: главное — не мешать выходу */}
  }

  // ── снимок/восстановление чужих настроек (до нашего включения и после) ──
  static Future<void> _snapshot() async {
    try {
      if (Platform.isWindows) {
        const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
        final en = await Process.run('reg', ['query', key, '/v', 'ProxyEnable']);
        final srv = await Process.run('reg', ['query', key, '/v', 'ProxyServer']);
        final ovr = await Process.run('reg', ['query', key, '/v', 'ProxyOverride']);
        _winSaved = {
          'enable': (en.stdout ?? '').toString().contains('0x1') ? '1' : '0',
          'server': RegExp(r'ProxyServer\s+REG_SZ\s+(\S.*)')
                  .firstMatch((srv.stdout ?? '').toString())?.group(1)?.trim() ?? '',
          // ProxyOverride может отсутствовать вовсе — тогда снимок пуст, и _restore удалит наш.
          'override': RegExp(r'ProxyOverride\s+REG_SZ\s+(\S.*)')
                  .firstMatch((ovr.stdout ?? '').toString())?.group(1)?.trim() ?? '',
        };
        return;
      }
      if (Platform.isMacOS) {
        final services = _macServices.isNotEmpty ? _macServices : await _macNetworkServices();
        _macSaved.clear();
        for (final svc in services) {
          final m = <String, List<String>>{};
          for (final t in ['-getwebproxy', '-getsecurewebproxy', '-getsocksfirewallproxy']) {
            final r = await Process.run('/usr/sbin/networksetup', [t, svc]);
            m[t] = (r.stdout ?? '').toString().split('\n');
          }
          _macSaved[svc] = m;
        }
        return;
      }
      if (Platform.isLinux) {
        Future<String> get(String key, String field) async =>
            (await Process.run('gsettings', ['get', key, field]))
                .stdout?.toString().trim().replaceAll("'", '') ?? '';
        final mode = await get('org.gnome.system.proxy', 'mode');
        _linuxSaved = {
          'mode': mode.isEmpty ? 'none' : mode,
          'httpHost': await get('org.gnome.system.proxy.http', 'host'),
          'httpPort': await get('org.gnome.system.proxy.http', 'port'),
        };
        return;
      }
    } catch (_) {/* снимок не снялся — disable() отработает по-старому (просто снять) */}
  }

  static Future<void> _restore() async {
    try {
      if (Platform.isWindows && _winSaved != null) {
        const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
        final srv = _winSaved!['server'] ?? '';
        if (srv.isNotEmpty) {
          await Process.run('reg', ['add', key, '/v', 'ProxyServer', '/t', 'REG_SZ', '/d', srv, '/f']);
        }
        // Обход прокси — как было до нас: был свой — возвращаем; не было — удаляем наш '<local>'.
        final ovr = _winSaved!['override'] ?? '';
        if (ovr.isNotEmpty) {
          await Process.run('reg', ['add', key, '/v', 'ProxyOverride', '/t', 'REG_SZ', '/d', ovr, '/f']);
        } else {
          await Process.run('reg', ['delete', key, '/v', 'ProxyOverride', '/f']);
        }
        await Process.run('reg', ['add', key, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', _winSaved!['enable'] ?? '0', '/f']);
        _winNotifyProxyChanged();
        return;
      }
      if (Platform.isMacOS) {
        final cmds = <List<String>>[];
        for (final e in _macSaved.entries) {
          for (final t in ['-getwebproxy', '-getsecurewebproxy', '-getsocksfirewallproxy']) {
            final lines = e.value[t] ?? const <String>[];
            String f(String k) => lines
                .firstWhere((l) => l.startsWith('$k:'), orElse: () => '')
                .split(':').last.trim();
            final host = f('Server'), port = f('Port'), on = f('Enabled') == 'Yes';
            final set = t.replaceFirst('-get', '-set'); // -getwebproxy → -setwebproxy
            if (host.isNotEmpty) cmds.add([set, e.key, host, port]);
            cmds.add(['${set}state', e.key, on ? 'on' : 'off']);
          }
        }
        if (cmds.isNotEmpty) await _macRun(cmds);
        _macServices = [];
        return;
      }
      if (Platform.isLinux && _linuxSaved != null) {
        await Process.run('gsettings', ['set', 'org.gnome.system.proxy.http', 'host', _linuxSaved!['httpHost'] ?? '']);
        await Process.run('gsettings', ['set', 'org.gnome.system.proxy.http', 'port', _linuxSaved!['httpPort'] ?? '0']);
        await Process.run('gsettings', ['set', 'org.gnome.system.proxy', 'mode', _linuxSaved!['mode'] ?? 'none']);
        return;
      }
    } catch (_) {/* восстановление best-effort: хуже, чем надо, не сделаем */}
  }

  /// Выполнить пачку команд networksetup. Сначала пробуем как есть: если приложение уже
  /// запущено с нужными правами, лишний запрос пароля не нужен. Не получилось — повторяем
  /// ОДНИМ вызовом с правами администратора, чтобы система спросила пароль один раз на всю
  /// операцию, а не на каждую команду. (Смена сетевых настроек в macOS требует root.)
  /// Бросает [EngineUnavailable] при ненулевом exitCode osascript: отмена пароля («User
  /// canceled», -128) раньше проглатывалась — команды не выполнялись, а вызывающий считал
  /// прокси применённым/снятым. Вызывающие сами решают по факту: enable() вернёт false,
  /// disable()/_restore() проглотят, но unblock() перепроверит looksOurs().
  static Future<void> _macRun(List<List<String>> cmds) async {
    var allOk = true;
    for (final args in cmds) {
      final r = await Process.run('/usr/sbin/networksetup', args);
      if (r.exitCode != 0) { allOk = false; break; }
    }
    if (allOk) return;
    final script = cmds.map((a) => '/usr/sbin/networksetup ${a.map(_shellQuote).join(' ')}').join(' ; ');
    // экранирование для строки AppleScript: обратный слэш и кавычки
    final applescript = script.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    final r = await Process.run('osascript', [
      '-e',
      'do shell script "$applescript" with administrator privileges',
    ]);
    if (r.exitCode != 0) {
      final err = (r.stderr ?? '').toString().trim();
      throw EngineUnavailable(
          'macOS не дала сменить системный прокси (код ${r.exitCode})${err.isEmpty ? '' : ': $err'}');
    }
  }

  static String _shellQuote(String a) => "'${a.replaceAll("'", r"'\''")}'";

  // ── подтверждение по факту ──
  // Команды настройки прокси возвращают успех и там, где их результат никто не читает
  // (KDE вместо GNOME, macOS без прав администратора). Поэтому после записи перечитываем.
  static Future<bool> _macApplied(int socksPort) async {
    if (_macServices.isEmpty) return false;
    // Частичное применение — НЕ успех: сервис без нашего прокси ходит напрямую, а «нашлось на
    // одном сервисе» раньше читалось зелёным. Зелёный — только «наш порт на ВСЕХ активных
    // сервисах» (primary из -listnetworkserviceorder входит в этот список по построению).
    for (final svc in _macServices) {
      final r = await Process.run('/usr/sbin/networksetup', ['-getsocksfirewallproxy', svc]);
      final out = (r.stdout ?? '').toString();
      // Порт — строгим совпадением поля, а не подстрокой: «4000» находилось бы и в «14000»
      // (аудит, MED) → ложный «прокси применён» при чужом прокси на другом порту.
      final port = RegExp(r'Port:\s*(\d+)').firstMatch(out)?.group(1) ?? '';
      if (!(out.contains('Enabled: Yes') && port == '$socksPort')) return false;
    }
    return true;
  }

  static Future<bool> _winApplied(int httpPort) async {
    const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
    final r = await Process.run('reg', ['query', key, '/v', 'ProxyServer']);
    return (r.stdout ?? '').toString().contains('127.0.0.1:$httpPort');
  }

  static Future<bool> _linuxApplied(int socksPort) async {
    final mode = await Process.run('gsettings', ['get', 'org.gnome.system.proxy', 'mode']);
    if (!(mode.stdout ?? '').toString().contains('manual')) return false;
    final port = await Process.run('gsettings', ['get', 'org.gnome.system.proxy.socks', 'port']);
    return (port.stdout ?? '').toString().trim() == '$socksPort';
  }

  /// Остался ли в системе НАШ прокси (указывает на localhost) — вызывается на старте
  /// приложения, чтобы прибрать за прошлым упавшим запуском.
  ///
  /// «localhost = наш» бьёт по другим VPN-клиентам (Happ держит 127.0.0.1:10808): наш
  /// _stopDesktop → disable() без снимка молча гасил бы чужой работающий прокси (багхант,
  /// MED). Поэтому свои реальные порты персистятся при enable (kOwnPortsPrefsKey), и «нашим»
  /// считается только совпадение по ним; нет записи (сессия старой версии) — прежнее
  /// поведение как fallback.
  static Future<bool> looksOurs() async {
    try {
      final own = await _loadOwnPorts();
      if (Platform.isWindows) {
        const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
        final en = await Process.run('reg', ['query', key, '/v', 'ProxyEnable']);
        if (!(en.stdout ?? '').toString().contains('0x1')) return false;
        final srv = await Process.run('reg', ['query', key, '/v', 'ProxyServer']);
        final server = (srv.stdout ?? '').toString();
        if (!server.contains('127.0.0.1')) return false;
        return ownPortsMatch(own, winProxyServerPorts(server));
      }
      if (Platform.isMacOS) {
        for (final svc in await _macNetworkServices()) {
          final r = await Process.run('/usr/sbin/networksetup', ['-getsocksfirewallproxy', svc]);
          final out = (r.stdout ?? '').toString();
          if (out.contains('Enabled: Yes') && out.contains('127.0.0.1')) {
            final port =
                int.tryParse(RegExp(r'Port:\s*(\d+)').firstMatch(out)?.group(1) ?? '') ?? 0;
            if (!ownPortsMatch(own, {port})) continue; // чужой localhost-прокси — не трогаем
            _macServices = [svc];
            return true;
          }
        }
        return false;
      }
      if (Platform.isLinux) {
        final mode = await Process.run('gsettings', ['get', 'org.gnome.system.proxy', 'mode']);
        if (!(mode.stdout ?? '').toString().contains('manual')) return false;
        final host = await Process.run('gsettings', ['get', 'org.gnome.system.proxy.socks', 'host']);
        if (!(host.stdout ?? '').toString().contains('127.0.0.1')) return false;
        final pr = await Process.run('gsettings', ['get', 'org.gnome.system.proxy.socks', 'port']);
        final port = int.tryParse((pr.stdout ?? '').toString().trim()) ?? 0;
        return ownPortsMatch(own, {port});
      }
    } catch (_) {/* не смогли прочитать — считаем, что чужого не трогаем */}
    return false;
  }

  // ── «наши» порты: персист при enable, сверка в looksOurs ──

  /// Ключ prefs с портами нашего последнего включения (строка 'socks,http').
  static const String kOwnPortsPrefsKey = 'proxyOwnPorts';
  static Set<int>? _ownPorts; // лениво грузится из prefs в looksOurs

  /// Разбор persisted-строки портов. null — записи нет или она битая (не доверяем).
  /// Чистая функция — покрыта proxy_guard_test.
  static Set<int>? parseOwnPorts(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final out = <int>{};
    for (final part in raw.split(',')) {
      final v = int.tryParse(part.trim());
      if (v == null || v <= 0 || v > 65535) return null;
      out.add(v);
    }
    return out.isEmpty ? null : out;
  }

  /// «Текущий прокси — наш?» по портам. Нет persisted-записи (сессия старой версии) —
  /// прежнее поведение (localhost = наш), иначе требуем пересечения портов.
  /// Чистая функция — покрыта proxy_guard_test.
  static bool ownPortsMatch(Set<int>? own, Set<int> current) =>
      own == null || own.isEmpty || current.any(own.contains);

  /// Делать ли снимок системных настроек перед включением: только когда текущий прокси НЕ
  /// наш — иначе снимок с реальными настройками пользователя затирался бы нашим же мёртвым
  /// прокси (багхант, CRIT). Чистая функция — покрыта proxy_guard_test.
  static bool snapshotNeeded(bool currentProxyIsOurs) => !currentProxyIsOurs;

  static Future<void> _saveOwnPorts(int socksPort, int httpPort) async {
    _ownPorts = {socksPort, httpPort};
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(kOwnPortsPrefsKey, '$socksPort,$httpPort');
    } catch (_) {/* без персиста — откат на прежнее поведение */}
  }

  static Future<Set<int>?> _loadOwnPorts() async {
    if (_ownPorts != null) return _ownPorts;
    Set<int>? parsed;
    try {
      final p = await SharedPreferences.getInstance();
      parsed = parseOwnPorts(p.getString(kOwnPortsPrefsKey));
    } catch (_) {
      parsed = null;
    }
    _ownPorts = parsed;
    return parsed;
  }

  static void _clearOwnPorts() {
    _ownPorts = null;
    SharedPreferences.getInstance()
        .then((p) => p.remove(kOwnPortsPrefsKey))
        .catchError((_) => false); // best-effort: запись не критична
  }

  /// Прибраться на старте приложения за прошлой сессией (аудит п.1/п.3/п.4).
  ///
  /// Решение по liveness, а не по одному «прокси наш»: прокси указывает на localhost, но
  /// ПОРТ ДВИЖКА СЛУШАЕТ — значит, туннель принадлежит другой ЖИВОЙ копии приложения, и
  /// снимать прокси = убить ей трафик (fail-open). Порт молчит — это протухший прокси от
  /// упавшей/перезагруженной сессии: снимаем его (иначе у человека «нет интернета») и
  /// добиваем осиротевший xray нашей установки (родитель умер, процесс остался).
  /// [instanceLockHeld] — мы УЖЕ держим блокировку одной копии (instance_lock.dart): живой
  /// другой копии тогда быть не может (вторая вышла бы до уборки), и слушающий порт — это
  /// осиротевший движок прошлой сессии: чистим и добиваем, а не keptAlive.
  static Future<StaleCleanup> cleanupStale({bool instanceLockHeld = false}) async {
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return StaleCleanup.nothing;
    final ours = await looksOurs();
    var alive = false;
    if (ours) {
      for (final port in await _ourProxyPorts()) {
        if (await _socksAlive(port)) { alive = true; break; }
      }
    }
    switch (decideStaleCleanup(proxyIsOurs: ours, engineAlive: alive, instanceLockHeld: instanceLockHeld)) {
      case StaleCleanup.nothing:
        return StaleCleanup.nothing;
      case StaleCleanup.keptAlive:
        return StaleCleanup.keptAlive; // вызывающий сообщает наверх: «другая копия жива»
      case StaleCleanup.cleaned:
        await disable();
        await _killOrphanedEngine();
        return StaleCleanup.cleaned;
    }
  }

  /// Решение уборки по факту liveness. Чистая функция — покрыта stale_cleanup_test.
  /// [instanceLockHeld]: блокировка одной копии у нас → «живой порт» это сирота, а не другая
  /// копия — чистим; без блокировки (порт блокировки занят чужим процессом) — прежний
  /// консерватизм keptAlive.
  static StaleCleanup decideStaleCleanup({required bool proxyIsOurs, required bool engineAlive, bool instanceLockHeld = false}) {
    if (!proxyIsOurs) return StaleCleanup.nothing; // чужой прокси не трогаем в любом случае
    return (engineAlive && !instanceLockHeld) ? StaleCleanup.keptAlive : StaleCleanup.cleaned;
  }

  /// Сервисы macOS, с которых снимаем прокси при уборке: полный список системы, а суженный
  /// looksOurs — только если системный список не прочитался (не остаться без уборки вовсе).
  /// Чистая функция — покрыта proxy_guard_test.
  static List<String> macCleanupServices(List<String> allServices, List<String> narrowed) =>
      allServices.isNotEmpty ? allServices : narrowed;

  /// Порты 127.0.0.1 из строки ProxyServer вида «http=127.0.0.1:40000;…;socks=127.0.0.1:40002».
  /// Чистая функция — покрыта stale_cleanup_test.
  static Set<int> winProxyServerPorts(String server) {
    final ports = <int>{};
    for (final m in RegExp(r'127\.0\.0\.1:(\d{1,5})').allMatches(server)) {
      final p = int.tryParse(m.group(1)!) ?? 0;
      if (p > 0 && p <= 65535) ports.add(p);
    }
    return ports;
  }

  /// Значение ProxyOverride при нашем включении: '<local>' (localhost/интранет мимо прокси)
  /// + записи, которые уже были у пользователя (без дублей). Чистая функция — покрыта тестом.
  static String winProxyOverride(String existing) {
    final parts = <String>[];
    for (final e in existing.split(';')) {
      final t = e.trim();
      if (t.isNotEmpty && t.toLowerCase() != '<local>') parts.add(t);
    }
    parts.add('<local>');
    return parts.join(';');
  }

  /// PID'ы xray.exe ИЗ НАШЕЙ ПАПКИ УСТАНОВКИ по выводу
  /// `Get-CimInstance Win32_Process … | ConvertTo-Csv` (строки вида «"1234","C:\…\xray.exe"»).
  /// Совпадение — полный путь к нашему бинарю, регистронезависимо: чужой xray (Happ и т.п.)
  /// добивать нельзя. Чистая функция — покрыта stale_cleanup_test.
  static List<int> parseOwnEnginePids(String csv, String installDir) {
    final dir = installDir.replaceAll('/', '\\').replaceAll(RegExp(r'\\+$'), '').toLowerCase();
    final want = '$dir\\xray.exe';
    final pids = <int>[];
    for (final raw in const LineSplitter().convert(csv)) {
      final m = RegExp(r'^"?(\d+)"?,\s*"?(.*?)"?\s*$').firstMatch(raw.trim());
      if (m == null) continue;
      final pid = int.tryParse(m.group(1)!);
      final path = m.group(2)!.replaceAll('/', '\\').toLowerCase();
      if (pid != null && path == want) pids.add(pid);
    }
    return pids;
  }

  /// Локальные порты движка из ТЕКУЩИХ системных настроек (вызывается после looksOurs()).
  static Future<Set<int>> _ourProxyPorts() async {
    try {
      if (Platform.isWindows) {
        const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
        final srv = await Process.run('reg', ['query', key, '/v', 'ProxyServer']);
        return winProxyServerPorts((srv.stdout ?? '').toString());
      }
      if (Platform.isMacOS) {
        final ports = <int>{};
        for (final svc in _macServices) {
          final r = await Process.run('/usr/sbin/networksetup', ['-getsocksfirewallproxy', svc]);
          final p = int.tryParse(RegExp(r'Port:\s*(\d+)')
                  .firstMatch((r.stdout ?? '').toString())?.group(1) ?? '') ?? 0;
          if (p > 0) ports.add(p);
        }
        return ports;
      }
      if (Platform.isLinux) {
        final r = await Process.run('gsettings', ['get', 'org.gnome.system.proxy.socks', 'port']);
        final p = int.tryParse((r.stdout ?? '').toString().trim()) ?? 0;
        return p > 0 ? {p} : {};
      }
    } catch (_) {/* не прочитали — считаем портов нет (прежнее поведение: снять прокси) */}
    return {};
  }

  /// Слушает ли на порту НАШ движок. Голый TCP-connect не подходит: на порту протухшего
  /// прокси мог сидеть ЧУЖОЙ сервис, и он читался бы как «живой туннель другой копии»
  /// (keptAlive → протухший прокси не снимается, у человека нет интернета, UI молчит —
  /// багхант, MED). Критерий — SOCKS5-рукопожатие нашего noauth-входа xray: шлём greeting
  /// 05 01 00 и ждём выбор метода 05 00. Чужой не-SOCKS сервис молчит/ругается → false.
  static Future<bool> _socksAlive(int port) async {
    Socket? s;
    try {
      s = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(milliseconds: 300));
      s.add(const [0x05, 0x01, 0x00]);
      await s.flush();
      final reply = await s.first.timeout(const Duration(milliseconds: 500));
      return reply.length >= 2 && reply[0] == 0x05 && reply[1] == 0x00;
    } catch (_) {
      return false;
    } finally {
      s?.destroy();
    }
  }

  /// Снять системный прокси, ТОЛЬКО если он сейчас указывает на один из [ports] (наша
  /// попытка подключения). Откат позднего connect (engine.dart) зовёт это после смены
  /// поколения: прокси новой попытки/чужого клиента трогать нельзя.
  static Future<void> disableIfPorts(Set<int> ports) async {
    try {
      final cur = await _ourProxyPorts();
      if (cur.any(ports.contains)) await disable();
    } catch (_) {/* best-effort откат — старт/отмену не блокируем */}
  }

  /// Добить осиротевший xray НАШЕЙ установки: родитель умер (краш/диспетчер задач/сон),
  /// процесс остался — держит порты и грузит CPU. Только полный путь нашего бинаря
  /// (parseOwnEnginePids на Windows, parseOwnEnginePidsPosix на macOS): чужой xray
  /// (Happ и т.п.) добивать нельзя. Linux оставляем ОС (PPID-deathwatch), там посторонние
  /// процессы из приложения не трогаем.
  static Future<void> _killOrphanedEngine() async {
    try {
      if (Platform.isWindows) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        // wmic в новых Windows 11 может отсутствовать, поэтому PowerShell + CIM.
        final r = await Process.run('powershell.exe', [
          '-NoProfile', '-WindowStyle', 'Hidden', '-Command',
          "Get-CimInstance Win32_Process -Filter \"Name='xray.exe'\" "
          '| Select-Object ProcessId,ExecutablePath | ConvertTo-Csv -NoTypeInformation',
        ]);
        for (final pid in parseOwnEnginePids((r.stdout ?? '').toString(), exeDir)) {
          await Process.run('taskkill', ['/PID', '$pid', '/F']);
        }
        return;
      }
      if (Platform.isMacOS) {
        // deathwatch по PPID на macOS наш процесс не добивает: launchd усыновляет сироту, и
        // она живёт с занятыми портами (аудит, HIGH). Ищем по полному пути нашего бинаря.
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final r = await Process.run('pgrep', ['-fl', 'xray']);
        for (final pid in parseOwnEnginePidsPosix((r.stdout ?? '').toString(), exeDir)) {
          await Process.run('kill', ['-9', '$pid']);
        }
        return;
      }
    } catch (_) {/* уборка best-effort: не получилось — старт не блокируем */}
  }

  /// PID'ы xray ИЗ НАШЕЙ ПАПКИ по выводу `pgrep -fl xray` (macOS): строки «PID cmd…».
  /// Совпадение — полный путь к нашему бинарю (<exeDir>/xray): чужой xray, запущенный
  /// из другого места, добивать нельзя. Путь бандла может содержать пробелы («bitaps
  /// VPN.app»), поэтому не режем по пробелу: совпадение = точный путь ИЛИ путь + аргументы.
  /// Чистая функция — покрыта proxy_guard_test.
  static List<int> parseOwnEnginePidsPosix(String out, String exeDir) {
    final dir = exeDir.replaceAll(RegExp(r'/+$'), '');
    final want = '$dir/xray';
    final pids = <int>[];
    for (final raw in const LineSplitter().convert(out)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final sp = line.indexOf(' ');
      if (sp == -1) continue;
      final pid = int.tryParse(line.substring(0, sp));
      if (pid == null) continue;
      final cmd = line.substring(sp + 1).trim();
      if (cmd == want || cmd.startsWith('$want ')) pids.add(pid);
    }
    return pids;
  }

  /// Уведомить систему о смене прокси (аудит п.5): reg.exe НЕ рассылает broadcast, поэтому
  /// WinINet-клиенты (браузеры, большинство софта) держали бы СТАРЫЕ настройки до своего
  /// перезапуска — прокси «включался/выключался» для них с опозданием. Шлём сами через
  /// wininet InternetSetOption: SETTINGS_CHANGED (39) + REFRESH (37). dart:ffi, Windows only.
  static void _winNotifyProxyChanged() {
    if (!Platform.isWindows) return;
    try {
      final wininet = ffi.DynamicLibrary.open('wininet.dll');
      final setOption = wininet.lookupFunction<
          ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Pointer<ffi.Void>, ffi.Uint32),
          int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Void>, int)>(
          'InternetSetOptionA');
      final nullHandle = ffi.Pointer<ffi.Void>.fromAddress(0);
      setOption(nullHandle, 39, nullHandle, 0); // INTERNET_OPTION_SETTINGS_CHANGED
      setOption(nullHandle, 37, nullHandle, 0); // INTERNET_OPTION_REFRESH
    } catch (_) {/* нет wininet (теоретически) — поведение как раньше, старт не блокируем */}
  }

  /// Сетевые сервисы macOS (Wi-Fi, Ethernet…), кроме отключённых (строки со «*»).
  static Future<List<String>> _macNetworkServices() async {
    final r = await Process.run('/usr/sbin/networksetup', ['-listallnetworkservices']);
    final out = (r.stdout ?? '').toString().split('\n');
    return [
      for (var line in out.skip(1))
        if (line.trim().isNotEmpty && !line.startsWith('*')) line.trim(),
    ];
  }
}
