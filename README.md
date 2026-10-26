# Alerta Ciudadana — Aplicación móvil (Pisco)

Aplicación Android de alerta ciudadana. El ciudadano registra sus datos y sus
contactos, y ante una emergencia activa el botón de pánico: el teléfono inicia el
rastreo GPS, una cuenta regresiva y el despacho de la alerta a la Central de
Monitoreo y a los contactos de confianza.

## Repositorio oficial

Este es el **repositorio oficial** del proyecto y de la entrega:
`RyujiItsuka/Seguridad-Panico`.

El repositorio `titinashe123/Seguridad-Panico` conserva la versión anterior del
proyecto y se mantiene únicamente como referencia histórica: no recibe cambios ni
forma parte del flujo de integración.

## Componentes

| Componente | Tecnología | Función |
|---|---|---|
| Servicio nativo | Kotlin (`EmergencyForegroundService`) | Único dueño del GPS, la cuenta regresiva, el despacho y el rastreo |
| Aplicación | Flutter / Dart | Interfaz del ciudadano, registro, contactos y FAQ |
| Backend | Supabase (PostgreSQL + Edge Functions) | Autenticación, alertas y ruta de pánico hacia el proveedor de mensajería |

La credencial del proveedor de mensajería **nunca** viaja en el APK: la aplicación
llama a una Edge Function y es el servidor quien despacha la alerta.

## Control de cambios e integración continua

El proyecto trabaja con el modelo `main` / `desarrollo` / `cambio/*`, con pull
requests obligatorios y verificación automática antes de fusionar. El detalle
está en [`docs/GUIA-RAMAS-Y-CI.md`](docs/GUIA-RAMAS-Y-CI.md).

El pipeline (`.github/workflows/ci.yml`, tarea **Analizar y probar**) ejecuta
`flutter analyze` y `flutter test` en cada pull request y en cada envío a `main`
y `desarrollo`. Las pruebas etiquetadas `e2e` se ejecutan a mano porque dependen del
entorno desplegado.

## Requisitos

- Flutter 3.47 o superior (canal stable)
- Android SDK y JDK 17 o superior
- Android 8.0 (API 26) o superior en el dispositivo

## Compilación

```bash
flutter pub get
flutter analyze
flutter test --exclude-tags e2e
flutter build apk --release
```

El APK resultante queda en `build/app/outputs/flutter-apk/app-release.apk`.
