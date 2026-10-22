@Tags(['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:alerta_ciudadana/data/services/reniec_service.dart';

/// Prueba end-to-end contra la Edge Function `reniec` desplegada en Supabase.
/// Requiere conexión a internet.
///
/// Está etiquetada como `e2e`: NO se ejecuta en integración continua, porque
/// depende de la red y del entorno desplegado. Para correrla localmente:
///   flutter test --tags e2e
void main() {
  test(
    'consulta real a la Edge Function reniec y contraste ciego',
    () async {
      final result = await ReniecService.lookup('72845241');

      expect(result.isSuccess, isTrue,
          reason: 'Fallo RENIEC: ${result.status} ${result.message}');

      final identity = result.identity!;
      expect(identity.dni, '72845241');
      expect(identity.nombres.toUpperCase(), contains('JHEFERSON'));
      expect(identity.apellidos.toUpperCase(), contains('YALLE'));

      // El ciudadano escribe a mano (sin autocompletado) -> debe coincidir
      expect(
        ReniecService.matchesIdentity(
          identity: identity,
          nombres: 'Jheferson Eliel',
          apellidos: 'Yalle Jayo',
        ),
        isTrue,
        reason: 'La validación ciega debe aceptar el dato real del ciudadano',
      );

      // Discrepancia real -> debe bloquear
      expect(
        ReniecService.matchesIdentity(
          identity: identity,
          nombres: 'Jheferson Eliel Andres',
          apellidos: 'Yalle Jayo',
        ),
        isFalse,
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('DNI inexistente devuelve notFound', () async {
    final result = await ReniecService.lookup('99999999');
    expect(result.isSuccess, isFalse);
    expect(result.status, ReniecLookupStatus.notFound);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
