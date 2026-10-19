package com.alertaciudadana.alerta_ciudadana

import android.app.AlarmManager
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Geocoder
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Looper
import android.media.AudioAttributes
import android.os.Build
import android.os.CountDownTimer
import android.os.IBinder
import android.os.PowerManager
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class EmergencyForegroundService : Service() {

    private var lastScreenAction: String? = null
    private var lastScreenActionTime: Long = 0
    private val powerPressTimestamps = ArrayList<Long>()
    private var screenReceiver: BroadcastReceiver? = null
    private var isLiveTrackingActive: Boolean = false

    private var locationManager: LocationManager? = null
    private var activeLocation: Location? = null
    private var locationListener: LocationListener? = null
    private var activeEmergencyLocationListener: LocationListener? = null

    private var sensorManager: SensorManager? = null
    private var linearAccelerometer: Sensor? = null
    private var rawAccelerometer: Sensor? = null
    private var gyroscope: Sensor? = null
    private var sensorEventListener: SensorEventListener? = null
    private var lastTheftTriggerTime: Long = 0
    private var lastButtonTriggerTime: Long = 0

    // Verificación de Fuga en 2 Fases (Estándar Google Theft Detection & Descarte de Reposo/Cama)
    private var isVerifyingTheftEscape: Boolean = false
    private var candidateSnatchTime: Long = 0
    private var candidateSnatchSource: String = ""
    private var candidateSnatchDetail: String = ""
    private var tailMotionSamples: Int = 0
    private var tailStillSamples: Int = 0
    private var lastActiveMotionTimestamp: Long = 0
    private var candidateStartLocation: Location? = null
    private var escapeVerificationHandler: android.os.Handler? = null
    private var lastCurrentLinearMag: Float = 0f
    private var lastCurrentGyroMag: Float = 0f

    // Control de corrección satelital y transmisión continua en vivo con pantalla apagada
    private var hasCorrectedInitialReportLocation: Boolean = false
    private var liveTrackingHandler: android.os.Handler? = null
    private var liveTrackingRunnable: Runnable? = null

    // WakeLock para garantizar ejecución continua de CPU y sensores con pantalla apagada / Doze Mode
    private var emergencyWakeLock: PowerManager.WakeLock? = null

    private fun acquireEmergencyWakeLock(timeoutMs: Long = 35000L) {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
            if (emergencyWakeLock == null) {
                emergencyWakeLock = pm?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "AlertaCiudadana:EmergencyCpuLock")
            }
            emergencyWakeLock?.let { wl ->
                if (wl.isHeld) {
                    try { wl.release() } catch (_: Exception) {}
                }
                wl.acquire(timeoutMs)
                android.util.Log.i("EmergencyService", "🔋 WakeLock de CPU activo ($timeoutMs ms) para forzado de hardware con pantalla apagada")
            }
        } catch (e: Exception) {
            android.util.Log.e("EmergencyService", "Error adquiriendo WakeLock de CPU: ${e.message}")
        }
    }

    private fun releaseEmergencyWakeLock() {
        try {
            emergencyWakeLock?.let { wl ->
                if (wl.isHeld) {
                    wl.release()
                    android.util.Log.i("EmergencyService", "🔋 WakeLock de CPU liberado")
                }
            }
        } catch (_: Exception) {}
    }

    companion object {
        const val CHANNEL_ID = "alerta_ciudadana_protection_channel"
        const val EMERGENCY_ALARM_CHANNEL_ID = "alerta_ciudadana_emergency_alarm"
        const val NOTIFICATION_ID = 1001
        const val PANIC_NOTIFICATION_ID = 9999

        const val ACTION_START_GUARD = "ACTION_START_GUARD"
        const val ACTION_STOP_GUARD = "ACTION_STOP_GUARD"
        const val ACTION_SET_TRACKING = "ACTION_SET_TRACKING"
        const val ACTION_TRIGGER_EMERGENCY = "ACTION_TRIGGER_EMERGENCY"
        const val ACTION_DISPATCH_NOW = "ACTION_DISPATCH_NOW"
        const val EXTRA_IS_TRACKING = "EXTRA_IS_TRACKING"
        const val EXTRA_ALERT_TYPE = "EXTRA_ALERT_TYPE"
        const val EXTRA_SOURCE = "EXTRA_SOURCE"

        var isServiceRunning = false

        // Punto de entrada ÚNICO para disparar una emergencia desde cualquier origen
        // (botón de encendido 3x, sensor, o botón de la UI). Garantiza UN solo despacho
        // y UN solo id_reporte, sin importar quién lo inicie.
        fun triggerEmergency(context: Context, alertType: String, source: String) {
            try {
                val intent = Intent(context, EmergencyForegroundService::class.java).apply {
                    action = ACTION_TRIGGER_EMERGENCY
                    putExtra(EXTRA_ALERT_TYPE, alertType)
                    putExtra(EXTRA_SOURCE, source)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                android.util.Log.e("EmergencyService", "No se pudo iniciar flujo de emergencia: ${e.message}")
            }
        }

        // Salta la cuenta regresiva y despacha inmediatamente (botón "ENVIAR AHORA").
        fun dispatchNow(context: Context) {
            try {
                val intent = Intent(context, EmergencyForegroundService::class.java).apply {
                    action = ACTION_DISPATCH_NOW
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                android.util.Log.e("EmergencyService", "No se pudo despachar inmediatamente: ${e.message}")
            }
        }

        var activeCountdownTimer: CountDownTimer? = null
        var isEmergencyActive: Boolean = false
        var currentEmergencySource: String = "power_button_3x"
        var currentEmergencyAlertType: String = "ROBO"
        var emergencyTriggerTimestamp: Long = 0
        var isEmergencyDispatched: Boolean = false
        var activeEmergencyReportId: Long? = null

        fun isUserLoggedIn(context: Context): Boolean {
            return try {
                val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                val loggedIn = prefs.getBoolean("flutter.app_session_is_logged_in", false)
                if (loggedIn) return true

                val dni = prefs.getString("flutter.app_session_user_dni", "") ?: ""
                val lastDni = prefs.getString("flutter.app_last_used_dni", "") ?: ""
                val token = prefs.getString("flutter.app_session_jwt_token", "") ?: ""
                val pin = prefs.getString("flutter.app_session_secret_pin", "") ?: ""
                val idPersona = prefs.getInt("flutter.app_session_user_id_persona", -1)

                if (dni.isNotEmpty() || lastDni.isNotEmpty() || token.isNotEmpty() || pin.isNotEmpty() || idPersona > 0) {
                    return true
                }

                if (MainActivity.instance != null) {
                    return true
                }

                true
            } catch (_: Exception) {
                true
            }
        }

        // ────────────────────────────────────────────────────────────────────
        //  Detección del gesto de pánico: "3 o más pulsaciones RÁPIDAS y
        //  CONSECUTIVAS del botón de encendido".
        //
        //  Cada transición de pantalla (ACTION_SCREEN_OFF / ACTION_SCREEN_ON)
        //  equivale a UNA pulsación física real del botón de encendido. La MISMA
        //  regla de conteo la usan el servicio (pantalla on/off, en segundo plano)
        //  y MainActivity (teclas físicas, en primer plano) para que el conteo
        //  sea idéntico y no se desincronice.
        // ────────────────────────────────────────────────────────────────────

        /** Número mínimo de pulsaciones rápidas para disparar la alerta. */
        const val POWER_MIN_PRESSES = 3

        /** Máxima separación (ms) entre dos pulsaciones para considerarlas "rápidas y consecutivas". */
        const val POWER_MAX_GAP_MS = 1800L

        /** Ventana total (ms) para completar las 3 pulsaciones. */
        const val POWER_WINDOW_3_MS = 3500L

        /** Ventana extendida (ms) cuando el usuario pulsa 5 o más veces (ráfaga de pánico). */
        const val POWER_WINDOW_BURST_MS = 5000L

        /**
         * Registra una nueva pulsación dentro de una secuencia y evalúa si se completó
         * el gesto de pánico.
         *
         * Reglas:
         *  - Si transcurre más de [POWER_MAX_GAP_MS] desde la última pulsación, la
         *    secuencia se reinicia (dejan de ser "consecutivas").
         *  - Se conservan solo las pulsaciones dentro de la ventana deslizante.
         *  - Se dispara con 3+ pulsaciones dentro de la ventana (5+ tienen margen extra).
         *
         * @param timestamps lista mutable con las marcas de tiempo de la secuencia en curso.
         * @param now marca de tiempo de la pulsación actual.
         * @return true cuando se completó el gesto de 3+ pulsaciones rápidas.
         */
        fun registerRapidPowerPress(timestamps: MutableList<Long>, now: Long): Boolean {
            // Pausa larga entre pulsaciones: la secuencia ya no es "consecutiva".
            if (timestamps.isNotEmpty() && (now - timestamps.last()) > POWER_MAX_GAP_MS) {
                timestamps.clear()
            }

            val window = if (timestamps.size >= 5) POWER_WINDOW_BURST_MS else POWER_WINDOW_3_MS
            timestamps.removeAll { now - it > window }
            timestamps.add(now)

            if (timestamps.size < POWER_MIN_PRESSES) return false

            val maxAllowed = if (timestamps.size >= 5) POWER_WINDOW_BURST_MS else POWER_WINDOW_3_MS
            if (now - timestamps.first() <= maxAllowed) return true

            // Fuera de ventana: conservar solo lo más reciente para el siguiente intento.
            timestamps.removeAll { now - it > POWER_MAX_GAP_MS }
            return false
        }

        // Nota: se eliminó el háptico intermedio (1ª/2ª pulsación) a propósito: solo debe
        // vibrar al confirmar el gesto de 3+ pulsaciones (triggerConfirmedHaptic).

        fun triggerConfirmedHaptic(context: Context) {
            try {
                val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    val vibratorManager = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? android.os.VibratorManager
                    vibratorManager?.defaultVibrator
                } else {
                    @Suppress("DEPRECATION")
                    context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
                }

                if (vibrator == null || !vibrator.hasVibrator()) return

                val audioAttributes = AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .build()

                // Patrón táctil firme y contundente de 3 pulsaciones fuertes
                val timings = longArrayOf(0, 320, 140, 320, 140, 550)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val amplitudes = intArrayOf(0, 255, 0, 255, 0, 255)
                    val effect = VibrationEffect.createWaveform(timings, amplitudes, -1)
                    vibrator.vibrate(effect, audioAttributes)
                } else {
                    @Suppress("DEPRECATION")
                    vibrator.vibrate(timings, -1)
                }
            } catch (_: Exception) {
                try {
                    @Suppress("DEPRECATION")
                    val fallback = context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
                    fallback?.vibrate(700L)
                } catch (_: Exception) {}
            }
        }

        fun startService(context: Context) {
            try {
                if (!isUserLoggedIn(context)) return
                val intent = Intent(context, EmergencyForegroundService::class.java).apply {
                    action = ACTION_START_GUARD
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                android.util.Log.e("EmergencyService", "No se pudo iniciar startForegroundService: ${e.message}")
            }
        }

        fun updateTrackingStatus(context: Context, isTracking: Boolean) {
            try {
                val intent = Intent(context, EmergencyForegroundService::class.java).apply {
                    action = ACTION_SET_TRACKING
                    putExtra(EXTRA_IS_TRACKING, isTracking)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                android.util.Log.e("EmergencyService", "No se pudo actualizar estado de rastreo: ${e.message}")
            }
        }

        fun cancelEmergency(context: Context) {
            activeCountdownTimer?.cancel()
            activeCountdownTimer = null
            isEmergencyActive = false
            isEmergencyDispatched = false

            // Si hay un reporte activo, notificar marcador (0.0, 0.0) de cierre a Supabase
            activeEmergencyReportId?.let { repId ->
                Thread {
                    try {
                        val supabaseUrl = URL("https://emtzprcntefzkvvzmhfk.supabase.co/rest/v1/ubicacion")
                        val conn = supabaseUrl.openConnection() as HttpURLConnection
                        conn.requestMethod = "POST"
                        conn.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                        conn.setRequestProperty("apikey", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVtdHpwcmNudGVmemt2dnptaGZrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA3ODIxNzIsImV4cCI6MjEwNjM1ODE3Mn0.x18Bh68n4ZgtNOyVPwIc01V6aL50oUaXjeXELzlWEh4")
                        conn.setRequestProperty("Authorization", "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVtdHpwcmNudGVmemt2dnptaGZrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA3ODIxNzIsImV4cCI6MjEwNjM1ODE3Mn0.x18Bh68n4ZgtNOyVPwIc01V6aL50oUaXjeXELzlWEh4")
                        conn.connectTimeout = 4000
                        conn.readTimeout = 4000
                        conn.doOutput = true
                        val sBody = JSONObject().apply {
                            put("id_reporte", repId)
                            put("latitud", 0.0)
                            put("longitud", 0.0)
                        }
                        val bytes = sBody.toString().toByteArray(Charsets.UTF_8)
                        conn.outputStream.use { os ->
                            os.write(bytes)
                            os.flush()
                        }
                        conn.responseCode
                        conn.disconnect()
                    } catch (_: Exception) {}
                }.start()
            }
            activeEmergencyReportId = null

            // Enviar orden inmediata de fin de rastreo y restauración de notificación al servicio
            try {
                val intent = Intent(context, EmergencyForegroundService::class.java).apply {
                    action = ACTION_SET_TRACKING
                    putExtra(EXTRA_IS_TRACKING, false)
                }
                context.startService(intent)
            } catch (_: Exception) {}

            try {
                val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                prefs.edit()
                    .putBoolean("flutter.pending_emergency_active", false)
                    .putBoolean("flutter.pending_emergency_dispatched", false)
                    .putBoolean("flutter.native_dispatched_success", false)
                    .apply()
            } catch (_: Exception) {}

            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            notificationManager?.cancel(PANIC_NOTIFICATION_ID)
        }

        fun stopService(context: Context) {
            cancelEmergency(context)
            val intent = Intent(context, EmergencyForegroundService::class.java).apply {
                action = ACTION_STOP_GUARD
            }
            context.stopService(intent)
        }
    }

    override fun onCreate() {
        super.onCreate()
        if (!isUserLoggedIn(this)) {
            stopSelf()
            return
        }
        isServiceRunning = true
        createNotificationChannels()
        registerScreenReceiver()
        registerSensorListener()
        registerLocationListener()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!isUserLoggedIn(this)) {
            stopForeground(true)
            stopSelf()
            return START_NOT_STICKY
        }

        when (intent?.action) {
            ACTION_START_GUARD, null -> {
                // Asegurar que el servicio permanezca en primer plano aunque se cierre la app
                try {
                    val notification = buildCurrentNotification()
                    startForeground(NOTIFICATION_ID, notification)
                } catch (e: Exception) {
                    android.util.Log.e("EmergencyService", "Error re-lanzando foreground tras cierre de app: ${e.message}")
                }
            }
            ACTION_STOP_GUARD -> {
                stopForeground(true)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_SET_TRACKING -> {
                isLiveTrackingActive = intent.getBooleanExtra(EXTRA_IS_TRACKING, false)
                if (!isLiveTrackingActive) {
                    stopNativeLiveTrackingLoop()
                    stopHighAccuracyGpsLock()
                    hasCorrectedInitialReportLocation = false
                } else {
                    startNativeLiveTrackingLoop()
                }
                val notification = buildCurrentNotification()
                val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                manager?.notify(NOTIFICATION_ID, notification)
                return START_STICKY
            }
            ACTION_TRIGGER_EMERGENCY -> {
                // Disparo iniciado desde la UI de Flutter: reutiliza el MISMO flujo nativo
                // (GPS + cuenta regresiva + despacho + rastreo). Un solo dueño, un solo reporte.
                val alertType = intent.getStringExtra(EXTRA_ALERT_TYPE) ?: "ROBO"
                val source = intent.getStringExtra(EXTRA_SOURCE) ?: "ui_button"
                try {
                    val notification = buildCurrentNotification()
                    startForeground(NOTIFICATION_ID, notification)
                } catch (_: Exception) {}
                startEmergencyFlow(source, alertType, "Despacho desde la aplicación ($source)")
                return START_STICKY
            }
            ACTION_DISPATCH_NOW -> {
                // "ENVIAR AHORA": salta la cuenta restante y despacha de inmediato.
                val shouldDispatch = isEmergencyActive && !isEmergencyDispatched
                activeCountdownTimer?.cancel()
                activeCountdownTimer = null
                isEmergencyActive = false
                if (shouldDispatch) {
                    dispatchEmergencyAlertFromService(currentEmergencySource, currentEmergencyAlertType)
                }
                return START_STICKY
            }
        }

        registerScreenReceiver()
        registerSensorListener()
        registerLocationListener()

        try {
            val notification = buildCurrentNotification()
            startForeground(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            android.util.Log.e("EmergencyService", "Error en startForeground: ${e.message}")
        }

        return START_STICKY
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

            // 1. Canal de guardia permanente (discreto)
            val guardChannel = NotificationChannel(
                CHANNEL_ID,
                "Protección de Seguridad Continua",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Monitoreo del botón de encendido (3x) y estado de protección"
                setShowBadge(false)
            }
            manager?.createNotificationChannel(guardChannel)

            // 2. Canal de emergencia máxima para Full-Screen Intent y Heads-Up emergente
            val alarmChannel = NotificationChannel(
                EMERGENCY_ALARM_CHANNEL_ID,
                "Alarma de Emergencia Inmediata",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Muestra la pantalla de cancelación por PIN fuera de la aplicación"
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 300, 150, 300)
            }
            manager?.createNotificationChannel(alarmChannel)
        }
    }

    private fun buildCurrentNotification(): Notification {
        val appIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val appPendingIntent = PendingIntent.getActivity(
            this,
            0,
            appIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val smallIcon = applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.ic_lock_idle_alarm

        if (isLiveTrackingActive) {
            val stopTrackingIntent = Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(MainActivity.EXTRA_STOP_TRACKING_PIN, true)
            }
            val stopTrackingPendingIntent = PendingIntent.getActivity(
                this,
                1,
                stopTrackingIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )

            return NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(smallIcon)
                .setContentTitle("🚨 RASTREO GPS EN VIVO: ROBO ACTIVO")
                .setContentText("Transmitiendo tu ubicación en tiempo real a la Central...")
                .setStyle(NotificationCompat.BigTextStyle().bigText("Transmitiendo tu ubicación en tiempo real a la Central de Video Vigilancia.\nToca para abrir o presiona el botón inferior para detener."))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setOngoing(true)
                .setContentIntent(stopTrackingPendingIntent)
                .addAction(
                    android.R.drawable.ic_delete,
                    "🛑 DETENER TRANSMISIÓN (PIN)",
                    stopTrackingPendingIntent
                )
                .build()
        } else {
            return NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(smallIcon)
                .setContentTitle("AlertaCiudadana - Protección Activa")
                .setContentText("Monitoreando botón de encendido (3+ pulsaciones rápidas)")
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .setContentIntent(appPendingIntent)
                .build()
        }
    }

    private fun registerScreenReceiver() {
        if (screenReceiver != null) return
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
        }

        screenReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                // Si el usuario no ha iniciado sesión, ignorar completamente cualquier pulsación
                if (!isUserLoggedIn(this@EmergencyForegroundService)) {
                    powerPressTimestamps.clear()
                    lastScreenAction = null
                    return
                }

                val action = intent?.action ?: return
                val now = System.currentTimeMillis()

                // Si ya está activa la emergencia: verificar si expiró (más de 30s) para no bloquear indefinidamente
                if (isEmergencyActive) {
                    if (emergencyTriggerTimestamp > 0 && (now - emergencyTriggerTimestamp > 30000L)) {
                        isEmergencyActive = false
                        activeCountdownTimer?.cancel()
                        activeCountdownTimer = null
                    } else {
                        // El usuario sigue pulsando en emergencia: darle confirmación háptica táctil
                        triggerConfirmedHaptic(this@EmergencyForegroundService)
                        return
                    }
                }

                // Anti-rebote mínimo: cada transición real de pantalla ya es 1 pulsación.
                if (now - lastScreenActionTime < 60L) {
                    return
                }
                lastScreenActionTime = now
                lastScreenAction = action

                // Registrar la pulsación y evaluar el gesto de pánico.
                val reached = registerRapidPowerPress(powerPressTimestamps, now)
                val currentCount = powerPressTimestamps.size
                android.util.Log.i("EmergencyService", "🔘 Pulsación física detectada [$action]. Acumuladas: $currentCount (máx. ${POWER_MAX_GAP_MS}ms entre pulsaciones)")

                if (reached) {
                    powerPressTimestamps.clear()
                    lastScreenAction = null
                    lastButtonTriggerTime = now
                    android.util.Log.i("EmergencyService", "⚡ DISPARO CONFIRMADO: 3+ pulsaciones rápidas del botón de encendido")
                    triggerConfirmedHaptic(this@EmergencyForegroundService)
                    onRapidPowerPressDetected()
                }
                // Sin háptico intermedio: NO vibrar en la 1ª ni 2ª pulsación (puede confundir
                // a las personas creyendo que la alarma ya se activó). Solo vibra al completar
                // el gesto de 3+ pulsaciones.
            }
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(screenReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(screenReceiver, filter)
            }
        } catch (e: Exception) {
            android.util.Log.e("EmergencyService", "No se pudo registrar el receptor de pantalla: ${e.message}")
            try {
                registerReceiver(screenReceiver, filter)
            } catch (_: Exception) {}
        }
    }

    private fun registerSensorListener() {
        if (!isUserLoggedIn(this)) return
        if (sensorManager != null) return
        try {
            sensorManager = getSystemService(Context.SENSOR_SERVICE) as? SensorManager
            // Sensor lineal (excluye gravedad estática de 9.8 m/s²), idéntico al estándar de Theft Detection Lock
            linearAccelerometer = sensorManager?.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
            if (linearAccelerometer == null) {
                rawAccelerometer = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
            }
            gyroscope = sensorManager?.getDefaultSensor(Sensor.TYPE_GYROSCOPE)

            sensorEventListener = object : SensorEventListener {
                override fun onSensorChanged(event: SensorEvent?) {
                    if (event == null) return
                    if (!isUserLoggedIn(this@EmergencyForegroundService)) return
                    val now = System.currentTimeMillis()

                    // Debounce de 8 segundos y no re-disparar si ya hay una emergencia activa
                    if (isEmergencyActive || (now - lastTheftTriggerTime <= 8000)) {
                        return
                    }

                    val x = event.values[0]
                    val y = event.values[1]
                    val z = event.values[2]
                    val magnitude = Math.sqrt((x * x + y * y + z * z).toDouble()).toFloat()

                    // Actualizar memoria sensorial continua para fusión de sensores
                    when (event.sensor.type) {
                        Sensor.TYPE_LINEAR_ACCELERATION -> lastCurrentLinearMag = magnitude
                        Sensor.TYPE_ACCELEROMETER -> lastCurrentLinearMag = Math.abs(magnitude - 9.8f)
                        Sensor.TYPE_GYROSCOPE -> lastCurrentGyroMag = magnitude
                    }

                    // FASE 2: Si estamos dentro de la ventana de verificación de fuga (2200 ms posteriores al jalón)
                    if (isVerifyingTheftEscape) {
                        val isMotionActive = when (event.sensor.type) {
                            Sensor.TYPE_LINEAR_ACCELERATION -> magnitude > 2.8f
                            Sensor.TYPE_ACCELEROMETER -> Math.abs(magnitude - 9.8f) > 2.8f
                            Sensor.TYPE_GYROSCOPE -> magnitude > 1.2f
                            else -> false
                        }

                        val elapsedSinceSnatch = now - candidateSnatchTime
                        val isTailWindow = elapsedSinceSnatch >= 900L

                        if (isMotionActive) {
                            lastActiveMotionTimestamp = now
                            if (isTailWindow) {
                                tailMotionSamples++
                            }
                        } else {
                            val isStill = when (event.sensor.type) {
                                Sensor.TYPE_LINEAR_ACCELERATION -> magnitude < 1.2f
                                Sensor.TYPE_ACCELEROMETER -> Math.abs(magnitude - 9.8f) < 1.2f
                                Sensor.TYPE_GYROSCOPE -> magnitude < 0.5f
                                else -> false
                            }
                            if (isStill && isTailWindow) {
                                tailStillSamples++
                            }
                        }
                        return
                    }

                    // FASE 1: Detección del Jalón de Arrebato Inicial (Candidate Snatch)
                    var isCandidate = false
                    var sourceCandidate = ""
                    var detailCandidate = ""

                    when (event.sensor.type) {
                        Sensor.TYPE_LINEAR_ACCELERATION -> {
                            if (magnitude >= 30.0f) {
                                isCandidate = true
                                sourceCandidate = "sensor_antirrobo_acelerometro"
                                detailCandidate = "Arrebato violento detectado (Aceleración lineal: ${String.format(Locale.US, "%.1f", magnitude)} m/s²)"
                            } else if (magnitude >= 22.0f && lastCurrentGyroMag >= 12.0f) {
                                isCandidate = true
                                sourceCandidate = "sensor_antirrobo_fusion"
                                detailCandidate = "Arrebato con forcejeo detectado (Aceleración: ${String.format(Locale.US, "%.1f", magnitude)} m/s², Giro: ${String.format(Locale.US, "%.1f", lastCurrentGyroMag)} rad/s)"
                            }
                        }
                        Sensor.TYPE_ACCELEROMETER -> {
                            if (magnitude >= 45.0f) {
                                isCandidate = true
                                sourceCandidate = "sensor_antirrobo_acelerometro"
                                detailCandidate = "Arrebato violento detectado (Aceleración total: ${String.format(Locale.US, "%.1f", magnitude)} m/s²)"
                            } else if (magnitude >= 35.0f && lastCurrentGyroMag >= 12.0f) {
                                isCandidate = true
                                sourceCandidate = "sensor_antirrobo_fusion"
                                detailCandidate = "Arrebato con forcejeo detectado (Aceleración: ${String.format(Locale.US, "%.1f", magnitude)} m/s², Giro: ${String.format(Locale.US, "%.1f", lastCurrentGyroMag)} rad/s)"
                            }
                        }
                        Sensor.TYPE_GYROSCOPE -> {
                            if (magnitude >= 18.0f && lastCurrentLinearMag >= 15.0f) {
                                isCandidate = true
                                sourceCandidate = "sensor_antirrobo_giroscopio"
                                detailCandidate = "Forcejeo violento de arrebato detectado (Rotación: ${String.format(Locale.US, "%.1f", magnitude)} rad/s)"
                            } else if (magnitude >= 14.0f && lastCurrentLinearMag >= 20.0f) {
                                isCandidate = true
                                sourceCandidate = "sensor_antirrobo_fusion"
                                detailCandidate = "Forcejeo con jalón detectado (Rotación: ${String.format(Locale.US, "%.1f", magnitude)} rad/s, Aceleración: ${String.format(Locale.US, "%.1f", lastCurrentLinearMag)} m/s²)"
                            }
                        }
                    }

                    if (isCandidate) {
                        // Iniciar Fase 2: Ventana de Verificación de Fuga (2200 ms)
                        // Permite corroborar si tras el jalón hay huida (carrera/moto) o si el celular quedó en reposo (cama/mesa)
                        isVerifyingTheftEscape = true
                        candidateSnatchTime = now
                        candidateSnatchSource = sourceCandidate
                        candidateSnatchDetail = detailCandidate
                        tailMotionSamples = 0
                        tailStillSamples = 0
                        lastActiveMotionTimestamp = now

                        // Capturar ubicación GPS inicial
                        val locationManager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
                        candidateStartLocation = try {
                            val available = locationManager?.getProviders(true) ?: emptyList<String>()
                            var newest: Location? = null
                            for (p in available) {
                                val l = locationManager?.getLastKnownLocation(p)
                                if (l != null && (newest == null || l.time > newest.time)) newest = l
                            }
                            newest
                        } catch (_: Exception) { null }

                        escapeVerificationHandler?.removeCallbacksAndMessages(null)
                        escapeVerificationHandler = android.os.Handler(android.os.Looper.getMainLooper())
                        escapeVerificationHandler?.postDelayed({
                            evaluatePostSnatchEscape()
                        }, 2200L)
                    }
                }

                override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
            }

            linearAccelerometer?.let {
                sensorManager?.registerListener(sensorEventListener, it, SensorManager.SENSOR_DELAY_UI)
            }
            rawAccelerometer?.let {
                sensorManager?.registerListener(sensorEventListener, it, SensorManager.SENSOR_DELAY_UI)
            }
            gyroscope?.let {
                sensorManager?.registerListener(sensorEventListener, it, SensorManager.SENSOR_DELAY_UI)
            }
        } catch (_: Exception) {}
    }

    private fun evaluatePostSnatchEscape() {
        if (!isVerifyingTheftEscape) return
        isVerifyingTheftEscape = false

        if (!isUserLoggedIn(this) || isEmergencyActive) return

        val now = System.currentTimeMillis()
        val timeSinceLastMotion = now - lastActiveMotionTimestamp

        // Consultar ubicación GPS actual tras los 2.2 segundos
        val locationManager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        var endLocation: Location? = null
        try {
            val available = locationManager?.getProviders(true) ?: emptyList<String>()
            var newest: Location? = null
            for (p in available) {
                val l = locationManager?.getLastKnownLocation(p)
                if (l != null && (newest == null || l.time > newest.time)) newest = l
            }
            endLocation = newest
        } catch (_: Exception) {}

        val distanceMoved = if (candidateStartLocation != null && endLocation != null) {
            candidateStartLocation!!.distanceTo(endLocation)
        } else {
            0f
        }
        val currentSpeed = endLocation?.speed ?: 0f // metros por segundo

        android.util.Log.d(
            "TheftDetector",
            "Evaluación Fase 2: tiempoSinMov=${timeSinceLastMotion}ms, colaMov=$tailMotionSamples, colaQuieto=$tailStillSamples, dist=${distanceMoved}m, vel=${currentSpeed}m/s"
        )

        // FASE 2: VERIFICACIÓN ESTRICTA DE FUGA (ESTÁNDAR THEFT DETECTION DE GOOGLE)
        // Para confirmar robo se EXIGE que el delincuente esté en fuga real.
        // Un celular arrojado a la cama/mesa queda en reposo sin movimiento sostenido tras el impacto inicial.
        
        // CONDICIÓN A: Fuga en vehículo / motocicleta / bicicleta o alta velocidad GPS
        val hasGpsTransit = (currentSpeed >= 2.2f && distanceMoved >= 5.0f) || (distanceMoved >= 8.0f)

        // CONDICIÓN B: Fuga a pie (carrera con pasos activos ininterrumpidos hasta el final de la ventana)
        // 1. Debe haber movimiento activo en el presente instante (última muestra hace menos de 350 ms)
        // 2. En la segunda mitad de la ventana (cola > 900ms), debe haber al menos 6 muestras de movimiento sostenido
        // 3. El movimiento activo debe superar al reposo
        val hasPedestrianTransit = (timeSinceLastMotion < 350L) &&
                                   (tailMotionSamples >= 6) &&
                                   (tailMotionSamples > tailStillSamples)

        val isConfirmedEscape = hasGpsTransit || hasPedestrianTransit

        if (isConfirmedEscape) {
            lastTheftTriggerTime = now
            val escapeDescription = if (hasGpsTransit) {
                "Fuga en vehículo/moto (${String.format(Locale.US, "%.1f", currentSpeed)} m/s, ${String.format(Locale.US, "%.1f", distanceMoved)} m)"
            } else {
                "Fuga a pie continua confirmada"
            }
            onTheftSnatchDetected(
                candidateSnatchSource,
                "$candidateSnatchDetail ($escapeDescription)"
            )
        } else {
            android.util.Log.i("TheftDetector", "🛑 FALSO POSITIVO DESCARTADO: Fase 2 no cumplida (reposo en cama/mesa o sin escape continuo).")
        }
    }

    private fun unregisterSensorListener() {
        try {
            escapeVerificationHandler?.removeCallbacksAndMessages(null)
            escapeVerificationHandler = null
            isVerifyingTheftEscape = false
            sensorEventListener?.let {
                sensorManager?.unregisterListener(it)
            }
        } catch (_: Exception) {}
        sensorEventListener = null
        sensorManager = null
        linearAccelerometer = null
        rawAccelerometer = null
        gyroscope = null
    }

    private fun registerLocationListener() {
        if (locationListener != null) return
        try {
            locationManager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            locationListener = object : LocationListener {
                override fun onLocationChanged(location: Location) {
                    // Solo acepta la nueva posición si es genuinamente MEJOR.
                    // Evita que un fix de red/celda pise a uno satelital preciso.
                    if (isBetterLocation(activeLocation, location)) {
                        activeLocation = location
                    }
                }
                override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
                override fun onProviderEnabled(provider: String) {}
                override fun onProviderDisabled(provider: String) {}
            }

            locationManager?.let { lm ->
                if (lm.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
                    lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, 3000L, 2f, locationListener!!)
                }
                if (lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
                    lm.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 3000L, 5f, locationListener!!)
                }
            }
        } catch (_: SecurityException) {
        } catch (_: Exception) {}
    }

    private fun unregisterLocationListener() {
        try {
            locationListener?.let {
                locationManager?.removeUpdates(it)
            }
        } catch (_: Exception) {}
        locationListener = null
        locationManager = null
    }

    // Nivel de confianza del proveedor de ubicación. GPS (satélite) es la máxima autoridad;
    // FUSED lo resuelve el SO y suele respaldarse en satélite; NETWORK es celda/Wi-Fi (imprecisa).
    private fun providerTrust(provider: String?): Int = when (provider) {
        LocationManager.GPS_PROVIDER -> 3
        LocationManager.FUSED_PROVIDER -> 2
        LocationManager.NETWORK_PROVIDER -> 1
        else -> 0
    }

    // Evalúa si `candidate` debe reemplazar a `current` como la mejor posición conocida.
    //
    // BUG QUE CORRIGE: la lógica anterior usaba `location.time > current.time + 10000`, lo que
    // permitía que un fix de RED (torre celular, ±500–2000m) más reciente PISARA un fix GPS
    // preciso (±8m). Esa era la causa directa de los saltos a antenas lejanas en los disparos
    // por botón 3x / sensor con pantalla apagada.
    private fun isBetterLocation(current: Location?, candidate: Location?): Boolean {
        if (candidate == null) return false
        if (current == null) return true

        val candTrust = providerTrust(candidate.provider)
        val curTrust = providerTrust(current.provider)

        // Regla de oro: jamás degradar de una fuente de mayor confianza a una menor,
        // salvo que el candidato sea drásticamente más preciso (>100m mejor).
        if (candTrust < curTrust) {
            return candidate.accuracy < (current.accuracy - 100f)
        }

        // Misma o mayor confianza: elegir por precisión con una tolerancia de 5m.
        val accuracyDelta = candidate.accuracy - current.accuracy
        if (accuracyDelta <= 5f) return true

        // Si el actual está viejo (>20s) y el candidato tiene precisión razonable, actualizar.
        val ageMs = candidate.time - current.time
        if (ageMs > 20000L && candidate.accuracy <= 50f) return true

        return false
    }

    // Devuelve true si `activeLocation` proviene del satélite (o fused satelital) con precisión usable.
    private fun hasSatelliteFix(): Boolean {
        val loc = activeLocation ?: return false
        val trust = providerTrust(loc.provider)
        return trust >= 2 && loc.hasAccuracy() && loc.accuracy <= 50f
    }

    private fun forceHighAccuracyGpsLock() {
        try {
            // 0. Forzar que la CPU y los módulos de radio/sensores no se duerman con pantalla apagada
            acquireEmergencyWakeLock(35000L)

            val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return
            val availableProviders = try { lm.getProviders(true) } catch (_: Exception) { emptyList<String>() }

            // 1. Obtener de inmediato la posición más reciente de TODOS los proveedores disponibles (fused, gps, network, passive)
            try {
                var newestCandidate: Location? = null
                for (prov in availableProviders) {
                    try {
                        val loc = lm.getLastKnownLocation(prov)
                        if (loc != null) {
                            if (newestCandidate == null || loc.time > newestCandidate.time) {
                                newestCandidate = loc
                            }
                        }
                    } catch (_: SecurityException) {} catch (_: Exception) {}
                }
                if (newestCandidate != null) {
                    if (activeLocation == null || newestCandidate.time > activeLocation!!.time) {
                        activeLocation = newestCandidate
                        android.util.Log.i("EmergencyService", "⚡ Posición GPS inicial inmediata disponible [${newestCandidate.provider}]: Lat ${newestCandidate.latitude}, Lon ${newestCandidate.longitude} (antigüedad ${(System.currentTimeMillis() - newestCandidate.time)/1000}s, ±${newestCandidate.accuracy}m)")
                    }
                }
            } catch (_: Exception) {}

            // 2. Forzar lectura activa directa al hardware con lm.getCurrentLocation (Android 11+ / API 30+)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val executor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    mainExecutor
                } else {
                    java.util.concurrent.Executor { r -> android.os.Handler(Looper.getMainLooper()).post(r) }
                }

                for (prov in availableProviders) {
                    try {
                        lm.getCurrentLocation(prov, null, executor) { loc ->
                            if (loc != null) {
                                if (activeLocation == null || loc.time >= activeLocation!!.time || loc.accuracy <= activeLocation!!.accuracy) {
                                    activeLocation = loc
                                    android.util.Log.i("EmergencyService", "🎯 Forzado activo a hardware getCurrentLocation [$prov]: Lat ${loc.latitude}, Lon ${loc.longitude}, Precisión: ±${loc.accuracy}m")
                                    try {
                                        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                                        prefs.edit()
                                            .putString("flutter.last_known_real_lat", loc.latitude.toString())
                                            .putString("flutter.last_known_real_lon", loc.longitude.toString())
                                            .putLong("flutter.last_known_real_time", System.currentTimeMillis())
                                            .apply()
                                    } catch (_: Exception) {}
                                }
                            }
                        }
                    } catch (_: SecurityException) {} catch (_: Exception) {}
                }
            }

            if (activeEmergencyLocationListener != null) {
                try { lm.removeUpdates(activeEmergencyLocationListener!!) } catch (_: Exception) {}
                activeEmergencyLocationListener = null
            }

            // 3. Suscribir listeners de máxima prioridad (0ms, 0m) en todos los proveedores disponibles
            val listener = object : LocationListener {
                override fun onLocationChanged(loc: Location) {
                    // Acepta la posición solo si mejora a la actual (no deja que la red pise al GPS)
                    if (isBetterLocation(activeLocation, loc)) {
                        activeLocation = loc
                    }
                    android.util.Log.i("EmergencyService", "🎯 Fix GPS activo fijado [${loc.provider}]: Lat ${loc.latitude}, Lon ${loc.longitude}, Precisión: ±${loc.accuracy}m")
                    if (loc.accuracy <= 70f) {
                        try {
                            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                            prefs.edit()
                                .putString("flutter.last_known_real_lat", loc.latitude.toString())
                                .putString("flutter.last_known_real_lon", loc.longitude.toString())
                                .putLong("flutter.last_known_real_time", System.currentTimeMillis())
                                .apply()
                        } catch (_: Exception) {}

                        // Si ya se despachó el reporte con ubicación previa/celular, corregirlo inmediatamente con el satélite
                        activeEmergencyReportId?.let { reportId ->
                            patchNativeReportLocationIfBetter(reportId, loc)
                        }
                    }
                }
                override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
                override fun onProviderEnabled(provider: String) {}
                override fun onProviderDisabled(provider: String) {}
            }
            activeEmergencyLocationListener = listener

            for (prov in availableProviders) {
                try {
                    lm.requestLocationUpdates(prov, 0L, 0f, listener, Looper.getMainLooper())
                } catch (_: SecurityException) {} catch (_: Exception) {}
            }
        } catch (_: SecurityException) {
            android.util.Log.w("EmergencyService", "Permiso de ubicación denegado en segundo plano")
        } catch (_: Exception) {}
    }

    private fun stopHighAccuracyGpsLock() {
        if (isEmergencyActive || isLiveTrackingActive) {
            // No apagar el hardware satelital si la emergencia o el rastreo en vivo están en progreso
            return
        }
        try {
            activeEmergencyLocationListener?.let {
                val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager
                lm?.removeUpdates(it)
            }
        } catch (_: Exception) {}
        activeEmergencyLocationListener = null
        releaseEmergencyWakeLock()
    }

    private fun onRapidPowerPressDetected() {
        if (!isUserLoggedIn(this)) return
        if (isEmergencyActive) return
        startEmergencyFlow("power_button_rapid", "ROBO", "Se detectaron 3 o más pulsaciones rápidas y seguidas del botón de encendido")
    }

    private fun onTheftSnatchDetected(source: String, detailInfo: String) {
        if (!isUserLoggedIn(this)) return
        if (isEmergencyActive) return
        startEmergencyFlow(source, "ROBO", detailInfo)
    }

    private fun startEmergencyFlow(source: String, alertType: String, detailInfo: String) {
        if (!isUserLoggedIn(this)) {
            return
        }

        // Si ya hay una emergencia en curso y no ha sido cancelada, ignorar disparos adicionales de pánico
        if (isEmergencyActive && !isEmergencyDispatched) {
            return
        }

        isEmergencyActive = true
        currentEmergencySource = source
        currentEmergencyAlertType = alertType
        emergencyTriggerTimestamp = System.currentTimeMillis()
        isEmergencyDispatched = false

        // Iniciar fijación satelital activa inmediata durante el conteo de 5 segundos
        forceHighAccuracyGpsLock()

        // Guardar estado en SharedPreferences
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            prefs.edit()
                .putBoolean("flutter.pending_emergency_active", true)
                .putString("flutter.pending_emergency_source", source)
                .putString("flutter.pending_emergency_alert_type", alertType)
                .putLong("flutter.pending_emergency_time", emergencyTriggerTimestamp)
                .putBoolean("flutter.pending_emergency_dispatched", false)
                .apply()
        } catch (_: Exception) {}

        val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        val isDeviceLocked = keyguardManager?.isKeyguardLocked ?: false

        // 1. Crear Intent para la actividad
        val fullScreenIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(MainActivity.EXTRA_TRIGGER_EMERGENCY, true)
            putExtra("source", source)
            putExtra("alert_type", alertType)
        }
        val fullScreenPendingIntent = PendingIntent.getActivity(
            this,
            999,
            fullScreenIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // 2. Despertar la CPU (PARTIAL_WAKE_LOCK) y la pantalla para feedback visual inmediato
        acquireEmergencyWakeLock(35000L)
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
            @Suppress("DEPRECATION")
            val screenWakeLock = powerManager?.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                "AlertaCiudadana:PanicScreenLock"
            )
            screenWakeLock?.acquire(15000L)
        } catch (_: Exception) {}

        try {
            MainActivity.instance?.triggerPanicFromNative(source, alertType)
        } catch (_: Exception) {}

        try {
            startActivity(fullScreenIntent)
        } catch (_: Exception) {}

        // 3. Vibración táctil contundente de confirmación en el bolsillo
        triggerHapticFeedback()

        // 4. Iniciar la notificación con cuenta regresiva (5 segundos)
        updateEmergencyNotificationCountdown(5, alertType, fullScreenPendingIntent)

        // 5. Iniciar temporizador nativo de 5 segundos
        activeCountdownTimer?.cancel()
        activeCountdownTimer = object : CountDownTimer(5000, 1000) {
            override fun onTick(millisUntilFinished: Long) {
                val seconds = (millisUntilFinished / 1000) + 1
                if (isEmergencyActive && !isEmergencyDispatched) {
                    updateEmergencyNotificationCountdown(seconds, alertType, fullScreenPendingIntent)
                }
            }

            override fun onFinish() {
                val shouldDispatch = isEmergencyActive && !isEmergencyDispatched
                isEmergencyActive = false
                activeCountdownTimer = null
                if (shouldDispatch) {
                    dispatchEmergencyAlertFromService(source, alertType)
                }
            }
        }.start()
    }

    private fun updateEmergencyNotificationCountdown(secondsLeft: Long, alertType: String, fullScreenPendingIntent: PendingIntent) {
        val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        val isDeviceLocked = keyguardManager?.isKeyguardLocked ?: false

        val smallIcon = applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.ic_lock_idle_alarm
        val title = if (alertType == "ACCIDENTE") {
            "🚗 ¡ACCIDENTE DETECTADO! ($secondsLeft seg)"
        } else {
            "🚨 ¡ALERTA DE ROBO ACTIVADA! ($secondsLeft seg)"
        }
        val text = "Despachando alerta en $secondsLeft segundos. Toca para ingresar PIN y cancelar."

        val builder = NotificationCompat.Builder(this, EMERGENCY_ALARM_CHANNEL_ID)
            .setSmallIcon(smallIcon)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText("$text\nSi fue una falsa alarma, ingresa tu PIN."))
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setOngoing(false)
            .setAutoCancel(true)
            .setContentIntent(fullScreenPendingIntent)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "❌ CANCELAR CON PIN",
                fullScreenPendingIntent
            )

        builder.setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        builder.setFullScreenIntent(fullScreenPendingIntent, true)

        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        notificationManager?.notify(PANIC_NOTIFICATION_ID, builder.build())
    }

    private fun triggerHapticFeedback() {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vibratorManager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? android.os.VibratorManager
                vibratorManager?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }

            if (vibrator == null || !vibrator.hasVibrator()) {
                android.util.Log.w("EmergencyService", "No se detectó vibrador en el dispositivo")
                return
            }

            val audioAttributes = AudioAttributes.Builder()
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(AudioAttributes.USAGE_ALARM)
                .build()

            // Patrón táctil firme y contundente: 3 pulsaciones fuertes
            // (0ms espera, 320ms vibración, 140ms pausa, 320ms vibración, 140ms pausa, 550ms vibración final)
            val timings = longArrayOf(0, 320, 140, 320, 140, 550)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val amplitudes = intArrayOf(0, 255, 0, 255, 0, 255)
                val effect = VibrationEffect.createWaveform(timings, amplitudes, -1)
                vibrator.vibrate(effect, audioAttributes)
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(timings, -1)
            }
            android.util.Log.i("EmergencyService", "✅ Vibración háptica de alerta activada con éxito")
        } catch (e: Exception) {
            android.util.Log.e("EmergencyService", "Error ejecutando vibración háptica: ${e.message}")
            try {
                @Suppress("DEPRECATION")
                val fallback = getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
                fallback?.vibrate(700L)
            } catch (_: Exception) {}
        }
    }

    private fun dispatchEmergencyAlertFromService(source: String, alertType: String) {
        if (!isUserLoggedIn(this)) return
        Thread {
            // Mantener la CPU despierta durante la conexión de red y despacho
            acquireEmergencyWakeLock(30000L)
            var nativeSuccess = false
            var createdReportId: Long? = null
            try {
                // 1. Obtener la MEJOR ubicación GPS disponible (priorizando satélite sobre red).
                // NOTA: `activeLocation` ya viene actualizándose durante la cuenta regresiva de 5s
                // gracias a forceHighAccuracyGpsLock() + registerLocationListener(). Aquí solo
                // completamos con getLastKnownLocation de cada proveedor eligiendo el MEJOR fix,
                // sin bloquear el hilo principal (evita ANR y garantiza despacho inmediato).
                var bestLocation: Location? = activeLocation
                val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager

                // Revisar getLastKnownLocation de cada proveedor eligiendo el MEJOR, no el más nuevo
                try {
                    val availableProviders = lm?.getProviders(true) ?: emptyList<String>()
                    for (prov in availableProviders) {
                        try {
                            val loc = lm?.getLastKnownLocation(prov)
                            if (loc != null && isBetterLocation(bestLocation, loc)) {
                                bestLocation = loc
                            }
                        } catch (_: SecurityException) {} catch (_: Exception) {}
                    }
                } catch (_: Exception) {}

                val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                val cachedRealLat = try {
                    val raw = prefs.all["flutter.last_known_real_lat"]
                    when (raw) {
                        is String -> raw.toDoubleOrNull()
                        is Number -> raw.toDouble()
                        else -> null
                    }
                } catch (_: Exception) { null }
                val cachedRealLon = try {
                    val raw = prefs.all["flutter.last_known_real_lon"]
                    when (raw) {
                        is String -> raw.toDoubleOrNull()
                        is Number -> raw.toDouble()
                        else -> null
                    }
                } catch (_: Exception) { null }
                val cachedRealAddress = try { prefs.getString("flutter.last_known_real_address", null) } catch (_: Exception) { null }
                val cachedRealTime = try { prefs.getLong("flutter.last_known_real_time", 0L) } catch (_: Exception) { 0L }

                // REGLA FUNDAMENTAL DE PRECISIÓN + DETECCIÓN DE CALIDAD:
                //  - Fix satelital usable (≤70m)  -> usarlo directo (calidad SATELITAL).
                //  - Sin fix satelital pero con caché satelital reciente (<90s) -> usar caché (calidad SATELITAL CACHÉ).
                //  - Solo fix de red (>70m)        -> último recurso, marcado como RED APROXIMADA.
                //  - Nada disponible               -> fallback Pisco/Ica marcado explícitamente como SIN GPS,
                //    para que la Central sepa que las coordenadas NO son reales.
                val lat: Double
                val lon: Double
                val locationQuality: String
                val cacheAgeMs = System.currentTimeMillis() - cachedRealTime
                val cacheIsFreshSatellite = cachedRealLat != null && cachedRealLon != null && cacheAgeMs in 0..90_000L

                when {
                    bestLocation != null && bestLocation.accuracy <= 50f && hasSatelliteFix() -> {
                        lat = bestLocation.latitude
                        lon = bestLocation.longitude
                        locationQuality = "SATELITAL (±${String.format(Locale.US, "%.1f", bestLocation.accuracy)}m)"
                    }
                    bestLocation != null && bestLocation.accuracy <= 70f -> {
                        // Puede ser satelital híbrido; prioriza si proveedor es GPS/Fused
                        lat = bestLocation.latitude
                        lon = bestLocation.longitude
                        locationQuality = "SATELITAL HÍBRIDO (±${String.format(Locale.US, "%.1f", bestLocation.accuracy)}m)"
                    }
                    cacheIsFreshSatellite -> {
                        lat = cachedRealLat!!
                        lon = cachedRealLon!!
                        locationQuality = "SATELITAL EN CACHÉ (±${String.format(Locale.US, "%.0f", cacheAgeMs / 1000.0)}s)"
                        android.util.Log.i("EmergencyService", "🛰️ Usando última ubicación satelital verificada en caché: Lat $lat, Lon $lon")
                    }
                    bestLocation != null -> {
                        lat = bestLocation.latitude
                        lon = bestLocation.longitude
                        locationQuality = "RED APROXIMADA (±${String.format(Locale.US, "%.0f", bestLocation.accuracy)}m)"
                    }
                    else -> {
                        lat = -13.71450   // Pisco, Ica — fallback declarado por el usuario
                        lon = -76.20320
                        locationQuality = "⚠️ SIN GPS — UBICACIÓN APROXIMADA PISCO/ICA"
                    }
                }

                val hasRealGps = locationQuality.startsWith("SATELITAL")

                // Resolver dirección y calle exacta mediante el Geocoder nativo
                var realAddress = cachedRealAddress ?: "Pisco, Ica - Ubicación móvil"
                val accuracyStr = if (bestLocation != null && bestLocation.hasAccuracy() && hasRealGps) " (±${String.format(Locale.US, "%.1f", bestLocation.accuracy)}m)" else ""
                if (!hasRealGps && locationQuality.startsWith("⚠️")) {
                    // Fallback sin GPS: dejar claro en la dirección que NO es una ubicación real
                    realAddress = "Pisco, Ica (SIN SEÑAL GPS — ubicación aproximada)"
                } else {
                    try {
                        if (Geocoder.isPresent()) {
                            val geocoder = Geocoder(this, Locale("es", "PE"))
                            @Suppress("DEPRECATION")
                            val addresses = geocoder.getFromLocation(lat, lon, 1)
                            if (!addresses.isNullOrEmpty()) {
                                val addr = addresses[0]
                                val thoroughfare = addr.thoroughfare
                                val subThoroughfare = addr.subThoroughfare
                                val locality = addr.locality ?: addr.subAdminArea ?: "Pisco"
                                if (!thoroughfare.isNullOrBlank()) {
                                    realAddress = if (!subThoroughfare.isNullOrBlank()) {
                                        "$thoroughfare $subThoroughfare, $locality$accuracyStr"
                                    } else {
                                        "$thoroughfare, $locality$accuracyStr"
                                    }
                                } else {
                                    val line = addr.getAddressLine(0)
                                    if (!line.isNullOrBlank()) {
                                        realAddress = "$line$accuracyStr"
                                    }
                                }
                            }
                        }
                    } catch (geoErr: Exception) {
                        android.util.Log.w("EmergencyService", "Geocoder fallback: ${geoErr.message}")
                        realAddress = "Ubicación móvil GPS$accuracyStr"
                    }
                }

                try {
                    prefs.edit()
                        .putString("flutter.last_known_real_lat", lat.toString())
                        .putString("flutter.last_known_real_lon", lon.toString())
                        .putString("flutter.last_known_real_address", realAddress)
                        .putLong("flutter.last_known_real_time", System.currentTimeMillis())
                        .apply()
                } catch (_: Exception) {}

                // 2. Leer datos del ciudadano desde SharedPreferences de forma completamente segura (sin ClassCastException)
                val citizenDni = prefs.getString("flutter.app_session_user_dni", null) ?: "74629337"
                val idPersona: Int = try {
                    val raw = prefs.all["flutter.app_session_user_id_persona"]
                    when (raw) {
                        is Number -> raw.toInt()
                        is String -> raw.toIntOrNull() ?: 3
                        else -> 3
                    }
                } catch (_: Exception) {
                    3
                }

                val headline = if (alertType == "ACCIDENTE") {
                    "🚗💥 ¡ACCIDENTE DE TRÁNSITO! AMBULANCIA Y POLICÍA REQUERIDA 🚗💥"
                } else {
                    "🚨 ¡AUXILIO! ME ESTÁN ROBANDO 🚨"
                }
                val triggerLabel = when (source) {
                    "power_button_rapid", "power_button_3x" -> "BOTÓN DE ENCENDIDO (3+ PULSACIONES RÁPIDAS SEGUIDAS) [MODO BOLSILLO / APP CERRADA]"
                    "sensor_antirrobo_acelerometro" -> "SENSOR ANTIRROBO (ARREBATO BRUSCO / ACELERÓMETRO)"
                    "sensor_antirrobo_giroscopio" -> "SENSOR ANTIRROBO (FORCEJEO BRUSCO / GIROSCOPIO)"
                    "sensor_antirrobo" -> "SENSOR ANTIRROBO (DETECCIÓN DE ROBO EN SEGUNDO PLANO)"
                    "physical_button_3x", "physical_button_rapid" -> "BOTÓN FÍSICO RÁPIDO (3+ PULSACIONES SEGUIDAS) [ROBO]"
                    else -> "DETECCIÓN AUTOMÁTICA DE ROBO (FONDO)"
                }
                val latStr = String.format(Locale.US, "%.5f", lat)
                val lonStr = String.format(Locale.US, "%.5f", lon)
                val gmapsUrl = "https://maps.google.com/?q=$latStr,$lonStr"
                val gmapsNav = "🚗 Cómo llegar (Google Maps): https://www.google.com/maps/dir/?api=1&destination=$latStr,$lonStr"

                val message = "$headline\n" +
                        "📍 Ubicación: $realAddress\n" +
                        "🛰️ Coordenadas: Lat $latStr, Lon $lonStr\n" +
                        "📡 Calidad GPS: $locationQuality\n" +
                        "🗺️ Mapa: $gmapsUrl\n" +
                        "$gmapsNav\n" +
                        "⚡ Disparador: $triggerLabel\n" +
                        "🛡️ Despacho automático WhatsApp API a la Central de Video Vigilancia."

                // 3. Despachar mensaje a WhatsApp vía Edge Function `whatsapp`.
                //    El token de Green API vive SOLO en el servidor (Deno.env);
                //    el APK solo conoce la URL de la Edge Function. Timeout
                //    corto + reintento (respaldo) para no dejar caer la ruta crítica.
                try {
                    val anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVtdHpwcmNudGVmemt2dnptaGZrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA3ODIxNzIsImV4cCI6MjEwNjM1ODE3Mn0.x18Bh68n4ZgtNOyVPwIc01V6aL50oUaXjeXELzlWEh4"
                    val fnUrl = URL("https://emtzprcntefzkvvzmhfk.supabase.co/functions/v1/whatsapp")
                    val jsonBody = JSONObject().apply {
                        put("action", "sendMessage")
                        put("chatId", "51976264949@c.us")
                        put("message", message)
                    }.toString().toByteArray(Charsets.UTF_8)

                    var code = 0
                    var resText = ""
                    for (attempt in 1..2) {
                        val conn = fnUrl.openConnection() as HttpURLConnection
                        try {
                            conn.requestMethod = "POST"
                            conn.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                            conn.setRequestProperty("apikey", anonKey)
                            conn.setRequestProperty("Authorization", "Bearer $anonKey")
                            conn.connectTimeout = 8000
                            conn.readTimeout = 8000
                            conn.doOutput = true
                            conn.setFixedLengthStreamingMode(jsonBody.size)
                            conn.outputStream.use { os ->
                                os.write(jsonBody)
                                os.flush()
                            }
                            code = conn.responseCode
                            resText = if (code in 200..299) {
                                conn.inputStream.bufferedReader().use { it.readText() }
                            } else {
                                conn.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
                            }
                            android.util.Log.d("EmergencyForegroundService", "Edge WhatsApp intento $attempt -> ($code): $resText")
                            if (code in 200..299) {
                                nativeSuccess = true
                                break
                            }
                            if (code in 400..499) break // error del cliente: no reintentar
                        } finally {
                            conn.disconnect()
                        }
                    }
                    if (!nativeSuccess) {
                        android.util.Log.w("EmergencyForegroundService", "Despacho WhatsApp fallido tras respaldo. Último código: $code $resText")
                    }
                } catch (waErr: Exception) {
                    android.util.Log.e("EmergencyForegroundService", "Edge WhatsApp error: ${waErr.message}", waErr)
                }

                // 4. Registrar reporte en Supabase
                val df = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                    timeZone = TimeZone.getTimeZone("UTC")
                }
                val nowUtcIso = df.format(Date())

                try {
                    val supabaseUrl = URL("https://emtzprcntefzkvvzmhfk.supabase.co/rest/v1/reporte")
                    val sConn = supabaseUrl.openConnection() as HttpURLConnection
                    sConn.requestMethod = "POST"
                    sConn.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                    sConn.setRequestProperty("apikey", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVtdHpwcmNudGVmemt2dnptaGZrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA3ODIxNzIsImV4cCI6MjEwNjM1ODE3Mn0.x18Bh68n4ZgtNOyVPwIc01V6aL50oUaXjeXELzlWEh4")
                    sConn.setRequestProperty("Authorization", "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVtdHpwcmNudGVmemt2dnptaGZrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA3ODIxNzIsImV4cCI6MjEwNjM1ODE3Mn0.x18Bh68n4ZgtNOyVPwIc01V6aL50oUaXjeXELzlWEh4")
                    sConn.setRequestProperty("Prefer", "return=representation")
                    sConn.connectTimeout = 10000
                    sConn.readTimeout = 10000
                    sConn.doOutput = true

                    val sBody = JSONObject().apply {
                        put("id_persona", idPersona)
                        put("id_tipo", if (alertType == "ACCIDENTE") 2 else 1)
                        put("id_estado", 1)
                        put("fecha_hora", nowUtcIso)
                        put("descripcion", message)
                        put("direccion_texto", realAddress)
                    }
                    val sBytes = sBody.toString().toByteArray(Charsets.UTF_8)
                    sConn.setFixedLengthStreamingMode(sBytes.size)
                    sConn.outputStream.use { os ->
                        os.write(sBytes)
                        os.flush()
                    }
                    val sCode = sConn.responseCode
                    val sResText = if (sCode in 200..299) {
                        sConn.inputStream.bufferedReader().use { it.readText() }
                    } else {
                        sConn.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
                    }
                    android.util.Log.d("EmergencyForegroundService", "Supabase Response ($sCode): $sResText")
                    if (sCode in 200..299) {
                        nativeSuccess = true
                        try {
                            val jsonArr = org.json.JSONArray(sResText)
                            if (jsonArr.length() > 0) {
                                createdReportId = jsonArr.getJSONObject(0).optLong("id_reporte")
                                activeEmergencyReportId = createdReportId
                                // Inserción inmediata del punto inicial en la tabla 'ubicacion' de Supabase
                                sendNativeLocationPointToSupabase(createdReportId!!, lat, lon)
                            }
                        } catch (_: Exception) {}
                    }
                    sConn.disconnect()
                } catch (sErr: Exception) {
                    android.util.Log.e("EmergencyForegroundService", "Supabase error: ${sErr.message}", sErr)
                }

                // 5. Guardar inmediatamente en la caché local de reportes de Flutter (local_saved_reports_v2)
                try {
                    val rawJson = prefs.getString("flutter.local_saved_reports_v2", null)
                    val localArray = if (rawJson != null && rawJson.isNotEmpty()) {
                        try { org.json.JSONArray(rawJson) } catch (_: Exception) { org.json.JSONArray() }
                    } else {
                        org.json.JSONArray()
                    }

                    val reportRecord = JSONObject().apply {
                        put("id_reporte", createdReportId ?: System.currentTimeMillis())
                        put("id_tipo", if (alertType == "ACCIDENTE") 2 else 1)
                        put("tipo_incidencia", JSONObject().apply {
                            put("nombre", alertType)
                        })
                        put("id_estado", 1)
                        put("estado_reporte", JSONObject().apply {
                            put("nombre", "Enviado")
                        })
                        put("fecha_hora", nowUtcIso)
                        put("descripcion", message)
                        put("direccion_texto", realAddress)
                        put("fotos", org.json.JSONArray())
                        put("latitud", lat)
                        put("longitud", lon)
                        put("is_synced", true)
                    }

                    val newLocalArray = org.json.JSONArray()
                    newLocalArray.put(reportRecord)
                    for (i in 0 until localArray.length()) {
                        newLocalArray.put(localArray.get(i))
                    }
                    prefs.edit()
                        .putString("flutter.local_saved_reports_v2", newLocalArray.toString())
                        .apply()
                } catch (_: Exception) {}

                // 6. Actualizar flags de despacho y éxito
                isEmergencyDispatched = true
                isEmergencyActive = false
                prefs.edit()
                    .putBoolean("flutter.pending_emergency_dispatched", true)
                    .putBoolean("flutter.pending_emergency_active", false)
                    .putBoolean("flutter.native_dispatched_success", nativeSuccess)
                    .putString("flutter.last_dispatched_alert_type", alertType)
                    .putString("flutter.last_dispatched_source", source)
                    .putLong("flutter.last_dispatched_time", System.currentTimeMillis())
                    .apply()

                // 7. Activar rastreo en vivo si es ROBO
                if (alertType == "ROBO") {
                    isLiveTrackingActive = true
                    startNativeLiveTrackingLoop()
                    val notif = buildCurrentNotification()
                    val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                    manager?.notify(NOTIFICATION_ID, notif)
                }

                // 8. Vibración de confirmación
                val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    vibrator?.vibrate(VibrationEffect.createOneShot(500, VibrationEffect.DEFAULT_AMPLITUDE))
                } else {
                    @Suppress("DEPRECATION")
                    vibrator?.vibrate(500)
                }

                // 9. Actualizar notificación permanente de alarma a despachado
                showDispatchedNotification(alertType)

                // 10. Si MainActivity está abierta o se abre, informarle el ID OFICIAL del reporte
                //     para que el rastreo en vivo use el MISMO id_reporte (evita traza partida).
                MainActivity.instance?.runOnUiThread {
                    MainActivity.instance?.onEmergencyDispatchedFromNative(alertType, source, nativeSuccess, createdReportId)
                }
            } catch (fatal: Exception) {
                android.util.Log.e("EmergencyForegroundService", "Fatal error in dispatch: ${fatal.message}", fatal)
            }
        }.start()
    }

    private fun showDispatchedNotification(alertType: String) {
        val appIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val appPendingIntent = PendingIntent.getActivity(
            this,
            1005,
            appIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val smallIcon = applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.ic_lock_idle_alarm
        val notification = NotificationCompat.Builder(this, EMERGENCY_ALARM_CHANNEL_ID)
            .setSmallIcon(smallIcon)
            .setContentTitle("✅ ALERTA DE $alertType ENVIADA A LA CENTRAL")
            .setContentText("Ubicación GPS transmitida con éxito. Toca para ver en la app.")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setContentIntent(appPendingIntent)
            .setAutoCancel(true)
            .build()

        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        notificationManager?.notify(PANIC_NOTIFICATION_ID, notification)
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (!isUserLoggedIn(applicationContext)) {
            super.onTaskRemoved(rootIntent)
            return
        }
        // Reactivar protección: el servicio debe continuar vigilando sensor/botón aunque
        // el usuario cierre (swipe away) la app. Re-lanzar como foreground service.
        val restartIntent = Intent(applicationContext, EmergencyForegroundService::class.java).apply {
            setPackage(packageName)
            action = ACTION_START_GUARD
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                applicationContext.startForegroundService(restartIntent)
            } else {
                applicationContext.startService(restartIntent)
            }
        } catch (_: Exception) {
            // Fallback: intentar con PendingIntent (más robusto en algunos OEMs)
            try {
                val pi = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    PendingIntent.getForegroundService(
                        applicationContext,
                        101,
                        restartIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                } else {
                    PendingIntent.getService(
                        applicationContext,
                        101,
                        restartIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                    )
                }
                val am = getSystemService(Context.ALARM_SERVICE) as? AlarmManager
                am?.set(
                    AlarmManager.ELAPSED_REALTIME,
                    SystemClock.elapsedRealtime() + 800,
                    pi
                )
            } catch (_: Exception) {}
        }
        super.onTaskRemoved(rootIntent)
    }

    private fun sendNativeLocationPointToSupabase(reportId: Long, lat: Double, lon: Double) {
        Thread {
            try {
                val df = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                    timeZone = TimeZone.getTimeZone("UTC")
                }
                val nowUtcIso = df.format(Date())

                val supabaseUrl = URL("https://emtzprcntefzkvvzmhfk.supabase.co/rest/v1/ubicacion")
                val conn = supabaseUrl.openConnection() as HttpURLConnection
                conn.requestMethod = "POST"
                conn.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                conn.setRequestProperty("apikey", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVtdHpwcmNudGVmemt2dnptaGZrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA3ODIxNzIsImV4cCI6MjEwNjM1ODE3Mn0.x18Bh68n4ZgtNOyVPwIc01V6aL50oUaXjeXELzlWEh4")
                conn.setRequestProperty("Authorization", "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVtdHpwcmNudGVmemt2dnptaGZrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA3ODIxNzIsImV4cCI6MjEwNjM1ODE3Mn0.x18Bh68n4ZgtNOyVPwIc01V6aL50oUaXjeXELzlWEh4")
                conn.connectTimeout = 6000
                conn.readTimeout = 6000
                conn.doOutput = true

                val sBody = JSONObject().apply {
                    put("id_reporte", reportId)
                    put("latitud", lat)
                    put("longitud", lon)
                    put("fecha_hora", nowUtcIso)
                }
                val sBytes = sBody.toString().toByteArray(Charsets.UTF_8)
                conn.setFixedLengthStreamingMode(sBytes.size)
                conn.outputStream.use { os ->
                    os.write(sBytes)
                    os.flush()
                }
                val code = conn.responseCode
                android.util.Log.d("EmergencyForegroundService", "🛰️ Punto de rastreo en vivo transmitido nativo a Supabase ($code): Lat $lat, Lon $lon")
                conn.disconnect()
            } catch (e: Exception) {
                android.util.Log.e("EmergencyForegroundService", "Error enviando punto nativo a Supabase: ${e.message}")
            }
        }.start()
    }

    private fun patchNativeReportLocationIfBetter(reportId: Long, loc: Location) {
        if (hasCorrectedInitialReportLocation) return
        if (loc.accuracy > 45f) return
        hasCorrectedInitialReportLocation = true
        Thread {
            try {
                var updatedAddress = "Ubicación móvil GPS (±${String.format(Locale.US, "%.1f", loc.accuracy)}m)"
                try {
                    if (Geocoder.isPresent()) {
                        val geocoder = Geocoder(this, Locale("es", "PE"))
                        @Suppress("DEPRECATION")
                        val addresses = geocoder.getFromLocation(loc.latitude, loc.longitude, 1)
                        if (!addresses.isNullOrEmpty()) {
                            val addr = addresses[0]
                            val thoroughfare = addr.thoroughfare
                            val subThoroughfare = addr.subThoroughfare
                            val locality = addr.locality ?: addr.subAdminArea ?: "Pisco"
                            if (!thoroughfare.isNullOrBlank()) {
                                updatedAddress = if (!subThoroughfare.isNullOrBlank()) {
                                    "$thoroughfare $subThoroughfare, $locality (±${String.format(Locale.US, "%.1f", loc.accuracy)}m)"
                                } else {
                                    "$thoroughfare, $locality (±${String.format(Locale.US, "%.1f", loc.accuracy)}m)"
                                }
                            }
                        }
                    }
                } catch (_: Exception) {}

                val patchUrl = URL("https://emtzprcntefzkvvzmhfk.supabase.co/rest/v1/reporte?id_reporte=eq.$reportId")
                val conn = patchUrl.openConnection() as HttpURLConnection
                conn.requestMethod = "PATCH"
                conn.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                conn.setRequestProperty("apikey", "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVtdHpwcmNudGVmemt2dnptaGZrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA3ODIxNzIsImV4cCI6MjEwNjM1ODE3Mn0.x18Bh68n4ZgtNOyVPwIc01V6aL50oUaXjeXELzlWEh4")
                conn.setRequestProperty("Authorization", "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVtdHpwcmNudGVmemt2dnptaGZrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA3ODIxNzIsImV4cCI6MjEwNjM1ODE3Mn0.x18Bh68n4ZgtNOyVPwIc01V6aL50oUaXjeXELzlWEh4")
                conn.connectTimeout = 6000
                conn.readTimeout = 6000
                conn.doOutput = true

                val patchBody = JSONObject().apply {
                    put("latitud", loc.latitude)
                    put("longitud", loc.longitude)
                    put("direccion_texto", updatedAddress)
                }
                val patchBytes = patchBody.toString().toByteArray(Charsets.UTF_8)
                conn.setFixedLengthStreamingMode(patchBytes.size)
                conn.outputStream.use { os ->
                    os.write(patchBytes)
                    os.flush()
                }
                val patchCode = conn.responseCode
                android.util.Log.i("EmergencyForegroundService", "🎯 Reporte inicial corregido con fix satelital de alta precisión ($patchCode): Lat ${loc.latitude}, Lon ${loc.longitude}")
                conn.disconnect()

                // Enviar también como punto de rastreo a la tabla de ubicación
                sendNativeLocationPointToSupabase(reportId, loc.latitude, loc.longitude)
            } catch (e: Exception) {
                android.util.Log.e("EmergencyForegroundService", "Error actualizando reporte con fix satelital: ${e.message}")
            }
        }.start()
    }

    private fun startNativeLiveTrackingLoop() {
        stopNativeLiveTrackingLoop()
        acquireEmergencyWakeLock(120000L)
        liveTrackingHandler = android.os.Handler(Looper.getMainLooper())
        liveTrackingRunnable = object : Runnable {
            override fun run() {
                if (!isLiveTrackingActive) return
                acquireEmergencyWakeLock(60000L)
                val reportId = activeEmergencyReportId
                val loc = activeLocation
                if (reportId != null) {
                    val lat = if (loc != null && loc.accuracy <= 70f) loc.latitude else null
                    val lon = if (loc != null && loc.accuracy <= 70f) loc.longitude else null
                    if (lat != null && lon != null) {
                        sendNativeLocationPointToSupabase(reportId, lat, lon)
                    } else {
                        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                        val cachedLat = prefs.all["flutter.last_known_real_lat"]?.toString()?.toDoubleOrNull()
                        val cachedLon = prefs.all["flutter.last_known_real_lon"]?.toString()?.toDoubleOrNull()
                        if (cachedLat != null && cachedLon != null) {
                            sendNativeLocationPointToSupabase(reportId, cachedLat, cachedLon)
                        } else if (loc != null) {
                            sendNativeLocationPointToSupabase(reportId, loc.latitude, loc.longitude)
                        }
                    }
                }
                liveTrackingHandler?.postDelayed(this, 5000L)
            }
        }
        liveTrackingHandler?.postDelayed(liveTrackingRunnable!!, 3000L)
    }

    private fun stopNativeLiveTrackingLoop() {
        liveTrackingHandler?.removeCallbacksAndMessages(null)
        liveTrackingHandler = null
        liveTrackingRunnable = null
    }

    override fun onDestroy() {
        isServiceRunning = false
        stopNativeLiveTrackingLoop()
        releaseEmergencyWakeLock()
        screenReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (_: Exception) {}
        }
        screenReceiver = null
        unregisterSensorListener()
        unregisterLocationListener()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
