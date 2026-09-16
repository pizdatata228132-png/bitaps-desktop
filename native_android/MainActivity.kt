package com.bitapsvpn.bitaps_vpn

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Разрешение на уведомления спрашиваем СРАЗУ при запуске, а не в момент подключения.
// Причина: служба VPN работает как приоритетная и обязана показать уведомление. Если на
// Android 13+ разрешения нет, показать его не удаётся, startForeground не вызывается — и
// система убивает службу через пять секунд («did not then call Service.startForeground»).
// Снаружи это выглядело так: подключился, а через мгновение туннель отвалился с зависанием.
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    // Канал «bitaps/system»: мелкие системные действия, которым не нужен отдельный плагин.
    // openVpnSettings — экран системной настройки Always-on VPN (дополнение к нашему
    // автостарту: системный Always-on держит туннель даже между перезагрузками приложения).
    // isVpnActive — НАДЁЖНОЕ «наш VPN сейчас поднят»: через ConnectivityManager (уровень ОС),
    // а не через задержку ядра плагина. Зачем: проверка через connectedDelayAlive после
    // свайп-убийства врала «мёртв» — в новом процессе у плагина нет своего ядра, и приложение
    // рисовало «Отключено» при живом туннеле (и дёргало реконнект).
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bitaps/system")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openVpnSettings" -> try {
                        startActivity(Intent("android.settings.VPN_SETTINGS"))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                    // 15.09: автообновление APK — системная страница «установка из неизвестных
                    // источников» для нашего пакета. open_file лишь ПРОВЕРЯЕТ canRequestPackageInstalls
                    // и молча отказывает — сами ведём человека в настройку один раз.
                    "openInstallSettings" -> try {
                        val i = Intent("android.settings.MANAGE_UNKNOWN_APP_SOURCES")
                        i.data = android.net.Uri.parse("package:$packageName")
                        startActivity(i)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                    "isVpnActive" -> try {
                        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
                        result.success(caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN))
                    } catch (e: Exception) {
                        result.success(false)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
