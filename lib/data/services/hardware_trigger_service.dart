import 'dart:developer' as developer;
import 'package:flutter/services.dart';
import '../../main.dart';
import '../../ui/features/emergency/emergency_countdown_dialog.dart';

typedef HardwareTriggerCallback = void Function(String source, [String? alertType]);
typedef EmergencyDispatchedCallback = void Function(String alertType, String source, bool nativeSuccess, int? reportId);
typedef StopTrackingDialogCallback = void Function();

/// Servicio que interactúa con la capa nativa de Android para:
/// 1. Recibir activación de emergencia por 3 pulsaciones del botón de encendido o impacto físico en segundo plano.
/// 2. Controlar el servicio en primer plano persistente en segundo plano (Foreground Service).
/// 3. Gestionar la notificación interactiva de rastreo en vivo y apertura de diálogo de PIN.
/// 4. Recuperar activaciones de emergencia ocurridas mientras la app estaba completamente cerrada (arranque en frío).
/// 5. Confirmar alertas enviadas automáticamente de forma autónoma por el Foreground Service cuando la app no estaba abierta.
class HardwareTriggerService {
  static final HardwareTriggerService _instance = HardwareTriggerService._internal();
  factory HardwareTriggerService() => _instance;
  HardwareTriggerService._internal();

  static const MethodChannel _channel = MethodChannel('com.alertaciudadana/hardware_trigger');

  HardwareTriggerCallback? _onHardwareTriggered;
  EmergencyDispatchedCallback? _onEmergencyDispatched;
  StopTrackingDialogCallback? _onOpenStopTrackingDialog;
  bool _initialized = false;

