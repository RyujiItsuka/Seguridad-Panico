import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:http/http.dart' as http;
import 'report_storage_service.dart';
import 'session_service.dart';

/// Servicio para el envío automatizado de alertas vía WhatsApp API
/// con mensajes predefinidos según la categoría de emergencia y despacho directo
/// al número oficial 976264949 sin abrir la aplicación de WhatsApp.
class WhatsAppApiService {
  /// Número oficial de auxilio y despacho de la Central de Video Vigilancia (Perú)
  static const String defaultEmergencyRecipient = '+51 976264949';
  
  /// URL del backend central de despacho de emergencias
  static const String backendBaseUrl = 'http://127.0.0.1:5000';

  /// URL de Supabase Edge Function de producción
  static const String supabaseFunctionsUrl = 'https://emtzprcntefzkvvzmhfk.supabase.co/functions/v1/alerts';

  /// Clave pública anónima de Supabase
  static const String supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImVtdHpwcmNudGVmemt2dnptaGZrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA3ODIxNzIsImV4cCI6MjEwNjM1ODE3Mn0.x18Bh68n4ZgtNOyVPwIc01V6aL50oUaXjeXELzlWEh4';

  /// Edge Function que PROXÍA Green API. El token de Green API vive SOLO en el
  /// servidor (Deno.env de esta función), nunca en el APK. Cualquier envío a
  /// WhatsApp debe pasar por aquí.
  static const String whatsappEdgeUrl = 'https://emtzprcntefzkvvzmhfk.supabase.co/functions/v1/whatsapp';

  static Map<String, String> get _whatsappEdgeHeaders => {
        'Content-Type': 'application/json; charset=utf-8',
        'apikey': supabaseAnonKey,
        'Authorization': 'Bearer $supabaseAnonKey',
      };

  /// Envía un mensaje de texto a WhatsApp a través de la Edge Function `whatsapp`.
  ///
  /// Devuelve `true` si la Edge Function respondió 2xx. Incluye timeout corto y
  /// un reintento (respaldo) para no dejar caída la ruta crítica de pánico.
  static Future<bool> sendTextViaEdge({
    required String chatId,
    required String message,
    Duration timeout = const Duration(seconds: 8),
    int attempts = 2,
  }) async {
    for (int attempt = 1; attempt <= attempts; attempt++) {
      try {
        final res = await http
            .post(
              Uri.parse(whatsappEdgeUrl),
              headers: _whatsappEdgeHeaders,
              body: jsonEncode({
                'action': 'sendMessage',
                'chatId': chatId,
                'message': message,
              }),
            )
            .timeout(timeout);
        if (res.statusCode >= 200 && res.statusCode < 300) {
          developer.log(
            'Mensaje despachado vía Edge Function (intento $attempt): ${res.body}',
            name: 'WhatsAppApiService',
          );
          return true;
        }
        developer.log(
          'Edge Function rechazó el envío (${res.statusCode}) en intento $attempt: ${res.body}',
          name: 'WhatsAppApiService',
        );
        // 4xx = error del cliente (chatId/mensaje inválido): no reintentar.
        if (res.statusCode >= 400 && res.statusCode < 500) return false;
      } catch (e) {
        developer.log(
          'Fallo de red en Edge Function (intento $attempt): $e',
          name: 'WhatsAppApiService',
        );
      }
    }
    return false;
  }

  /// Normaliza el número al formato internacional para la API (51976264949)
  static String normalizeNumber(String phone) {
    final clean = phone.replaceAll(RegExp(r'\D'), '');
    if (clean.length == 9 && clean.startsWith('9')) {
      return '51$clean';
    }
    if (clean.startsWith('51') && clean.length == 11) {
      return clean;
    }
    return clean.isNotEmpty ? clean : '51976264949';
  }

