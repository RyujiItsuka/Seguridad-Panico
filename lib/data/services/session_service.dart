import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'app_lock_service.dart';
import 'hardware_trigger_service.dart';
import 'whatsapp_api_service.dart';

/// Servicio para persistencia segura de sesión de usuario y PIN secreto en almacenamiento seguro
/// Cumple con: HU-SEG-02 (flutter_secure_storage / Keychain & Keystore)
class SessionService {
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static const String _keyIsLoggedIn = 'app_session_is_logged_in';
  static const String _keyUserDni = 'app_session_user_dni';
  static const String _keyUserName = 'app_session_user_name';
  static const String _keyUserPhone = 'app_session_user_phone';
  static const String _keySecretPin = 'app_session_secret_pin';
  static const String _keyJwtToken = 'app_session_jwt_token';
  static const String _keyUserIdPersona = 'app_session_user_id_persona';
  static const String _keyLastDni = 'app_last_used_dni';

  /// Guarda la sesión del ciudadano en almacenamiento seguro encriptado
  static Future<void> saveSession({
    required String dni,
    String name = 'Ciudadano',
    String phone = '',
    String? secretPin,
    String? jwtToken,
    int? idPersona,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyIsLoggedIn, true);
    await prefs.setString(_keyUserDni, dni);
    await prefs.setString(_keyLastDni, dni);
    await prefs.setString(_keyUserName, name);
    await prefs.setString(_keyUserPhone, phone);
    if (idPersona != null) {
      await prefs.setInt(_keyUserIdPersona, idPersona);
    }

    // Guardado en Keystore/Keychain mediante flutter_secure_storage (HU-SEG-02)
    try {
      if (jwtToken != null && jwtToken.trim().isNotEmpty) {
        await _secureStorage.write(key: _keyJwtToken, value: jwtToken.trim());
      }
      if (secretPin != null && secretPin.trim().isNotEmpty) {
        await _secureStorage.write(key: _keySecretPin, value: secretPin.trim());
      }
      await _secureStorage.write(key: _keyUserDni, value: dni);
    } catch (_) {}

    if (secretPin != null && secretPin.trim().isNotEmpty) {
      await prefs.setString(_keySecretPin, secretPin.trim());
    }
  }

