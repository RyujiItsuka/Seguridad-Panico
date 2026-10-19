import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/theme/app_theme.dart';
import 'app_lock_service.dart';

/// Servicio para obtención de ubicación GPS exacta en tiempo real del dispositivo
class GpsLocationService {
  /// Obtiene la posición GPS exacta del dispositivo con manejo de permisos y alta precisión satelital
  static Future<Position?> getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    try {
      // 1. Verificar si los servicios de ubicación del sistema están activados
      serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        developer.log('Servicios de ubicación desactivados en el teléfono', name: 'GpsLocationService');
        return await _getFilteredLastKnown();
      }

      // 2. Verificar permisos de acceso a la ubicación
      permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          developer.log('Permisos de GPS denegados por el usuario', name: 'GpsLocationService');
          return await _getFilteredLastKnown();
        }
      }

      if (permission == LocationPermission.deniedForever) {
        developer.log('Permisos de GPS denegados permanentemente', name: 'GpsLocationService');
        return await _getFilteredLastKnown();
      }

      // 3. Revisar si la última posición en caché es ULTRA reciente (menor a 25s) y de gran precisión (< 15m)
      final quickPos = await Geolocator.getLastKnownPosition();
      if (quickPos != null) {
        final age = DateTime.now().difference(quickPos.timestamp);
        if (age.inSeconds < 25 && quickPos.accuracy <= 15.0) {
          developer.log('✅ Usando posición reciente de alta fidelidad (±${quickPos.accuracy}m)', name: 'GpsLocationService');
          _savePositionToCache(quickPos);
          return quickPos;
        }
      }

      // 4. Solicitar posición GPS satelital con máxima precisión (bestForNavigation) y 10s de ventana de fijación
      final locationSettings = defaultTargetPlatform == TargetPlatform.android
          ? AndroidSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              distanceFilter: 0,
              forceLocationManager: false,
              intervalDuration: const Duration(milliseconds: 500),
              timeLimit: const Duration(seconds: 10),
            )
          : const LocationSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              timeLimit: Duration(seconds: 10),
            );

      try {
        final position = await Geolocator.getCurrentPosition(locationSettings: locationSettings);
        developer.log('🛰️ GPS satelital fijado con éxito: Lat ${position.latitude}, Lon ${position.longitude}, Margen ±${position.accuracy}m', name: 'GpsLocationService');
        _savePositionToCache(position);
        return position;
      } catch (e) {
        developer.log('Reintentando con sensor de hardware GPS directo (forceLocationManager=true): $e', name: 'GpsLocationService');
        if (defaultTargetPlatform == TargetPlatform.android) {
          final hwSettings = AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
            forceLocationManager: true,
            timeLimit: const Duration(seconds: 8),
          );
          final hwPos = await Geolocator.getCurrentPosition(locationSettings: hwSettings);
          _savePositionToCache(hwPos);
          return hwPos;
        }
        rethrow;
      }
    } catch (e) {
      developer.log('Error obteniendo posición GPS en tiempo real: $e', name: 'GpsLocationService');
      return await _getFilteredLastKnown();
    }
  }

  static void _savePositionToCache(Position pos) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_known_real_lat', pos.latitude.toString());
      await prefs.setString('last_known_real_lon', pos.longitude.toString());
      await prefs.setInt('last_known_real_time', DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  /// Recupera la última posición real persistida en SharedPreferences
  static Future<Map<String, dynamic>?> getCachedRealCoordinates() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final latStr = prefs.getString('last_known_real_lat');
      final lonStr = prefs.getString('last_known_real_lon');
      final addr = prefs.getString('last_known_real_address');
      if (latStr != null && lonStr != null) {
        final lat = double.tryParse(latStr);
        final lon = double.tryParse(lonStr);
        if (lat != null && lon != null) {
          return {
            'lat': lat,
            'lon': lon,
            'address': addr ?? 'Ubicación móvil GPS previa',
          };
        }
      }
    } catch (_) {}
    return null;
  }

  /// Retorna la última posición en memoria como último recurso.
  ///
  /// BUG QUE CORRIGE: antes devolvía `getLastKnownPosition()` sin ningún filtro,
  /// por lo que podía retornar un fix de horas de antigüedad o un fix de red
  /// (torre celular) con precisión de kilómetros, que luego se usaba como si
  /// fuera la ubicación real de la víctima.
  static Future<Position?> _getFilteredLastKnown() async {
    try {
      final pos = await Geolocator.getLastKnownPosition();
      if (pos == null) return null;

      final age = DateTime.now().difference(pos.timestamp);

      // Descartar posiciones viejas (> 3 minutos) o imprecisas (> 200m, típico de red/celda).
      if (age.inMinutes > 3) {
        developer.log('Descartando posición en caché vieja (${age.inSeconds}s)', name: 'GpsLocationService');
        return null;
      }
      if (pos.hasAccuracy && pos.accuracy > 200) {
        developer.log('Descartando posición en caché imprecisa (±${pos.accuracy}m, probable torre celular)', name: 'GpsLocationService');
        return null;
      }

      developer.log('Usando última posición conocida filtrada (±${pos.accuracy}m, ${age.inSeconds}s)', name: 'GpsLocationService');
      _savePositionToCache(pos);
      return pos;
    } catch (_) {
      return null;
    }
  }

  /// Geocodificación inversa para obtener el nombre real de la calle/distrito
  static Future<String?> getAddressFromCoordinates(double lat, double lon) async {
    try {
      final url = Uri.parse('https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lon&zoom=18&addressdetails=1');
      final response = await http.get(url, headers: {
        'User-Agent': 'AlertaCiudadanaPisco/1.0',
      }).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final address = data['address'] as Map<String, dynamic>?;
        if (address != null) {
          final road = address['road'] ?? address['pedestrian'] ?? address['suburb'];
          final city = address['city'] ?? address['town'] ?? address['county'] ?? 'Pisco';
          if (road != null) {
            return '$road, $city';
          }
        }
        final displayName = data['display_name'] as String?;
        if (displayName != null) {
          final parts = displayName.split(',');
          return parts.take(2).join(',').trim();
        }
      }
    } catch (_) {}
    return null;
  }

  /// Retorna un texto formateado de la dirección o coordenadas para la alerta
  static String formatLocationText(Position? position, {String fallback = 'Pisco, Ica - Ubicación móvil GPS'}) {
    if (position == null) return fallback;
    final accuracyStr = ' (±${position.accuracy.toStringAsFixed(1)}m)';
    return 'Lat: ${position.latitude.toStringAsFixed(5)}, Lon: ${position.longitude.toStringAsFixed(5)}$accuracyStr';
  }

  /// Verifica si ya tiene permisos suficientes para el funcionamiento continuo.
  /// Evitamos volver a solicitar "Permitir todo el tiempo" en cada reanudación.
  static Future<bool> hasLocationPermission() async {
    try {
      final permission = await Geolocator.checkPermission();
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return false;
      if (permission == LocationPermission.always) return true;
      if (permission == LocationPermission.whileInUse) return true;
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Comprueba y solicita permisos proactivamente al registrarse o abrir la app por primera vez
  static Future<bool> checkAndPromptLocationPermission(BuildContext context) async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
        if (!serviceEnabled && context.mounted) {
          _showEnableGpsDialog(context);
          return false;
        }
        // Permiso ya concedido.
        // Si solo tiene whileInUse, no volvemos a solicitar background para evitar
        // el bucle de re-pregunta al volver a la app (Android muestra el diálogo
        // de "Permitir todo el tiempo" solo cuando corresponde y muchas veces lo
        // muestra de forma persistente). Con "always" o foreground ya concedido,
        // el servicio nativo con foregroundServiceType location funciona para
        // lectura GPS; el requerimiento de background explícito se conserva en manifest
        // pero evitamos re-solicitarlo en cada reanudación.
        getCurrentLocation();
        return true;
      }

      if (!context.mounted) return false;

      // Mostrar diálogo explicativo de seguridad antes de solicitar permiso nativo
      final userWantsToAllow = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: AppColors.border, width: 1.2),
          ),
          contentPadding: const EdgeInsets.all(24),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.primaryRed.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.primaryRed.withValues(alpha: 0.35), width: 1.5),
                ),
                child: const Icon(
                  Icons.location_on_rounded,
                  color: AppColors.primaryRed,
                  size: 34,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Protección Satelital y GPS',
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                'Para que la Policía y la Central de Serenazgo puedan auxiliarte con precisión milimétrica ante un robo o emergencia, Alerta Ciudadana necesita acceder a tu ubicación.',
                style: GoogleFonts.inter(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  height: 1.45,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: Column(
                  children: [
                    _buildPermissionBenefit(Icons.bolt_rounded, 'Despacho táctico en tiempo real al pulsar SOS'),
                    const SizedBox(height: 8),
                    _buildPermissionBenefit(Icons.phone_android_rounded, 'Localización satelital por 3 toques del botón físico'),
                    const SizedBox(height: 8),
                    _buildPermissionBenefit(Icons.shield_outlined, 'Rastreo en vivo de la víctima ante asalto callejero'),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryRed,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                  child: Text(
                    'PERMITIR UBICACIÓN GPS',
                    style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.5),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(
                  'Ahora no',
                  style: GoogleFonts.inter(color: AppColors.textMuted, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      );

      if (userWantsToAllow == true) {
        AppLockService().isSystemDialogActive = true;
        try {
          if (permission == LocationPermission.deniedForever) {
            await Geolocator.openAppSettings();
            return false;
          }

          permission = await Geolocator.requestPermission();
          if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
            if (!serviceEnabled && context.mounted) {
              _showEnableGpsDialog(context);
            } else {
              // Acaba de conceder permiso de primer plano: intentar obtener también
              // el de SEGUNDO PLANO ("Permitir todo el tiempo") para que el GPS
              // siga fijando con la pantalla apagada durante un asalto.
              if (permission == LocationPermission.whileInUse && context.mounted) {
                await _requestBackgroundLocation(context);
              }
              getCurrentLocation(); // Pre-calentar satélites
            }
            return true;
          }
        } finally {
          await Future.delayed(const Duration(milliseconds: 600));
          AppLockService().isSystemDialogActive = false;
          AppLockService().recordUserActivity();
        }
      }
    } catch (e) {
      developer.log('Error verificando permisos de ubicación: $e', name: 'GpsLocationService');
    }
    return false;
  }

  /// Solicita el permiso de ubicación en SEGUNDO PLANO ("Permitir todo el tiempo").
  ///
  /// En Android 10+ este permiso es OBLIGATORIO para seguir recibiendo fijaciones
  /// GPS cuando la pantalla está apagada o la app pasa a segundo plano. Sin él,
  /// el SO deja de entregar ubicación en el momento exacto de un asalto/bolsillo,
  /// y la alerta caía a coordenadas falsas (fallback de ciudad).
  ///
  /// Debe llamarse DESPUÉS de tener el permiso de primer plano (whileInUse).
  static Future<void> _requestBackgroundLocation(BuildContext context) async {
    try {
      if (defaultTargetPlatform != TargetPlatform.android) return;

      final current = await Geolocator.checkPermission();
      if (current == LocationPermission.always || current == LocationPermission.deniedForever) {
        return;
      }

      if (!context.mounted) return;

      // Dialogo explicativo: en Android 10+ la opción "Permitir todo el tiempo"
      // solo aparece si el usuario entiende por qué la necesita.
      final wantsBackground = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: AppColors.border, width: 1.2),
          ),
          contentPadding: const EdgeInsets.all(24),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.primaryRed.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.primaryRed.withValues(alpha: 0.35), width: 1.5),
                ),
                child: const Icon(
                  Icons.location_on_rounded,
                  color: AppColors.primaryRed,
                  size: 34,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Activar ubicación en segundo plano',
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                'Para que el rastreo satelital siga funcionando con la pantalla apagada o con la app cerrada durante un asalto, elige "PERMITIR TODO EL TIEMPO" en el siguiente mensaje del sistema.',
                style: GoogleFonts.inter(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                  height: 1.45,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(
                'Ahora no',
                style: GoogleFonts.inter(color: AppColors.textMuted, fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryRed,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              child: Text(
                'CONTINUAR',
                style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 0.5),
              ),
            ),
          ],
        ),
      );

      if (wantsBackground != true) return;
      if (!context.mounted) return;

      AppLockService().isSystemDialogActive = true;
      try {
        // En Android 10+, tras tener whileInUse, volver a solicitar permite
        // elegir "Permitir todo el tiempo" (requiere ACCESS_BACKGROUND_LOCATION
        // declarado en el manifest, ya agregado).
        final upgraded = await Geolocator.requestPermission();
        developer.log('Permiso de ubicación tras solicitar fondo: $upgraded', name: 'GpsLocationService');
      } finally {
        await Future.delayed(const Duration(milliseconds: 600));
        AppLockService().isSystemDialogActive = false;
        AppLockService().recordUserActivity();
      }
    } catch (e) {
      developer.log('Error solicitando permiso de ubicación en segundo plano: $e', name: 'GpsLocationService');
    }
  }

  static Widget _buildPermissionBenefit(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, color: AppColors.accentGreen, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: GoogleFonts.inter(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }

  static void _showEnableGpsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.location_disabled_rounded, color: AppColors.warning, size: 22),
            const SizedBox(width: 8),
            Text('Activa tu GPS', style: GoogleFonts.inter(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
          ],
        ),
        content: Text(
          'Los servicios de ubicación de tu teléfono están apagados. Actívalos para que las alertas envíen tus coordenadas reales.',
          style: GoogleFonts.inter(color: AppColors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancelar', style: GoogleFonts.inter(color: AppColors.textMuted)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              AppLockService().isSystemDialogActive = true;
              try {
                await Geolocator.openLocationSettings();
              } finally {
                await Future.delayed(const Duration(milliseconds: 600));
                AppLockService().isSystemDialogActive = false;
                AppLockService().recordUserActivity();
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accentGreen),
            child: Text('Activar GPS', style: GoogleFonts.inter(color: Colors.black, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