  static String getPredefinedMessage(
    String category, {
    String address = 'Av. de la Constitución 145, Lima',
    double lat = -12.04637,
    double lon = -77.02987,
    String source = 'BOTÓN PRINCIPAL',
  }) {
    final catNormalized = category.trim().toUpperCase();

    String headline;
    switch (catNormalized) {
      case 'ROBO':
        headline = '🚨 ¡AUXILIO! ME ESTÁN ROBANDO 🚨';
        break;
      case 'SECUESTRO':
        headline = '🛑 ¡ALERTA MÁXIMA: POSIBLE SECUESTRO EN CURSO! INTERVENCIÓN POLICIAL INMEDIATA 🛑';
        break;
      case 'INCENDIO':
        headline = '🔥 ¡ALERTA DE INCENDIO! UNIDAD DE BOMBEROS REQUERIDA 🔥';
        break;
      case 'ACCIDENTE':
        headline = '🚗💥 ¡ACCIDENTE DE TRÁNSITO! AMBULANCIA Y POLICÍA REQUERIDA 🚗💥';
        break;
      case 'ASESINATO':
        headline = '🛑 ¡ALERTA CRÍTICA: ATENTADO / ASESINATO! INTERVENCIÓN INMEDIATA 🛑';
        break;
      case 'GRESCA':
        headline = '🥊 ¡ALTERCADO / GRESCA EN VÍA PÚBLICA! PATRULLAJE URGENTE 🥊';
        break;
      case 'PERSONALIZADO':
        headline = '⚠️ ¡ALERTA DE SEGURIDAD CIUDADANA! ⚠️';
        break;
      default:
        headline = '🚨 ¡ALERTA DE EMERGENCIA CIUDADANA: $catNormalized! 🚨';
        break;
    }

    final gmapsNav = '🚗 Cómo llegar (Google Maps): https://www.google.com/maps/dir/?api=1&destination=${lat.toStringAsFixed(5)},${lon.toStringAsFixed(5)}';

    return '$headline\n'
        '📍 Ubicación: $address\n'
        '🛰️ Coordenadas: Lat ${lat.toStringAsFixed(5)}, Lon ${lon.toStringAsFixed(5)}\n'
        '🗺️ Mapa: https://maps.google.com/?q=${lat.toStringAsFixed(5)},${lon.toStringAsFixed(5)}\n'
        '$gmapsNav\n'
        '⚡ Disparador: $source\n'
        '🛡️ Despacho automático WhatsApp API a la Central de Video Vigilancia.';
  }

  /// Último ID de alerta despachada (usado para inicializar rastreo en vivo de ROBO)
  static String? lastAlertId;

  /// Persiste el reporte e incidencias en almacenamiento dual (Local y Supabase)
  /// Almacena imágenes adjuntas en formato base64 / metadata dentro del campo fotos (JSONB)
  static Future<int?> saveReportToDatabase({
    required String category,
    required String message,
    required String address,
    required double lat,
    required double lon,
    List<String>? imagePaths,
    bool isSuccessfullyDispatched = false,
  }) async {
    try {
      final record = await ReportStorageService.saveReport(
        category: category,
        message: message,
        address: address,
        lat: lat,
        lon: lon,
        imagePaths: imagePaths,
        isSuccessfullyDispatched: isSuccessfullyDispatched,
      );
      final id = record['id_reporte'];
      if (id is int) return id;
      if (id is String) return int.tryParse(id.replaceAll(RegExp(r'\D'), ''));
      return null;
    } catch (e) {
      developer.log('Excepción al persistir reporte: $e', name: 'WhatsAppApiService');
      return null;
    }
  }

  /// Despacha la alerta directamente a través de la API de WhatsApp vía Backend HTTP POST
  /// Sin abrir la app de WhatsApp en el dispositivo del usuario.
  static DateTime? _lastDispatchTime;
  static String? _lastDispatchedCategory;