  void initialize({
    required HardwareTriggerCallback onTriggered,
    EmergencyDispatchedCallback? onEmergencyDispatched,
    StopTrackingDialogCallback? onOpenStopTrackingDialog,
  }) {
    _onHardwareTriggered = onTriggered;
    if (onEmergencyDispatched != null) {
      _onEmergencyDispatched = onEmergencyDispatched;
    }
    if (onOpenStopTrackingDialog != null) {
      _onOpenStopTrackingDialog = onOpenStopTrackingDialog;
    }

    if (_initialized) {
      // Si ya estaba inicializado pero se volvió a vincular la UI, revisar si hay disparos pendientes
      checkPendingTriggers();
      return;
    }
    _initialized = true;

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPanicTriggered':
          final Map? args = call.arguments as Map?;
          final String source = args?['source'] as String? ?? 'power_button_3x';
          final String? alertType = args?['alertType'] as String?;
          developer.log('🚨 DISPARO NATIVO DE EMERGENCIA: $source ($alertType)', name: 'HardwareTriggerService');
          if (_onHardwareTriggered != null) {
            _onHardwareTriggered?.call(source, alertType);
          } else if (appNavigatorKey.currentContext != null) {
            final type = alertType ?? 'ROBO';
            final label = source.contains('sensor')
                ? 'SENSOR ANTIRROBO (ARREBATO / FORCEJEO)'
                : 'BOTÓN FÍSICO (3+ PULSACIONES SEGUIDAS)';
            EmergencyCountdownDialog.show(
              appNavigatorKey.currentContext!,
              alertType: type,
              source: label,
              isDirectWhatsAppApi: true,
            );
          }
          break;

        case 'onEmergencyDispatched':
          final Map? args = call.arguments as Map?;
          final String source = args?['source'] as String? ?? 'power_button_3x';
          final String alertType = args?['alertType'] as String? ?? 'ROBO';
          final bool nativeSuccess = args?['nativeSuccess'] == true;
          final dynamic rawReportId = args?['reportId'];
          final int? reportId = (rawReportId is int) ? rawReportId : null;
          developer.log('✅ ALERTA CONFIRMADA DESPACHADA DESDE SEGUNDO PLANO: $alertType (nativoOk: $nativeSuccess, reporte: $reportId)', name: 'HardwareTriggerService');
          _onEmergencyDispatched?.call(alertType, source, nativeSuccess, reportId);
          break;

        case 'onOpenStopTrackingDialog':
          developer.log('🛑 SOLICITUD DESDE NOTIFICACIÓN: Abrir diálogo de PIN para detener rastreo', name: 'HardwareTriggerService');
          _onOpenStopTrackingDialog?.call();
          break;
      }
    });

    // Iniciar automáticamente el servicio persistente en Android
    startBackgroundService();
    developer.log('Canal de disparador por hardware y segundo plano inicializado', name: 'HardwareTriggerService');

    // Verificar si la app fue abierta debido a una emergencia pendiente (arranque desde app cerrada)
    checkPendingTriggers();
  }

  /// Cancela una emergencia activa en el servicio nativo de segundo plano
  Future<void> cancelEmergency() async {
    try {
      await _channel.invokeMethod('cancelEmergency');
    } catch (e) {
      developer.log('Error cancelando emergencia nativa: $e', name: 'HardwareTriggerService');
    }
  }

  /// Solicita al servicio nativo iniciar el flujo de emergencia COMPLETO
  /// (fijación GPS + cuenta regresiva de 5s + despacho + rastreo en vivo).
  ///
  /// Este es el punto de entrada ÚNICO para disparar alertas desde la UI.
  /// El servicio nativo es el único dueño del despacho, por lo que NO hay
  /// doble envío ni dos id_reporte distintos para la misma alerta.
  Future<void> startEmergencyFlow(String alertType, String source) async {
    try {
      await _channel.invokeMethod('startEmergencyFlow', {
        'alertType': alertType,
        'source': source,
      });
    } catch (e) {
      developer.log('Error iniciando flujo nativo de emergencia: $e', name: 'HardwareTriggerService');
    }
  }

  /// Salta la cuenta regresiva nativa y despacha la alerta de inmediato
  /// (botón "ENVIAR AHORA"). El nativo sigue siendo el único que envía.
  Future<void> dispatchNow() async {
    try {
      await _channel.invokeMethod('dispatchNow');
    } catch (e) {
      developer.log('Error solicitando despacho inmediato: $e', name: 'HardwareTriggerService');
    }
  }

  /// Limpia el estado de emergencia activo para permitir nuevas activaciones
  Future<void> resetEmergencyState() async {
    try {
      await _channel.invokeMethod('resetEmergencyState');
    } catch (e) {
      developer.log('Error reseteando estado de emergencia nativo: $e', name: 'HardwareTriggerService');
    }
  }

  /// Verifica si la actividad nativa fue despertada por una emergencia pendiente mientras Flutter cargaba
  Future<void> checkPendingTriggers() async {
    try {
      final Map? pending = await _channel.invokeMapMethod('checkPendingTrigger');
      if (pending != null && pending['hasPending'] == true) {
        final String source = pending['source'] as String? ?? 'power_button_3x';
        final String alertType = pending['alertType'] as String? ?? 'ROBO';
        final bool isDispatched = pending['isDispatched'] == true;
        final bool nativeSuccess = pending['nativeSuccess'] == true;

        if (isDispatched) {
          developer.log('🚨 ALERTA YA DESPACHADA EN SEGUNDO PLANO: $alertType ($source, nativoOk: $nativeSuccess)', name: 'HardwareTriggerService');
          Future.delayed(const Duration(milliseconds: 50), () {
            _onEmergencyDispatched?.call(alertType, source, nativeSuccess, null);
          });
        } else {
          developer.log('🚨 DISPARO PENDIENTE AL ABRIR LA APP: $source ($alertType)', name: 'HardwareTriggerService');
          // Delay mínimo de 50ms para asegurar el primer frame montado
          Future.delayed(const Duration(milliseconds: 50), () {
            _onHardwareTriggered?.call(source, alertType);
          });
        }
      }
    } catch (e) {
      developer.log('Error al verificar disparo pendiente: $e', name: 'HardwareTriggerService');
    }

    try {
      final bool? pendingStop = await _channel.invokeMethod<bool>('checkPendingStopTracking');
      if (pendingStop == true) {
        Future.delayed(const Duration(milliseconds: 350), () {
          _onOpenStopTrackingDialog?.call();
        });
      }
    } catch (_) {}
  }

  void setStopTrackingDialogCallback(StopTrackingDialogCallback callback) {
    _onOpenStopTrackingDialog = callback;
  }

  /// Inicia el servicio persistente en primer plano de Android
  Future<void> startBackgroundService() async {
    try {
      await _channel.invokeMethod('startBackgroundService');
    } catch (e) {
      developer.log('Plataforma no nativa Android o error al iniciar servicio: $e', name: 'HardwareTriggerService');
    }
  }

  /// Detiene el servicio persistente en Android
  Future<void> stopBackgroundService() async {
    try {
      await _channel.invokeMethod('stopBackgroundService');
    } catch (e) {
      developer.log('Error al detener servicio: $e', name: 'HardwareTriggerService');
    }
  }

  /// Actualiza la barra de notificaciones según si hay rastreo en vivo de ROBO activo
  Future<void> updateLiveTrackingNotification(bool isTracking) async {
    try {
      await _channel.invokeMethod('updateLiveTrackingNotification', {'isTracking': isTracking});
    } catch (e) {
      developer.log('Error al actualizar notificación de rastreo en vivo: $e', name: 'HardwareTriggerService');
    }
  }

  /// Permite simular las 3 pulsaciones del botón de encendido para pruebas rápidas
  Future<void> simulatePowerButtonTriplePress() async {
    try {
      await _channel.invokeMethod('simulatePowerPress3x');
    } catch (_) {
      // Fallback para entornos donde el canal nativo de Android no está presente (ej. Web)
      _onHardwareTriggered?.call('power_button_3x_simulado');
    }
  }
}