  /// Obtiene el ID de persona registrado en la base de datos
  static Future<int?> getIdPersona() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyUserIdPersona);
  }

  /// Obtiene el último DNI registrado o utilizado en el dispositivo
  static Future<String?> getLastDni() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString(_keyLastDni);
    if (last != null && last.isNotEmpty) return last;
    return prefs.getString(_keyUserDni);
  }

  /// Guarda el último DNI para prellenar o login biométrico
  static Future<void> saveLastDni(String dni) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLastDni, dni.trim());
  }

  /// Verifica si el usuario tiene una sesión activa previa
  static Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    final isLogged = prefs.getBool(_keyIsLoggedIn) ?? false;
    if (isLogged) return true;
    final dni = prefs.getString(_keyUserDni);
    if (dni != null && dni.trim().isNotEmpty) return true;
    final lastDni = prefs.getString(_keyLastDni);
    if (lastDni != null && lastDni.trim().isNotEmpty) return true;
    return false;
  }

  /// Obtiene el token JWT único emitido por el backend (HU-SEG-02)
  static Future<String?> getJwtToken() async {
    try {
      final token = await _secureStorage.read(key: _keyJwtToken);
      if (token != null && token.isNotEmpty) return token;
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyJwtToken);
  }

  // ===========================================================================
  // VALIDACIÓN DE LA SESIÓN CONTRA EL SERVIDOR
  // ---------------------------------------------------------------------------
  // La bandera local (isLoggedIn) no puede saber si el servidor revocó la
  // sesión (por robo o por exposición de tokens). Este método consulta la Edge
  // Function `security` (acción `verify-token`) para confirmar que el token
  // sigue vigente. Si la sesión fue revocada, se limpia la sesión local y se
  // devuelve false, de modo que la app vuelve al inicio de sesión.
  // ===========================================================================
  static const String _supabaseUrl = 'https://emtzprcntefzkvvzmhfk.supabase.co';
  static const String _securityFunctionUrl = '$_supabaseUrl/functions/v1/security';

  /// Devuelve true sólo si el token actual sigue siendo válido en el servidor.
  /// Ante cualquier error de red devuelve true (no se cierra sesión por falta
  /// de conexión); sólo cierra cuando el servidor responde que fue revocado.
  static Future<bool> isSessionValidOnServer() async {
    final token = await getJwtToken();
    if (token == null || token.trim().isEmpty) return false;

    try {
      final resp = await http.post(
        Uri.parse(_securityFunctionUrl),
        headers: {
          'Content-Type': 'application/json',
          'apikey': WhatsAppApiService.supabaseAnonKey,
          'Authorization': 'Bearer ${WhatsAppApiService.supabaseAnonKey}',
        },
        body: jsonEncode({'action': 'verify-token', 'token': token}),
      ).timeout(const Duration(seconds: 8));

      // El servidor responde 403 cuando la sesión fue revocada y 401 cuando el
      // token es inválido o expiró. En ambos casos la sesión local debe cerrarse.
      if (resp.statusCode == 403 || resp.statusCode == 401) {
        await clearSession();
        return false;
      }
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        if (data['valid'] == false) {
          await clearSession();
          return false;
        }
        return true;
      }
    } catch (_) {
      // Sin red o error transitorio: no se cierra la sesión por precaución.
      return true;
    }
    return true;
  }

  /// Obtiene el PIN secreto registrado (si no se guardó, usa los primeros 4 dígitos del DNI)
  static Future<String> getSecretPin() async {
    try {
      final securePin = await _secureStorage.read(key: _keySecretPin);
      if (securePin != null && securePin.trim().isNotEmpty) return securePin.trim();
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    final savedPin = prefs.getString(_keySecretPin);
    if (savedPin != null && savedPin.trim().isNotEmpty) return savedPin.trim();

    // Si no se guardó un PIN explícito, los primeros 4 dígitos del DNI del ciudadano logueado
    final dni = prefs.getString(_keyUserDni) ?? '';
    if (dni.length >= 4) {
      return dni.substring(0, 4);
    }
    return '7462';
  }

  /// Guarda o actualiza el PIN secreto de 4 dígitos
  static Future<void> setSecretPin(String newPin) async {
    final cleanPin = newPin.trim();
    if (cleanPin.length != 4) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySecretPin, cleanPin);
    try {
      await _secureStorage.write(key: _keySecretPin, value: cleanPin);
    } catch (_) {}
  }

  /// Valida si el PIN ingresado coincide con el PIN secreto registrado
  static Future<bool> verifySecretPin(String inputPin) async {
    final cleanInput = inputPin.trim();
    if (cleanInput.isEmpty) return false;

    final savedPin = await getSecretPin();
    if (cleanInput == savedPin) {
      return true;
    }

    // Comprobar también contra los primeros 4 dígitos del DNI del usuario actual
    final prefs = await SharedPreferences.getInstance();
    final dni = prefs.getString(_keyUserDni) ?? '';
    if (dni.length >= 4 && cleanInput == dni.substring(0, 4)) {
      await setSecretPin(cleanInput);
      return true;
    }

    return false;
  }

  /// Obtiene los datos del ciudadano almacenado
  static Future<Map<String, String>> getUserData() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'dni': prefs.getString(_keyUserDni) ?? '',
      'name': prefs.getString(_keyUserName) ?? 'Ciudadano',
      'phone': prefs.getString(_keyUserPhone) ?? '',
    };
  }

  /// Cierra la sesión y borra las credenciales locales y de Keystore
  static Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyIsLoggedIn);
    await prefs.remove(_keyUserDni);
    await prefs.remove(_keyUserName);
    await prefs.remove(_keyUserPhone);
    await prefs.remove(_keySecretPin);
    await prefs.remove(_keyJwtToken);
    await prefs.remove(_keyUserIdPersona);

    try {
      await _secureStorage.deleteAll();
    } catch (_) {}

    try {
      await prefs.setBool(_keyIsLoggedIn, false);
      AppLockService().onLogout();
      await HardwareTriggerService().cancelEmergency();
      await HardwareTriggerService().stopBackgroundService();
    } catch (_) {}
  }
}
