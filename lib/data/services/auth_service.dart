import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'session_service.dart';
import 'whatsapp_api_service.dart';

class AuthResult {
  final bool success;
  final String? errorMessage;
  final Map<String, dynamic>? userData;
  final String? token;

  AuthResult({
    required this.success,
    this.errorMessage,
    this.userData,
    this.token,
  });
}

/// Servicio de Autenticación y Seguridad (Sprint 4)
/// Cumple con: HU-SEG-01 (OTP WhatsApp), HU-SEG-02 (JWT Keystore), HU-SEG-06 (Bcrypt)
class AuthService {
  static const String _supabaseUrl = 'https://emtzprcntefzkvvzmhfk.supabase.co';
  static const String _securityFunctionUrl = '$_supabaseUrl/functions/v1/security';
  static const String _anonKey = WhatsAppApiService.supabaseAnonKey;

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'apikey': _anonKey,
        'Authorization': 'Bearer $_anonKey',
      };

  /// Cliente HTTP inyectable. En producción usa el cliente real; en pruebas se
  /// reemplaza por un `MockClient` para validar la lógica sin red.
  static http.Client httpClient = http.Client();

  /// HU-SEG-01: Solicita un código OTP de 6 dígitos enviado por WhatsApp al registrarse
  static Future<AuthResult> requestOtp({
    required String dni,
    required String phone,
  }) async {
    final cleanDni = dni.trim();
    final cleanPhone = phone.trim();

    try {
      final response = await httpClient
          .post(
            Uri.parse('$_securityFunctionUrl?action=send-otp'),
            headers: _headers,
            body: jsonEncode({
              'dni': cleanDni,
              'phone': cleanPhone,
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        return AuthResult(success: true);
      } else {
        final data = jsonDecode(response.body);
        return AuthResult(
          success: false,
          errorMessage: data['error'] ?? 'No se pudo enviar el código OTP',
        );
      }
    } catch (e) {
      developer.log('Error solicitando OTP: $e', name: 'AuthService');
      return AuthResult(
        success: false,
        errorMessage: 'No se pudo conectar con la Central para enviar el código. Revise su red.',
      );
    }
  }

  /// HU-SEG-01: Valida el código OTP de 6 dígitos ingresado por el ciudadano
  static Future<AuthResult> verifyOtp({
    required String dni,
    required String phone,
    required String code,
  }) async {
    final cleanCode = code.trim();
    if (cleanCode.length != 6) {
      return AuthResult(success: false, errorMessage: 'El código debe tener 6 dígitos.');
    }

    try {
      final response = await httpClient
          .post(
            Uri.parse('$_securityFunctionUrl?action=verify-otp'),
            headers: _headers,
            body: jsonEncode({
              'dni': dni.trim(),
              'phone': phone.trim(),
              'code': cleanCode,
            }),
          )
          .timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return AuthResult(
          success: true,
          token: data is Map ? data['resetToken']?.toString() : null,
        );
      } else {
        final data = jsonDecode(response.body);
        return AuthResult(
          success: false,
          errorMessage: data['error'] ?? 'Código incorrecto o expirado.',
        );
      }
    } catch (e) {
      developer.log('Error verificando OTP: $e', name: 'AuthService');
      return AuthResult(
        success: false,
        errorMessage: 'No se pudo verificar el código. Revise su conexión.',
      );
    }
  }

  /// HU-SEG-02 & HU-SEG-06: Inicia sesión con DNI y contraseña validando Bcrypt y guardando JWT en Keystore
  static Future<AuthResult> login({
    required String dni,
    required String password,
  }) async {
    final cleanDni = dni.trim();
    final cleanPassword = password.trim();

    if (cleanDni.isEmpty || cleanPassword.isEmpty) {
      return AuthResult(
        success: false,
        errorMessage: 'Por favor ingrese su DNI y contraseña.',
      );
    }

    // 1. Intento primario a través de la Edge Function de Seguridad (Bcrypt + JWT)
    try {
      final response = await httpClient
          .post(
            Uri.parse('$_securityFunctionUrl?action=login'),
            headers: _headers,
            body: jsonEncode({
              'dni': cleanDni,
              'password': cleanPassword,
            }),
          )
          .timeout(const Duration(seconds: 7));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final token = data['token'] as String?;
        final user = data['user'] as Map<String, dynamic>?;

        final nombres = user?['nombres']?.toString().trim() ?? '';
        final apellidos = user?['apellidos']?.toString().trim() ?? '';
        final fullName = '$nombres $apellidos'.trim();
        final displayName = fullName.isNotEmpty ? fullName : (nombres.isNotEmpty ? nombres : 'Ciudadano');
        final idPersona = user?['id_persona'] != null ? int.tryParse(user!['id_persona'].toString()) : null;

        final dniVal = (user?['dni'] ?? cleanDni).toString().trim();
        final defaultPin = dniVal.length >= 4 ? dniVal.substring(0, 4) : '7462';

        await SessionService.saveSession(
          dni: dniVal,
          name: displayName,
          phone: user?['telefono'] ?? '+51 999 999 999',
          secretPin: defaultPin,
          jwtToken: token,
          idPersona: idPersona,
        );

        return AuthResult(success: true, token: token, userData: user);
      } else if (response.statusCode == 401 || response.statusCode == 404) {
        final data = jsonDecode(response.body);
        return AuthResult(success: false, errorMessage: data['error']);
      }
    } catch (e) {
      developer.log('Fallo Edge Function security login: $e', name: 'AuthService');
    }

    // Sin respaldo offline: la validación es SIEMPRE por la Edge Function
    // `security` (bcrypt + JWT). No existen credenciales demo ni lecturas
    // directas a la tabla persona desde el cliente.
    return AuthResult(success: false, errorMessage: 'Sin conexión con la Central. Verifique su red.');
  }

  /// HU-SEG-01, HU-SEG-02, HU-SEG-06: Registro completo con OTP verificado, Bcrypt y JWT
  static Future<AuthResult> register({
    required String dni,
    String? firstName,
    String? lastName,
    String? name,
    required String phone,
    required String password,
    required String pin,
    String? otpCode,
  }) async {
    final cleanDni = dni.trim();
    var cleanFirstName = (firstName ?? name ?? '').trim();
    var cleanLastName = (lastName ?? '').trim();

    // Si apellidos vino vacío y nombres contiene más de una palabra, descomponer inteligentemente
    if (cleanLastName.isEmpty && cleanFirstName.contains(' ')) {
      final parts = cleanFirstName.split(RegExp(r'\s+'));
      if (parts.length >= 4) {
        cleanFirstName = parts.sublist(0, 2).join(' ');
        cleanLastName = parts.sublist(2).join(' ');
      } else if (parts.length == 3) {
        cleanFirstName = parts.sublist(0, 1).join(' ');
        cleanLastName = parts.sublist(1).join(' ');
      } else if (parts.length == 2) {
        cleanFirstName = parts[0];
        cleanLastName = parts[1];
      }
    }

    final fullName = '$cleanFirstName $cleanLastName'.trim();
    final cleanPhone = phone.trim();
    final cleanPassword = password.trim();
    final cleanPin = pin.trim();

    final pinSecurityError = validatePinSecurity(cleanPin);
    if (pinSecurityError != null) {
      return AuthResult(success: false, errorMessage: pinSecurityError);
    }

    // 1. Intento primario con Edge Function de Seguridad
    try {
      final response = await httpClient
          .post(
            Uri.parse('$_securityFunctionUrl?action=register'),
            headers: _headers,
            body: jsonEncode({
              'dni': cleanDni,
              'nombres': cleanFirstName,
              'apellidos': cleanLastName,
              'firstName': cleanFirstName,
              'lastName': cleanLastName,
              'name': fullName,
              'phone': cleanPhone,
              'password': cleanPassword,
              'pin': cleanPin,
              'otpCode': otpCode,
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 201 || response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final token = data['token'] as String?;
        final user = data['user'] as Map<String, dynamic>?;
        final idPersona = user?['id_persona'] != null ? int.tryParse(user!['id_persona'].toString()) : null;

        await SessionService.saveSession(
          dni: cleanDni,
          name: fullName,
          phone: cleanPhone,
          secretPin: cleanPin,
          jwtToken: token,
          idPersona: idPersona,
        );

        return AuthResult(success: true, token: token, userData: user);
      } else {
        final data = jsonDecode(response.body);
        return AuthResult(success: false, errorMessage: data['error'] ?? 'Error al registrar.');
      }
    } catch (e) {
      developer.log('Fallo Edge Function security register: $e', name: 'AuthService');
    }

    return AuthResult(success: false, errorMessage: 'Fallo de conexión al registrar. Intente nuevamente.');
  }

  /// HU-SEG-02: Revoca todas las sesiones del usuario ante reporte de robo de celular
  static Future<bool> revokeSession({required String dni}) async {
    try {
      final response = await httpClient.post(
        Uri.parse('$_securityFunctionUrl?action=revoke-session'),
        headers: _headers,
        body: jsonEncode({'dni': dni}),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Busca un usuario registrado por su DNI para recuperar contraseña o verificar cuenta.
  /// Va por la Edge Function `security` (find-user): no expone password_hash y
  /// funciona con el RLS de persona cerrado al rol anon.
  static Future<Map<String, dynamic>?> findUserByDni(String dni) async {
    final cleanDni = dni.trim();
    if (cleanDni.isEmpty) return null;

    try {
      final response = await httpClient
          .post(
            Uri.parse('$_securityFunctionUrl?action=find-user'),
            headers: _headers,
            body: jsonEncode({'dni': cleanDni}),
          )
          .timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic> && data['success'] == true) {
          final user = data['user'];
          if (user is Map<String, dynamic>) return user;
        }
      }
    } catch (e) {
      developer.log('Error buscando usuario por DNI vía Edge Function: $e', name: 'AuthService');
    }

    // Fallback: verificar sesión actual si coincide (sin exponer hashes)
    final currentSession = await SessionService.getUserData();
    if (currentSession['dni'] == cleanDni) {
      return {
        'dni': currentSession['dni'],
        'telefono': currentSession['phone'],
        'nombres': currentSession['name'],
      };
    }

    return null;
  }

  /// Envía un código OTP de 6 dígitos al WhatsApp del ciudadano.
  ///
  /// El código lo GENERA EL SERVIDOR (Edge Function `security` → `whatsapp`):
  /// el dispositivo nunca elige ni conoce el código, y la verificación es
  /// siempre contra el servidor. Esto sustituye al OTP generado en el cliente,
  /// que permitía a cualquier tercero que conociera un DNI pasar la
  /// verificación usando su propio código.
  static Future<AuthResult> sendWhatsAppOtp({
    required String dni,
    required String phone,
    String purpose = 'recuperación de contraseña',
  }) async {
    final cleanDni = dni.trim();
    final cleanPhone = phone.trim();

    if (cleanDni.isEmpty || cleanPhone.isEmpty) {
      return AuthResult(success: false, errorMessage: 'DNI o teléfono no válido.');
    }

    try {
      final response = await httpClient
          .post(
            Uri.parse('$_securityFunctionUrl?action=send-otp'),
            headers: _headers,
            body: jsonEncode({
              'dni': cleanDni,
              'phone': cleanPhone,
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        return AuthResult(success: true);
      }
      final data = jsonDecode(response.body);
      return AuthResult(
        success: false,
        errorMessage: data['error'] ?? 'No se pudo enviar el código.',
      );
    } catch (e) {
      developer.log('Error enviando OTP ($purpose): $e', name: 'AuthService');
      return AuthResult(
        success: false,
        errorMessage: 'No se pudo enviar el código. Revise su red.',
      );
    }
  }

  /// Verifica el código OTP contra el servidor y devuelve en `token` un
  /// resetToken firmado que autoriza el cambio de contraseña. No usa caché local.
  static Future<AuthResult> verifyRecoveryOtp({
    required String dni,
    required String phone,
    required String code,
  }) async {
    final cleanCode = code.trim();
    if (cleanCode.length != 6) {
      return AuthResult(success: false, errorMessage: 'El código debe tener 6 dígitos.');
    }
    return verifyOtp(dni: dni, phone: phone, code: cleanCode);
  }

  /// Restablece la contraseña del ciudadano en Supabase.
  /// Requiere el `resetToken` firmado que devuelve `verifyRecoveryOtp`: sin él
  /// el servidor rechaza el cambio (evita el reseteo por DNI de terceros).
  static Future<AuthResult> resetPassword({
    required String dni,
    required String newPassword,
    required String resetToken,
  }) async {
    final cleanDni = dni.trim();
    final cleanPassword = newPassword.trim();
    final cleanToken = resetToken.trim();

    if (cleanDni.isEmpty || cleanPassword.length < 6) {
      return AuthResult(
        success: false,
        errorMessage: 'La nueva contraseña debe tener al menos 6 caracteres.',
      );
    }

    if (cleanToken.isEmpty) {
      return AuthResult(
        success: false,
        errorMessage: 'Debe verificar el código OTP enviado a su WhatsApp antes de continuar.',
      );
    }

    // Sin respaldos locales: el cambio de contraseña SOLO se considera exitoso
    // cuando el servidor lo confirma (bcrypt + service_role + resetToken).
    try {
      final response = await httpClient.post(
        Uri.parse('$_securityFunctionUrl?action=reset-password'),
        headers: _headers,
        body: jsonEncode({
          'dni': cleanDni,
          'password': cleanPassword,
          'token': cleanToken,
        }),
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        return AuthResult(success: true);
      } else {
        final data = jsonDecode(response.body);
        return AuthResult(
          success: false,
          errorMessage: data['error'] ?? 'No se pudo actualizar la contraseña.',
        );
      }
    } catch (e) {
      developer.log('Error actualizando contraseña vía Edge Function: $e', name: 'AuthService');
    }

    return AuthResult(
      success: false,
      errorMessage: 'No se pudo actualizar la contraseña. Verifique su conexión.',
    );
  }

  /// Actualiza el PIN secreto de 4 dígitos en Supabase y SessionService
  static Future<bool> updatePin({
    required String dni,
    required String newPin,
  }) async {
    final cleanDni = dni.trim();
    final cleanPin = newPin.trim();

    if (validatePinSecurity(cleanPin) != null) {
      return false;
    }

    // El servidor exige una sesión válida (JWT de login) del propio usuario.
    final jwt = await SessionService.getJwtToken();
    if (jwt == null || jwt.isEmpty) {
      developer.log('updatePin sin sesión JWT válida.', name: 'AuthService');
      return false;
    }

    // Actualizar en Supabase vía Edge Function (bcrypt). Solo cuando el servidor
    // confirma el cambio se persiste el PIN local: se elimina el falso positivo
    // que devolvía "true" aunque la Central no hubiese actualizado nada.
    try {
      final response = await httpClient
          .post(
            Uri.parse('$_securityFunctionUrl?action=update-pin'),
            headers: _headers,
            body: jsonEncode({
              'dni': cleanDni,
              'pin': cleanPin,
              'token': jwt,
            }),
          )
          .timeout(const Duration(seconds: 6));
      if (response.statusCode == 200) {
        await SessionService.setSecretPin(cleanPin);
        return true;
      }
      return false;
    } catch (e) {
      developer.log('Error actualizando PIN vía Edge Function: $e', name: 'AuthService');
      return false;
    }
  }

  /// Valida si un PIN es débil o fácil de adivinar (PDF Seguridad Pisco - Punto 2)
  static String? validatePinSecurity(String pin) {
    final clean = pin.trim();
    if (clean.length != 4 || !RegExp(r'^\d{4}$').hasMatch(clean)) {
      return 'El PIN debe tener exactamente 4 dígitos numéricos.';
    }

    // 1. Dígitos idénticos (0000, 1111, 2222, etc.)
    if (clean[0] == clean[1] && clean[1] == clean[2] && clean[2] == clean[3]) {
      return 'PIN inseguro: no utilices 4 dígitos repetidos (ej. ${clean[0] * 4}).';
    }

    // 2. Secuencias consecutivas ascendentes o descendentes (1234, 4321, 0123, etc.)
    final d0 = int.parse(clean[0]);
    final d1 = int.parse(clean[1]);
    final d2 = int.parse(clean[2]);
    final d3 = int.parse(clean[3]);

    if ((d1 == d0 + 1 && d2 == d1 + 1 && d3 == d2 + 1) ||
        (d1 == d0 - 1 && d2 == d1 - 1 && d3 == d2 - 1)) {
      return 'PIN inseguro: no utilices secuencias consecutivas (como 1234 o 4321).';
    }

    // 3. Patrones repetitivos obvios (1212, 1010, 6969, etc.)
    if (clean.substring(0, 2) == clean.substring(2, 4)) {
      return 'PIN inseguro: no utilices combinaciones repetitivas como $clean.';
    }

    // 4. Años comunes de nacimiento (1940 - 2026)
    final year = int.tryParse(clean);
    if (year != null && year >= 1940 && year <= 2026) {
      return 'PIN inseguro: por motivos de seguridad no uses tu año de nacimiento ($clean).';
    }

    return null;
  }
}
