import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'session_service.dart';
import 'whatsapp_api_service.dart';

/// Servicio para almacenamiento dual (Local persistente + Supabase en la nube)
/// de todos los reportes ciudadanos, tanto enviados exitosamente como aquellos
/// pendientes o no enviados por corte de red o falta de conexión.
class ReportStorageService {
  static const String _keyLocalReports = 'local_saved_reports_v2';
  static const String _supabaseUrl = 'https://emtzprcntefzkvvzmhfk.supabase.co';

  /// Edge Function de seguridad: única vía autorizada para leer la tabla
  /// `persona` (el RLS cierra el acceso directo al rol anon).
  static const String _securityFunctionUrl =
      '$_supabaseUrl/functions/v1/security';

  /// Obtiene los headers autorizados para PostgREST de Supabase
  /// Importante: PostgREST exige el JWT anónimo del proyecto en Authorization: Bearer
  static Map<String, String> get _supabaseHeaders => {
        'apikey': WhatsAppApiService.supabaseAnonKey,
        'Authorization': 'Bearer ${WhatsAppApiService.supabaseAnonKey}',
        'Content-Type': 'application/json',
      };

  /// Mapea el nombre de la categoría a su respectivo id_tipo
  static int getTipoId(String category) {
    switch (category.trim().toUpperCase()) {
      case 'ROBO':
        return 1;
      case 'ACCIDENTE':
        return 2;
      case 'INCENDIO':
        return 3;
      case 'GRESCA':
        return 4;
      case 'ASESINATO':
        return 5;
      case 'SECUESTRO':
        return 6;
      case 'PERSONALIZADO':
      default:
        return 7;
    }
  }

  /// Genera una clave de caché aislada para el usuario actual
  static String _getUserCacheKey(int? idPersona, String? dni) {
    if (idPersona != null && idPersona > 0) {
      return 'local_saved_reports_user_$idPersona';
    }
    final cleanDni = dni?.trim() ?? '';
    if (cleanDni.isNotEmpty) {
      return 'local_saved_reports_user_$cleanDni';
    }
    return 'local_saved_reports_guest';
  }

