import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:alerta_ciudadana/data/services/whatsapp_api_service.dart';
import 'package:alerta_ciudadana/data/services/sensor_emergency_service.dart';
import 'package:alerta_ciudadana/data/services/session_service.dart';
import 'package:alerta_ciudadana/data/services/auth_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WhatsAppApiService Tests', () {
    test('default recipient is +51 976264949 and normalizes to 51976264949', () {
      expect(WhatsAppApiService.defaultEmergencyRecipient, '+51 976264949');
      expect(WhatsAppApiService.normalizeNumber('+51 976264949'), '51976264949');
      expect(WhatsAppApiService.normalizeNumber('976264949'), '51976264949');
    });

    test('getPredefinedMessage formats correctly for ROBO', () {
      final msg = WhatsAppApiService.getPredefinedMessage(
        'ROBO',
        address: 'Av. Test 123',
        lat: -12.04,
        lon: -77.02,
        source: 'BOTÓN ROJO',
      );
      expect(msg, contains('ROBANDO'));
      expect(msg, contains('Av. Test 123'));
      expect(msg, contains('BOTÓN ROJO'));
      expect(msg, contains('Central de Video Vigilancia'));
    });

    test('sendAutomatedEmergencyAlert completes successfully to 976264949', () async {
      final success = await WhatsAppApiService.sendAutomatedEmergencyAlert(
        category: 'ROBO',
        recipientNumber: '976264949',
        source: 'TEST_SUITE',
      );
      expect(success, isNotNull);
    });
  });

  group('SensorEmergencyService Tests', () {
    test('simulation triggers callback with reason', () {
      final sensor = SensorEmergencyService();
      String? triggeredReason;
      String? triggeredSource;

      sensor.startMonitoring(
        listenToHardware: false,
        onTriggered: (reason, source) {
          triggeredReason = reason;
          triggeredSource = source;
        },
      );

      sensor.simulateTheftSnatchTrigger();
      expect(triggeredReason, contains('Antirrobo'));
      expect(triggeredSource, 'sensor_simulado_robo');
      sensor.stopMonitoring();
    });

    test('does not trigger emergency if user is logged out', () async {
      SharedPreferences.setMockInitialValues({'app_session_is_logged_in': false});
      final sensor = SensorEmergencyService();
      String? triggeredReason;

      sensor.startMonitoring(
        listenToHardware: false,
        onTriggered: (reason, source) {
          triggeredReason = reason;
        },
      );

      sensor.simulateTheftSnatchTrigger(bypassAuth: false);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(triggeredReason, isNull);
      sensor.stopMonitoring();
    });

    test('sensor thresholds enforce snatch and violent twist conditions', () {
      final sensor = SensorEmergencyService();
      expect(sensor.snatchLinearThreshold, 24.0);
      expect(sensor.struggleGyroThreshold, 7.0);
      expect(sensor.snatchRawThreshold, 38.0);
    });
  });

  group('SessionService Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('verifySecretPin validates default PIN and custom PIN', () async {
      // Default fallback PIN is 7462 (primeros 4 dígitos de DNI 74629337)
      final defaultValid = await SessionService.verifySecretPin('7462');
      expect(defaultValid, isTrue);

      final wrongPin = await SessionService.verifySecretPin('9999');
      expect(wrongPin, isFalse);

      await SessionService.saveSession(
        dni: '77889900',
        secretPin: '4321',
      );

      final customValid = await SessionService.verifySecretPin('4321');
      expect(customValid, isTrue);
    });
  });

  group('AuthService & WhatsApp OTP Recovery Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});

      // Servidor simulado: la generación y validación del OTP es 100% server-side.
      AuthService.httpClient = MockClient((request) async {
        final action = request.url.queryParameters['action'] ?? '';
        final body = request.body.isNotEmpty
            ? jsonDecode(request.body) as Map<String, dynamic>
            : <String, dynamic>{};

        switch (action) {
          case 'send-otp':
            return http.Response(jsonEncode({'success': true, 'message': 'ok'}), 200);
          case 'verify-otp':
            if (body['code'] == '654321') {
              return http.Response(
                jsonEncode({'success': true, 'resetToken': 'test-reset-token'}),
                200,
              );
            }
            return http.Response(
              jsonEncode({'success': false, 'error': 'Código inválido o expirado (límite 5 min).'}),
              400,
            );
          case 'reset-password':
            if (body['token'] == 'test-reset-token') {
              return http.Response(jsonEncode({'success': true}), 200);
            }
            return http.Response(
              jsonEncode({'success': false, 'error': 'No autorizado'}),
              401,
            );
          case 'update-pin':
            if (body['token'] == 'session-jwt-token') {
              return http.Response(jsonEncode({'success': true}), 200);
            }
            return http.Response(
              jsonEncode({'success': false, 'error': 'No autorizado'}),
              401,
            );
          default:
            return http.Response(jsonEncode({'success': false}), 404);
        }
      });
    });

    test('sendWhatsAppOtp y verifyRecoveryOtp validan contra el servidor y rechazan 123456', () async {
      const testDni = '74629337';
      const testPhone = '+51 976264949';

      final sendRes = await AuthService.sendWhatsAppOtp(
        dni: testDni,
        phone: testPhone,
        purpose: 'recuperación de contraseña',
      );
      expect(sendRes.success, isTrue);

      // Código de longitud incorrecta.
      final invalidLen = await AuthService.verifyRecoveryOtp(
        dni: testDni,
        phone: testPhone,
        code: '123',
      );
      expect(invalidLen.success, isFalse);
      expect(invalidLen.errorMessage, contains('6 dígitos'));

      // El código universal 123456 fue eliminado por seguridad: el servidor lo rechaza.
      final universalOtp = await AuthService.verifyRecoveryOtp(
        dni: testDni,
        phone: testPhone,
        code: '123456',
      );
      expect(universalOtp.success, isFalse);

      // Código válido emitido por el servidor -> devuelve el resetToken firmado.
      final validOtp = await AuthService.verifyRecoveryOtp(
        dni: testDni,
        phone: testPhone,
        code: '654321',
      );
      expect(validOtp.success, isTrue);
      expect(validOtp.token, 'test-reset-token');
    });

    test('resetPassword exige resetToken y valida la contraseña', () async {
      const testDni = '12345678';

      final tooShort = await AuthService.resetPassword(
        dni: testDni,
        newPassword: '123',
        resetToken: 'test-reset-token',
      );
      expect(tooShort.success, isFalse);
      expect(tooShort.errorMessage, contains('6 caracteres'));

      // Sin token de verificación no se permite el cambio.
      final noToken = await AuthService.resetPassword(
        dni: testDni,
        newPassword: 'newSecretPass2026',
        resetToken: '',
      );
      expect(noToken.success, isFalse);

      final validReset = await AuthService.resetPassword(
        dni: testDni,
        newPassword: 'newSecretPass2026',
        resetToken: 'test-reset-token',
      );
      expect(validReset.success, isTrue);
    });

    test('updatePin exige sesión y solo persiste el PIN si el servidor confirma', () async {
      const testDni = '12345678';

      // Rechaza PIN no numérico o de longitud incorrecta.
      final invalidLen = await AuthService.updatePin(dni: testDni, newPin: '123');
      expect(invalidLen, isFalse);

      final invalidAlpha = await AuthService.updatePin(dni: testDni, newPin: 'abcd');
      expect(invalidAlpha, isFalse);

      // Sin sesión JWT no se autoriza el cambio.
      final noSession = await AuthService.updatePin(dni: testDni, newPin: '5839');
      expect(noSession, isFalse);

      // Con sesión válida, el servidor confirma y se guarda el PIN.
      await SessionService.saveSession(dni: testDni, jwtToken: 'session-jwt-token');
      final success = await AuthService.updatePin(dni: testDni, newPin: '5839');
      expect(success, isTrue);

      final savedPin = await SessionService.getSecretPin();
      expect(savedPin, '5839');
      expect(await SessionService.verifySecretPin('5839'), isTrue);
    });
  });
}
