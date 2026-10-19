package com.alertaciudadana.alerta_ciudadana

import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.alertaciudadana/hardware_trigger"
    private var methodChannel: MethodChannel? = null
    private var pendingTriggerEmergency: Boolean = false
    private var pendingStopTrackingPin: Boolean = false
    private var pendingSource: String = "power_button_3x"
    private var pendingAlertType: String = "ROBO"

    companion object {
        const val EXTRA_TRIGGER_EMERGENCY = "EXTRA_TRIGGER_EMERGENCY"
        const val EXTRA_STOP_TRACKING_PIN = "EXTRA_STOP_TRACKING_PIN"
        var instance: MainActivity? = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        instance = this
        applyLockScreenFlags(false)

        // Solo iniciar el servicio en primer plano si el usuario ha iniciado sesión
        try {
            if (EmergencyForegroundService.isUserLoggedIn(this)) {
                EmergencyForegroundService.startService(applicationContext)
            }
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "Error iniciando servicio: ${e.message}")
        }

        checkIntentExtras(intent)
    }

    private fun applyLockScreenFlags(isEmergency: Boolean) {
        if (isEmergency) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            }
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        } else {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(false)
                setTurnScreenOn(false)
            }
            @Suppress("DEPRECATION")
            window.clearFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }
    }

    override fun onResume() {
        super.onResume()
        if (!pendingTriggerEmergency) {
            applyLockScreenFlags(false)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        checkIntentExtras(intent)
    }

    private fun checkIntentExtras(intent: Intent?) {
        if (intent == null) return

        // Si se abre por emergencia, cancelar la notificación de alarma
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        notificationManager?.cancel(EmergencyForegroundService.PANIC_NOTIFICATION_ID)

        // Si el usuario NO está autenticado, ignorar cualquier llamada a emergencias
        if (!EmergencyForegroundService.isUserLoggedIn(this)) {
            intent.removeExtra(EXTRA_TRIGGER_EMERGENCY)
            intent.removeExtra("source")
            intent.removeExtra("alert_type")
            pendingTriggerEmergency = false
            return
        }

        if (intent.getBooleanExtra(EXTRA_TRIGGER_EMERGENCY, false)) {
            applyLockScreenFlags(true)
            val src = intent.getStringExtra("source") ?: "power_button_3x"
            val alertType = intent.getStringExtra("alert_type") ?: "ROBO"
            intent.removeExtra(EXTRA_TRIGGER_EMERGENCY)
            intent.removeExtra("source")
            intent.removeExtra("alert_type")
            pendingTriggerEmergency = true
            pendingSource = src
            pendingAlertType = alertType
            triggerPanicFromNative(src, alertType)
        }

        if (intent.getBooleanExtra(EXTRA_STOP_TRACKING_PIN, false)) {
            intent.removeExtra(EXTRA_STOP_TRACKING_PIN)
            pendingStopTrackingPin = true
            runOnUiThread {
                methodChannel?.invokeMethod("onOpenStopTrackingDialog", null)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startBackgroundService" -> {
                    if (EmergencyForegroundService.isUserLoggedIn(this)) {
                        EmergencyForegroundService.startService(applicationContext)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "startEmergencyFlow" -> {
                    // Ruta única de despacho desde la UI: el servicio nativo hace GPS,
                    // cuenta regresiva, despacho y rastreo. Evita el doble envío.
                    if (EmergencyForegroundService.isUserLoggedIn(this)) {
                        val alertType = call.argument<String>("alertType") ?: "ROBO"
                        val source = call.argument<String>("source") ?: "ui_button"
                        EmergencyForegroundService.triggerEmergency(applicationContext, alertType, source)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "dispatchNow" -> {
                    // "ENVIAR AHORA": salta la cuenta regresiva nativa y despacha de inmediato.
                    EmergencyForegroundService.dispatchNow(applicationContext)
                    result.success(true)
                }
                "stopBackgroundService" -> {
                    EmergencyForegroundService.stopService(applicationContext)
                    result.success(true)
                }
                "updateLiveTrackingNotification" -> {
                    val isTracking = call.argument<Boolean>("isTracking") ?: false
                    EmergencyForegroundService.updateTrackingStatus(applicationContext, isTracking)
                    result.success(true)
                }
                "simulatePowerPress3x" -> {
                    if (EmergencyForegroundService.isUserLoggedIn(this)) {
                        triggerPanicFromNative("simulated_power_press_3x", "ROBO")
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "checkPendingTrigger" -> {
                    if (!EmergencyForegroundService.isUserLoggedIn(this)) {
                        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                        prefs.edit()
                            .putBoolean("flutter.pending_emergency_dispatched", false)
                            .putBoolean("flutter.pending_emergency_active", false)
                            .putBoolean("flutter.native_dispatched_success", false)
                            .apply()
                        EmergencyForegroundService.isEmergencyDispatched = false
                        EmergencyForegroundService.isEmergencyActive = false
                        pendingTriggerEmergency = false
                        result.success(mapOf("hasPending" to false))
                        return@setMethodCallHandler
                    }
                    val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    val isDispatched = prefs.getBoolean("flutter.pending_emergency_dispatched", false) || EmergencyForegroundService.isEmergencyDispatched
                    val nativeSuccess = prefs.getBoolean("flutter.native_dispatched_success", false)
                    val isActive = prefs.getBoolean("flutter.pending_emergency_active", false) || EmergencyForegroundService.isEmergencyActive
                    val source = prefs.getString("flutter.pending_emergency_source", pendingSource) ?: pendingSource
                    val alertType = prefs.getString("flutter.pending_emergency_alert_type", pendingAlertType) ?: pendingAlertType

                    if (isDispatched) {
                        prefs.edit()
                            .putBoolean("flutter.pending_emergency_dispatched", false)
                            .putBoolean("flutter.pending_emergency_active", false)
                            .putBoolean("flutter.native_dispatched_success", false)
                            .apply()
                        EmergencyForegroundService.isEmergencyDispatched = false
                        EmergencyForegroundService.isEmergencyActive = false
                        pendingTriggerEmergency = false

                        result.success(mapOf(
                            "hasPending" to true,
                            "isDispatched" to true,
                            "nativeSuccess" to nativeSuccess,
                            "source" to source,
                            "alertType" to alertType
                        ))
                    } else if (isActive || pendingTriggerEmergency) {
                        prefs.edit()
                            .putBoolean("flutter.pending_emergency_active", false)
                            .apply()
                        EmergencyForegroundService.isEmergencyActive = false
                        pendingTriggerEmergency = false

                        result.success(mapOf(
                            "hasPending" to true,
                            "isDispatched" to false,
                            "source" to source,
                            "alertType" to alertType
                        ))
                    } else {
                        result.success(mapOf("hasPending" to false))
                    }
                }
                "cancelEmergency" -> {
                    EmergencyForegroundService.cancelEmergency(applicationContext)
                    lastPanicTriggerTime = 0L
                    pendingTriggerEmergency = false
                    result.success(true)
                }
                "resetEmergencyState" -> {
                    EmergencyForegroundService.isEmergencyActive = false
                    EmergencyForegroundService.activeCountdownTimer?.cancel()
                    EmergencyForegroundService.activeCountdownTimer = null
                    lastPanicTriggerTime = 0L
                    pendingTriggerEmergency = false
                    result.success(true)
                }
                "checkPendingStopTracking" -> {
                    if (pendingStopTrackingPin) {
                        pendingStopTrackingPin = false
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "isNativeActive" -> {
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // Si había llamadas pendientes antes de que Flutter terminara de inicializar
        if (pendingTriggerEmergency) {
            triggerPanicFromNative(pendingSource, pendingAlertType)
        }

        if (pendingStopTrackingPin) {
            runOnUiThread {
                methodChannel?.invokeMethod("onOpenStopTrackingDialog", null)
            }
        }
    }

    private var lastPanicTriggerTime: Long = 0

    fun triggerPanicFromNative(source: String, alertType: String = "ROBO"): Boolean {
        // Bloqueo total si el usuario no ha iniciado sesión
        if (!EmergencyForegroundService.isUserLoggedIn(this)) {
            pendingTriggerEmergency = false
            return false
        }

        pendingSource = source
        pendingAlertType = alertType
        if (methodChannel == null) {
            pendingTriggerEmergency = true
            return false
        }
        val now = System.currentTimeMillis()
        if (now - lastPanicTriggerTime < 2500) {
            // Ignorar disparos duplicados dentro de 2.5 segundos
            return true
        }
        lastPanicTriggerTime = now
        pendingTriggerEmergency = false
        runOnUiThread {
            methodChannel?.invokeMethod("onPanicTriggered", mapOf("source" to source, "alertType" to alertType))
        }
        return true
    }

    fun onEmergencyDispatchedFromNative(alertType: String, source: String, nativeSuccess: Boolean = true, reportId: Long? = null) {
        runOnUiThread {
            methodChannel?.invokeMethod(
                "onEmergencyDispatched",
                mapOf(
                    "alertType" to alertType,
                    "source" to source,
                    "nativeSuccess" to nativeSuccess,
                    "reportId" to reportId,
                ),
            )
        }
    }

    private val physicalKeyTimestamps = mutableListOf<Long>()
    private var lastKeyTime: Long = 0

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            val keyCode = event.keyCode
            if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || 
                keyCode == KeyEvent.KEYCODE_VOLUME_UP || 
                keyCode == KeyEvent.KEYCODE_POWER) {
                
                val now = System.currentTimeMillis()
                if (now - lastKeyTime > 60L) {
                    lastKeyTime = now

                    // Misma regla que el servicio: 3+ pulsaciones rápidas y consecutivas.
                    val reached = EmergencyForegroundService.registerRapidPowerPress(physicalKeyTimestamps, now)
                    val count = physicalKeyTimestamps.size
                    android.util.Log.i("MainActivity", "🔘 Tecla física pulsada (código $keyCode). Acumuladas: $count")

                    if (reached) {
                        physicalKeyTimestamps.clear()
                        android.util.Log.i("MainActivity", "⚡ DISPARO CONFIRMADO POR BOTONES FÍSICOS: 3+ pulsaciones rápidas")
                        EmergencyForegroundService.triggerConfirmedHaptic(this)
                        applyLockScreenFlags(true)
                        triggerPanicFromNative("physical_button_rapid", "ROBO")
                        return true
                    } else if (count == 2) {
                        EmergencyForegroundService.triggerSinglePressHaptic(this)
                    }
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        if (instance == this) {
            instance = null
        }
        super.onDestroy()
    }
}
