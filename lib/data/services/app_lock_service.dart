import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'session_service.dart';

/// Servicio central para el bloqueo de seguridad por inactividad / segundo plano.
/// Mantiene la sesión del ciudadano siempre abierta (token, datos y monitoreo activos),
/// pero bloquea visualmente la interfaz exigiendo huella digital o PIN secreto de 4 dígitos:
/// 1. Cuando transcurre 1 minuto de inactividad con la app abierta en primer plano.
/// 2. Cuando la app permanece más de 30 segundos en segundo plano (sin cerrar por completo).
class AppLockService {
  static final AppLockService _instance = AppLockService._internal();
  factory AppLockService() => _instance;
  AppLockService._internal();

  /// Tiempo máximo de inactividad con la app abierta antes de bloquear (1 minuto)
  static const Duration inactivityTimeout = Duration(minutes: 1);

  /// Tiempo mínimo en segundo plano antes de exigir PIN al regresar (30 segundos)
  static const Duration backgroundLockThreshold = Duration(seconds: 30);

  /// Notificador observable para determinar si la aplicación está bloqueada
  final ValueNotifier<bool> isLockedNotifier = ValueNotifier<bool>(false);

  bool get isLocked => isLockedNotifier.value;

  /// Bandera para evitar que el diálogo nativo biométrico del sistema
  /// (que produce eventos pause/resume transitorios en Android) provoque un bucle de bloqueo.
  bool isAuthenticatingBiometrics = false;

  /// Bandera para evitar que los diálogos de permisos del sistema operativo (GPS, cámara, etc.)
  /// provoquen un bloqueo transitorio indeseado.
  bool isSystemDialogActive = false;

  /// Bandera para evitar bloquear la app en el instante en que el usuario
  /// acaba de iniciar sesión o registrarse desde LoginView.
  bool justLoggedIn = false;

  /// Bandera de período de gracia (4s) para evitar que el cierre del diálogo
  /// de huella digital de Android vuelva a bloquear la app inmediatamente.
  bool justUnlocked = false;

  DateTime? _pausedAt;
  Timer? _inactivityTimer;
  bool _isLoggedIn = false;

  /// Inicializa el estado de bloqueo al encender la app (cold start)
  Future<void> initOnLaunch({required bool isLoggedIn}) async {
    _isLoggedIn = isLoggedIn;
    if (isLoggedIn) {
      developer.log('App iniciada con sesión activa previa: activando pantalla de bloqueo.', name: 'AppLockService');
      isLockedNotifier.value = true;
    } else {
      isLockedNotifier.value = false;
      _cancelInactivityTimer();
    }
  }

  /// Registra cualquier toque o interacción del usuario en la pantalla
  /// para reiniciar el temporizador de inactividad de 1 minuto.
  void recordUserActivity() {
    if (isLocked) return;
    if (!_isLoggedIn) return;
    if (_pausedAt != null) return;
    _resetInactivityTimer();
  }

  /// Reinicia el contador de inactividad a 1 minuto
  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    if (isLocked || !_isLoggedIn) return;

    _inactivityTimer = Timer(inactivityTimeout, () {
      _onInactivityTimeout();
    });
  }

  /// Cancela el contador de inactividad
  void _cancelInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
  }

  /// Se ejecuta cuando transcurre 1 minuto completo sin interacción en pantalla
  void _onInactivityTimeout() {
    if (isLocked) return;
    if (!_isLoggedIn) return;
    if (_pausedAt != null) return;

    developer.log('⏳ 1 minuto de inactividad alcanzado: bloqueando aplicación por seguridad', name: 'AppLockService');
    lock();
  }

  /// Fuerza el bloqueo de seguridad de la app
  void lock() {
    _cancelInactivityTimer();
    isLockedNotifier.value = true;
  }

  /// Desbloquea la interfaz tras validación exitosa de huella o PIN
  void unlock() {
    developer.log('Desbloqueo de seguridad completado exitosamente', name: 'AppLockService');
    isLockedNotifier.value = false;
    _pausedAt = null;
    justUnlocked = true;
    _resetInactivityTimer();
    Future.delayed(const Duration(seconds: 4), () {
      justUnlocked = false;
    });
  }

  /// Marca que el usuario acaba de iniciar sesión con credenciales
  void markJustLoggedIn() {
    _isLoggedIn = true;
    justLoggedIn = true;
    isLockedNotifier.value = false;
    _pausedAt = null;
    _resetInactivityTimer();
    Future.delayed(const Duration(seconds: 4), () {
      justLoggedIn = false;
    });
  }

  /// Se ejecuta cuando la aplicación pasa a segundo plano o se bloquea la pantalla
  void onAppPaused() {
    if (isAuthenticatingBiometrics || isSystemDialogActive) return;
    if (justUnlocked) return;
    _cancelInactivityTimer();
    _pausedAt = DateTime.now();
    developer.log('App en segundo plano a las $_pausedAt. Temporizador de 30s en curso.', name: 'AppLockService');
  }

  /// Se ejecuta cuando la aplicación regresa a primer plano
  Future<void> onAppResumed() async {
    if (isAuthenticatingBiometrics || isSystemDialogActive) return;
    if (justLoggedIn) return;
    if (justUnlocked) {
      _pausedAt = null;
      _resetInactivityTimer();
      return;
    }

    final loggedIn = await SessionService.isLoggedIn();
    _isLoggedIn = loggedIn;
    if (!loggedIn) {
      isLockedNotifier.value = false;
      _cancelInactivityTimer();
      return;
    }

    // Si la sesión fue revocada en el servidor (robo o exposición de tokens),
    // cerrar la sesión local y no exigir PIN: el usuario debe volver a entrar.
    if (!await SessionService.isSessionValidOnServer()) {
      isLockedNotifier.value = false;
      _cancelInactivityTimer();
      _isLoggedIn = false;
      return;
    }

    if (_pausedAt != null) {
      final elapsed = DateTime.now().difference(_pausedAt!);
      developer.log('App reanudada tras ${elapsed.inSeconds}s en segundo plano (umbral: ${backgroundLockThreshold.inSeconds}s)', name: 'AppLockService');

      // Si la app estuvo en segundo plano 30 segundos o más, exigir PIN / Huella
      if (elapsed >= backgroundLockThreshold) {
        developer.log('🔒 Umbral de 30 segundos en segundo plano alcanzado: activando pantalla de bloqueo.', name: 'AppLockService');
        lock();
      } else {
        developer.log('✅ Regreso en menos de 30 segundos: manteniendo pantalla sin bloquear.', name: 'AppLockService');
        _resetInactivityTimer();
      }
    } else {
      _resetInactivityTimer();
    }
    _pausedAt = null;
  }

  /// Desactiva el bloqueo si se cierra la sesión intencionalmente
  void onLogout() {
    _isLoggedIn = false;
    _cancelInactivityTimer();
    isLockedNotifier.value = false;
    justLoggedIn = false;
    justUnlocked = false;
    _pausedAt = null;
  }
}
