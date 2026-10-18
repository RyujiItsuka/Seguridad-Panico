import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';

import 'hardware_trigger_service.dart';

/// Visor de estado del Rastreo GPS en Vivo.
///
/// IMPORTANTE: el despacho y la TRANSMISIÓN de puntos a Supabase los realiza
/// ÚNICAMENTE el servicio nativo `EmergencyForegroundService` (Kotlin). Este
/// servicio en Dart NO publica coordenadas; solo refleja el estado del rastreo
/// para que la UI (banner de home) muestre que la transmisión está activa y
/// permita detenerla.
///
/// Esto elimina el bug anterior donde Flutter y el nativo publicaban puntos a
/// la vez con dos `id_reporte` distintos, partiendo la traza de la víctima.
class LocationTrackingService extends ChangeNotifier {
  static final LocationTrackingService _instance = LocationTrackingService._internal();
  factory LocationTrackingService() => _instance;
  LocationTrackingService._internal();

  String? _activeAlertId;
  bool _isTracking = false;
  double? _currentLat;
  double? _currentLon;

  bool get isTracking => _isTracking;
  String? get activeAlertId => _activeAlertId;
  double? get currentLat => _currentLat;
  double? get currentLon => _currentLon;

  /// Marca el rastreo como activo para una alerta ya despachada por el nativo.
  /// [alertId] debe ser el `id_reporte` OFICIAL devuelto por el servicio nativo.
  void startTracking({
    required String alertId,
    double? initialLat,
    double? initialLon,
  }) {
    _activeAlertId = alertId;
    _isTracking = true;
    _currentLat = initialLat;
    _currentLon = initialLon;

    // Notificar al servicio nativo para que muestre la notificación de rastreo
    HardwareTriggerService().updateLiveTrackingNotification(true);

    developer.log(
      '🚨 Rastreo GPS en vivo ACTIVO para ROBO (ID oficial: $alertId)',
      name: 'LocationTrackingService',
    );
    notifyListeners();
  }

  /// Actualiza el ID oficial de la alerta cuando el nativo confirma el `id_reporte`.
  void updateAlertId(String newAlertId) {
    if (_activeAlertId != newAlertId) {
      _activeAlertId = newAlertId;
      notifyListeners();
    }
  }

  /// Registra el último punto recibido (para mostrar en la UI). La transmisión
  /// a Supabase la hace el servicio nativo, no este método.
  void reportCurrentPoint(double lat, double lon) {
    _currentLat = lat;
    _currentLon = lon;
    notifyListeners();
  }

  /// Detiene el rastreo. El servicio nativo es quien envía el marcador de cierre
  /// (0,0) a Supabase y finaliza la transmisión en vivo de forma definitiva.
  Future<void> stopTracking() async {
    final wasTracking = _isTracking;
    _isTracking = false;
    _activeAlertId = null;
    _currentLat = null;
    _currentLon = null;
    notifyListeners();

    if (!wasTracking) return;

    developer.log('Deteniendo rastreo GPS en vivo vía servicio nativo', name: 'LocationTrackingService');

    // Restaurar notificación nativa a modo guardia y cancelar la emergencia activa.
    // El nativo se encarga de notificar a Supabase que el rastreo terminó.
    await HardwareTriggerService().updateLiveTrackingNotification(false);
    await HardwareTriggerService().cancelEmergency();
  }
}