  /// Resuelve el id_persona del usuario logueado actualmente
  static Future<int?> _resolveCurrentIdPersona() async {
    int? idPersona = await SessionService.getIdPersona();
    if (idPersona != null && idPersona > 0) return idPersona;

    final citizen = await SessionService.getUserData();
    final dni = citizen['dni']?.trim() ?? '';
    if (dni.isNotEmpty) {
      try {
        // Se resuelve vía Edge Function `security` (find-user) porque la tabla
        // `persona` tiene el RLS cerrado al rol anon: el acceso REST directo
        // dejó de estar permitido.
        final res = await http
            .post(
              Uri.parse('$_securityFunctionUrl?action=find-user'),
              headers: _supabaseHeaders,
              body: jsonEncode({'dni': dni}),
            )
            .timeout(const Duration(seconds: 6));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final user = data is Map<String, dynamic> ? data['user'] : null;
          if (user is Map<String, dynamic>) {
            idPersona = int.tryParse(user['id_persona']?.toString() ?? '');
            if (idPersona != null && idPersona > 0) {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setInt('app_session_user_id_persona', idPersona);
            }
          }
        }
      } catch (e) {
        developer.log('Error resolviendo id_persona vía Edge Function: $e', name: 'ReportStorageService');
      }
    }
    return idPersona;
  }

  /// Carga la lista combinada de reportes pertenecientes exclusivamente al usuario logueado:
  /// 1. Lee la memoria caché local privada del usuario.
  /// 2. Consulta a Supabase los reportes en la nube filtrados por id_persona.
  /// 3. Fusiona y actualiza la caché local privada.
  static Future<List<Map<String, dynamic>>> loadAllReports() async {
    final idPersona = await _resolveCurrentIdPersona();
    final citizen = await SessionService.getUserData();
    final currentDni = citizen['dni']?.trim() ?? '';
    final userCacheKey = _getUserCacheKey(idPersona, currentDni);

    final prefs = await SharedPreferences.getInstance();
    List<Map<String, dynamic>> localList = [];

    // 1. Cargar caché privada del usuario
    final rawUserJson = prefs.getString(userCacheKey);
    if (rawUserJson != null && rawUserJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawUserJson) as List<dynamic>;
        localList = decoded.cast<Map<String, dynamic>>().toList();
      } catch (e) {
        developer.log('Error decodificando reportes locales de usuario: $e', name: 'ReportStorageService');
      }
    } else {
      // Migración / rescate preventivo de reportes generados localmente en este dispositivo
      final rawOldJson = prefs.getString(_keyLocalReports);
      if (rawOldJson != null && rawOldJson.isNotEmpty) {
        try {
          final decodedOld = jsonDecode(rawOldJson) as List<dynamic>;
          final oldList = decodedOld.cast<Map<String, dynamic>>();
          for (final item in oldList) {
            final itemPersona = item['id_persona'];
            final itemDni = item['dni'];
            final isLocalUnsynced = item['is_synced'] == false || item['id_estado'] == 2;
            if (itemPersona != null && itemPersona == idPersona) {
              localList.add(item);
            } else if (itemDni != null && itemDni == currentDni) {
              localList.add(item);
            } else if (isLocalUnsynced && itemPersona == null && itemDni == null) {
              item['id_persona'] = idPersona;
              item['dni'] = currentDni;
              localList.add(item);
            }
          }
        } catch (_) {}
      }
    }

    // 2. Consulta a Supabase filtrando EXCLUSIVAMENTE por el id_persona del usuario logueado
    if (idPersona != null && idPersona > 0) {
      try {
        final uriWithFotos = Uri.parse(
          '$_supabaseUrl/rest/v1/reporte?id_persona=eq.$idPersona&select=id_reporte,id_persona,descripcion,fecha_hora,direccion_texto,id_tipo,id_estado,fotos,tipo_incidencia(nombre),estado_reporte(nombre)&order=fecha_hora.desc',
        );

        var response = await http
            .get(uriWithFotos, headers: _supabaseHeaders)
            .timeout(const Duration(seconds: 6));

        // Si la columna fotos aún no fue creada en PostgreSQL, consultar columnas base
        if (response.statusCode == 400 && response.body.contains('fotos')) {
          final uriBase = Uri.parse(
            '$_supabaseUrl/rest/v1/reporte?id_persona=eq.$idPersona&select=id_reporte,id_persona,descripcion,fecha_hora,direccion_texto,id_tipo,id_estado,tipo_incidencia(nombre),estado_reporte(nombre)&order=fecha_hora.desc',
          );
          response = await http
              .get(uriBase, headers: _supabaseHeaders)
              .timeout(const Duration(seconds: 6));
        }

        if (response.statusCode == 200) {
          final List<dynamic> remoteData = jsonDecode(response.body);
          final remoteReports = remoteData.cast<Map<String, dynamic>>();

          // Fusionar: Mantener reportes locales no sincronizados del usuario
          final Map<String, Map<String, dynamic>> mergedMap = {};

          // Agregar primero los remotos del usuario
          for (final r in remoteReports) {
            final idKey = 'REP-${r['id_reporte']}';
            mergedMap[idKey] = r;
          }

          // Solo mantener locales que sean borradores pendientes nunca sincronizados (sin id_reporte y is_synced == false).
          // Cualquier reporte que tenga id_reporte pero ya no exista en Supabase fue eliminado en la nube y se purga definitivamente de la caché local.
          for (final l in localList) {
            final isSynced = l['is_synced'] == true;
            final hasRemoteId = l['id_reporte'] != null;
            if (!isSynced && !hasRemoteId) {
              final idKey = 'LOC-${l['fecha_hora']}';
              mergedMap[idKey] = l;
            }
          }

          // Ordenar por fecha descendente
          final mergedList = mergedMap.values.toList();
          mergedList.sort((a, b) {
            final dtA = DateTime.tryParse(a['fecha_hora']?.toString() ?? '') ?? DateTime(2000);
            final dtB = DateTime.tryParse(b['fecha_hora']?.toString() ?? '') ?? DateTime(2000);
            return dtB.compareTo(dtA);
          });

          // Guardar la caché consolidada del usuario
          await prefs.setString(userCacheKey, jsonEncode(mergedList));
          return mergedList;
        }
      } catch (e) {
        developer.log('Sin conexión con Supabase. Mostrando caché local del usuario: $e', name: 'ReportStorageService');
      }
    }

    // Si no hubo respuesta remota, retornar la lista local del usuario ordenadada
    localList.sort((a, b) {
      final dtA = DateTime.tryParse(a['fecha_hora']?.toString() ?? '') ?? DateTime(2000);
      final dtB = DateTime.tryParse(b['fecha_hora']?.toString() ?? '') ?? DateTime(2000);
      return dtB.compareTo(dtA);
    });

    return localList;
  }

  /// Guarda un reporte inmediatamente (tanto en almacenamiento local como en Supabase)
  /// Si el envío falla o está offline, queda registrado con id_estado = 2 ("No enviado").
  static Future<Map<String, dynamic>> saveReport({
    required String category,
    required String message,
    required String address,
    required double lat,
    required double lon,
    List<String>? imagePaths,
    bool isSuccessfullyDispatched = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final idTipo = getTipoId(category);

    // Resolver usuario logueado
    int? idPersona = await _resolveCurrentIdPersona();
    final citizen = await SessionService.getUserData();
    final dni = citizen['dni'] ?? '';
    final userCacheKey = _getUserCacheKey(idPersona, dni);

    // 1. Procesar fotografías a Base64
    final List<Map<String, dynamic>> fotosList = [];
    if (imagePaths != null && imagePaths.isNotEmpty) {
      for (int i = 0; i < imagePaths.length; i++) {
        final f = File(imagePaths[i]);
        if (await f.exists()) {
          try {
            final bytes = await f.readAsBytes();
            final b64 = base64Encode(bytes);
            fotosList.add({
              'nombre': f.uri.pathSegments.isNotEmpty ? f.uri.pathSegments.last : 'foto_${i + 1}.jpg',
              'data': 'data:image/jpeg;base64,$b64',
              'tamano': bytes.length,
            });
          } catch (e) {
            developer.log('Error codificando foto $i: $e', name: 'ReportStorageService');
          }
        }
      }
    }

    // 2. Crear objeto reporte inicial con el id_persona y DNI del usuario logueado
    final Map<String, dynamic> reportRecord = {
      'id_reporte': DateTime.now().millisecondsSinceEpoch,
      'id_tipo': idTipo,
      'id_persona': idPersona,
      'dni': dni,
      'tipo_incidencia': {'nombre': category.trim().toUpperCase()},
      'id_estado': 1,
      'estado_reporte': {'nombre': 'Pendiente'},
      'fecha_hora': nowIso,
      'descripcion': message,
      'direccion_texto': address,
      'fotos': fotosList,
      'latitud': lat,
      'longitud': lon,
      'is_synced': false,
    };

    // 3. Guardado preventivo inmediato en memoria local aislada del usuario
    List<Map<String, dynamic>> currentLocal = [];
    final rawJson = prefs.getString(userCacheKey);
    if (rawJson != null && rawJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawJson) as List<dynamic>;
        currentLocal = decoded.cast<Map<String, dynamic>>().toList();
      } catch (_) {}
    }
    currentLocal.insert(0, reportRecord);
    await prefs.setString(userCacheKey, jsonEncode(currentLocal));

    // 4. Intentar sincronización con Supabase
    try {
      final targetIdPersona = idPersona ?? 1;

      final reportUri = Uri.parse('$_supabaseUrl/rest/v1/reporte');
      final insertHeaders = {
        ..._supabaseHeaders,
        'Prefer': 'return=representation',
      };

      Map<String, dynamic> remotePayload = {
        'id_persona': targetIdPersona,
        'id_tipo': idTipo,
        'id_estado': 1,
        'fecha_hora': nowIso,
        'descripcion': message,
        'direccion_texto': address,
      };

      if (fotosList.isNotEmpty) {
        remotePayload['fotos'] = fotosList;
      }

      var res = await http.post(
        reportUri,
        headers: insertHeaders,
        body: jsonEncode(remotePayload),
      ).timeout(const Duration(seconds: 7));

      if (res.statusCode == 400 && res.body.contains('fotos')) {
        remotePayload.remove('fotos');
        if (fotosList.isNotEmpty) {
          remotePayload['descripcion'] = '$message\n📸 [${fotosList.length} fotografía(s) adjunta(s)]';
        }
        res = await http.post(
          reportUri,
          headers: insertHeaders,
          body: jsonEncode(remotePayload),
        ).timeout(const Duration(seconds: 7));
      }

      if (res.statusCode == 201 || res.statusCode == 200) {
        final List<dynamic> resData = jsonDecode(res.body);
        if (resData.isNotEmpty) {
          final int newReportId = int.parse(resData.first['id_reporte'].toString());
          reportRecord['id_reporte'] = newReportId;
          reportRecord['is_synced'] = true;
          reportRecord['id_estado'] = 1;
          reportRecord['estado_reporte'] = {'nombre': 'Enviado'};
          reportRecord['id_persona'] = targetIdPersona;

          // Actualizar en lista local del usuario
          currentLocal[0] = reportRecord;
          await prefs.setString(userCacheKey, jsonEncode(currentLocal));

          // Guardar ubicación en Supabase
          try {
            await http.post(
              Uri.parse('$_supabaseUrl/rest/v1/ubicacion'),
              headers: insertHeaders,
              body: jsonEncode({
                'id_reporte': newReportId,
                'latitud': lat,
                'longitud': lon,
                'fecha_hora': nowIso,
              }),
            ).timeout(const Duration(seconds: 4));
          } catch (_) {}

          developer.log('Reporte #$newReportId sincronizado exitosamente con Supabase', name: 'ReportStorageService');
        }
      } else {
        developer.log('Supabase no aceptó inserción (${res.statusCode}): ${res.body}. Conservado localmente.', name: 'ReportStorageService');
      }
    } catch (e) {
      developer.log('Error o sin conexión al persistir en Supabase: $e. Conservado localmente como "No enviado".', name: 'ReportStorageService');
    }

    return reportRecord;
  }

  /// Actualiza un reporte existente en la caché local como "Enviado" (id_estado = 1)
  static Future<void> markReportAsSent(int idReporte) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final idPersona = await _resolveCurrentIdPersona();
      final citizen = await SessionService.getUserData();
      final userCacheKey = _getUserCacheKey(idPersona, citizen['dni']);

      for (final key in [userCacheKey, _keyLocalReports]) {
        final rawJson = prefs.getString(key);
        if (rawJson != null && rawJson.isNotEmpty) {
          final decoded = jsonDecode(rawJson) as List<dynamic>;
          final list = decoded.cast<Map<String, dynamic>>().toList();
          bool updated = false;
          for (var r in list) {
            if (r['id_reporte'] == idReporte) {
              r['id_estado'] = 1;
              r['estado_reporte'] = {'nombre': 'Enviado'};
              updated = true;
              break;
            }
          }
          if (updated) {
            await prefs.setString(key, jsonEncode(list));
          }
        }
      }
    } catch (_) {}
  }
}