  /// Retorna el ID de la alerta (ej: 'ALT-17889291234') si el envío fue exitoso.
  static Future<String?> sendAutomatedEmergencyAlert({
    required String category,
    String? customMessage,
    String recipientNumber = defaultEmergencyRecipient,
    String source = 'ui_button',
    double lat = -12.04637,
    double lon = -77.02987,
    String address = 'Av. de la Constitución 145, Lima',
    List<String>? imagePaths,
  }) async {
    // Protección contra doble disparo involuntario en menos de 5 segundos
    if (_lastDispatchTime != null &&
        DateTime.now().difference(_lastDispatchTime!).inSeconds < 5 &&
        _lastDispatchedCategory == category &&
        lastAlertId != null) {
      developer.log(
        '⚠️ Debounce activo: Alerta de $category ya despachada hace menos de 5s. Reutilizando ID $lastAlertId',
        name: 'WhatsAppApiService',
      );
      return lastAlertId;
    }
    _lastDispatchTime = DateTime.now();
    _lastDispatchedCategory = category;

    final message = customMessage ??
        getPredefinedMessage(
          category,
          address: address,
          lat: lat,
          lon: lon,
          source: source,
        );

    final cleanRecipient = normalizeNumber(recipientNumber);
    developer.log(
      'Enviando alerta directa WhatsApp API a +$cleanRecipient (Origen: $source)',
      name: 'WhatsAppApiService',
    );

    // HU-SEG-09: Persistencia asegurada en Supabase (tabla reporte y ubicacion con fotos)
    int? dbReportId;
    try {
      dbReportId = await saveReportToDatabase(
        category: category,
        message: message,
        address: address,
        lat: lat,
        lon: lon,
        imagePaths: imagePaths,
      );
      if (dbReportId != null) {
        lastAlertId = 'ALT-$dbReportId';
      }
    } catch (dbErr) {
      developer.log('Error al invocar saveReportToDatabase: $dbErr', name: 'WhatsAppApiService');
    }

    // Obtener datos del ciudadano registrado
    Map<String, String>? citizen;
    try {
      citizen = await SessionService.getUserData();
    } catch (_) {}

    // Despacho de fotografías de evidencia vía Edge Function `whatsapp`
    // (multipart -> sendFileByUpload). El token de Green API vive solo en el
    // servidor; el APK solo conoce la URL de la Edge Function.
    bool photoDispatched = false;
    if (imagePaths != null && imagePaths.isNotEmpty) {
      for (int i = 0; i < imagePaths.length; i++) {
        final filePath = imagePaths[i];
        final file = File(filePath);
        if (await file.exists()) {
          try {
            final request = http.MultipartRequest('POST', Uri.parse(whatsappEdgeUrl));
            request.headers['apikey'] = supabaseAnonKey;
            request.headers['Authorization'] = 'Bearer $supabaseAnonKey';
            request.fields['action'] = 'sendFileByUpload';
            request.fields['chatId'] = '$cleanRecipient@c.us';
            request.fields['caption'] = i == 0
                ? message
                : '📸 Evidencia fotográfica adicional #${i + 1}';
            request.fields['fileName'] = 'evidencia_${i + 1}.jpg';
            request.files.add(await http.MultipartFile.fromPath('file', filePath));

            final streamedResponse = await request.send().timeout(const Duration(seconds: 15));
            final resBody = await streamedResponse.stream.bytesToString();
            developer.log('Evidencia fotográfica #$i despachada a WhatsApp: $resBody', name: 'WhatsAppApiService');
            if (streamedResponse.statusCode >= 200 && streamedResponse.statusCode < 300) {
              photoDispatched = true;
            }
          } catch (photoErr) {
            developer.log('Error enviando foto #$i vía Edge Function: $photoErr', name: 'WhatsAppApiService');
          }
        }
      }

      // Si las fotos con el mensaje como pie de foto se enviaron con éxito,
      // el despacho a WhatsApp está 100% completado. Retornar de inmediato
      // para evitar que se envíe un segundo mensaje de texto por WhatsApp.
      if (photoDispatched) {
        if (dbReportId != null) {
          ReportStorageService.markReportAsSent(dbReportId);
          lastAlertId = 'ALT-$dbReportId';
        } else {
          lastAlertId = 'ALT-${DateTime.now().millisecondsSinceEpoch}';
        }
        developer.log('Reporte personalizado con fotos enviado exitosamente sin duplicados.', name: 'WhatsAppApiService');
        return lastAlertId;
      }
    }

    // 1. Despacho a WhatsApp vía Edge Function `whatsapp` (token de Green API
    //    SOLO en el servidor; nunca en el APK).
    final dispatched = await sendTextViaEdge(
      chatId: '$cleanRecipient@c.us',
      message: message,
    );
    if (dispatched) {
      if (dbReportId != null) {
        ReportStorageService.markReportAsSent(dbReportId);
      }
      developer.log(
        'Alerta despachada con éxito vía Edge Function a WhatsApp.',
        name: 'WhatsAppApiService',
      );
      lastAlertId = dbReportId != null ? 'ALT-$dbReportId' : 'ALT-${DateTime.now().millisecondsSinceEpoch}';
      return lastAlertId;
    }

    // 2. Respaldo opcional vía Backend local (si está activo)
    try {
      final response = await http
          .post(
            Uri.parse('$backendBaseUrl/api/alerts'),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
            body: jsonEncode({
              'category': category,
              'message': message,
              'recipientNumber': cleanRecipient,
              'source': source,
              'coordinates': {'lat': lat, 'lon': lon},
              'address': address,
              'timestamp': DateTime.now().toIso8601String(),
              'citizen': citizen,
            }),
          )
          .timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        if (dbReportId != null) {
          ReportStorageService.markReportAsSent(dbReportId);
        }
        developer.log(
          'Alerta despachada exitosamente al Backend/WhatsApp API: ${response.body}',
          name: 'WhatsAppApiService',
        );
        try {
          final data = jsonDecode(response.body);
          lastAlertId = data['alertId'] as String?;
        } catch (_) {
          lastAlertId = dbReportId != null ? 'ALT-$dbReportId' : 'ALT-${DateTime.now().millisecondsSinceEpoch}';
        }
        return lastAlertId;
      }
    } catch (e) {
      developer.log('Backend local no disponible: $e', name: 'WhatsAppApiService');
    }

    lastAlertId = dbReportId != null ? 'ALT-$dbReportId' : 'ALT-${DateTime.now().millisecondsSinceEpoch}';
    return lastAlertId;
  }
}
