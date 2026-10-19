import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/alert_category.dart';
import '../../../data/services/sensor_emergency_service.dart';
import '../../../data/services/hardware_trigger_service.dart';
import '../../../data/services/location_tracking_service.dart';
import '../../../data/services/session_service.dart';
import '../../../data/services/gps_location_service.dart';
import '../../../data/services/report_storage_service.dart';
import '../../../data/services/biometric_auth_service.dart';
import '../../../data/services/app_lock_service.dart';
import '../emergency/emergency_countdown_dialog.dart';
import '../reports/new_report_view.dart';

class HomeView extends StatefulWidget {
  final VoidCallback? onNavigateToReports;

  const HomeView({super.key, this.onNavigateToReports});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  final SensorEmergencyService _sensorService = SensorEmergencyService();
  final HardwareTriggerService _hardwareService = HardwareTriggerService();
  String _citizenName = '';

  @override
  void initState() {
    super.initState();
    _loadCitizenInfo();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _initHardwareAndSensors();
    _checkPermissionsOnStartup();
  }

  void _checkPermissionsOnStartup() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Solo solicitar permisos si no los tiene ya concedidos.
      // Esto evita volver a preguntar al regresar a la app con sesión activa.
      final hasPermission = await GpsLocationService.hasLocationPermission();
      if (hasPermission) return;
      if (!mounted) return;
      await GpsLocationService.checkAndPromptLocationPermission(context);
    });
  }

  void _initHardwareAndSensors() {
    // 1. Iniciar monitoreo continuo de sensores antirrobo (Acelerómetro y Giroscopio)
    _sensorService.startMonitoring(
      onTriggered: (reason, source) {
        // Ruta única: el SERVICIO NATIVO es el dueño del GPS, despacho y rastreo.
        // Al invocar startEmergencyFlow, el nativo arranca su cuenta regresiva,
        // fija el GPS y notifica a Flutter (onTriggered) para mostrar el diálogo
        // de cancelación. Evita el doble envío y el segundo id_reporte.
        HardwareTriggerService().startEmergencyFlow('ROBO', 'ANTIRROBO: $reason');
      },
    );

    // 2. Iniciar escucha del botón físico de encendido (3 pulsaciones consecutivas), sensores de fondo y servicio persistente
    _hardwareService.initialize(
      onTriggered: (source, [alertType]) {
        if (!mounted) return;
        final type = alertType ?? 'ROBO';
        final label = source.contains('sensor')
            ? 'SENSOR ANTIRROBO (ARREBATO / FORCEJEO)'
            : 'BOTÓN DE ENCENDIDO (3+ PULSACIONES SEGUIDAS)';
        EmergencyCountdownDialog.show(
          context,
          alertType: type,
          source: label,
          isDirectWhatsAppApi: true,
        );
      },
      onEmergencyDispatched: (alertType, source, nativeSuccess, reportId) async {
        if (!mounted) return;

        final isRobo = alertType.trim().toUpperCase() == 'ROBO';
        final isSecuestro = alertType.trim().toUpperCase() == 'SECUESTRO';
        final hasLiveTracking = isRobo || isSecuestro;

        // El despacho y la transmisión los realizó el SERVICIO NATIVO.
        // Aquí solo reflejamos el estado para la UI y usamos el id_reporte OFICIAL.
        final String officialId =
            reportId != null ? 'REP-$reportId' : 'ALT-${DateTime.now().millisecondsSinceEpoch}';

        if (hasLiveTracking) {
          // Mostrar el banner de rastreo. La transmisión de puntos a Supabase
          // la hace el servicio nativo; este servicio NO publica coordenadas.
          LocationTrackingService().startTracking(alertId: officialId);
        }

        // Refrescar la lista de reportes (el nativo ya creó el registro en Supabase)
        ReportStorageService.loadAllReports();

        // Cerrar el diálogo de cuenta regresiva si sigue abierto (el nativo confirmó)
        EmergencyCountdownDialog.dismissOpen();

        if (mounted) {
          _showAlreadyDispatchedDialog(context, alertType, source);
        }
      },
      onOpenStopTrackingDialog: () {
        if (!mounted) return;
        _showStopTrackingDialog(context, LocationTrackingService());
      },
    );
  }

  void _loadCitizenInfo() async {
    final data = await SessionService.getUserData();
    final fullName = data['name'] ?? '';
    final firstName = fullName.trim().split(' ').first;
    if (mounted) {
      setState(() {
        _citizenName = firstName.isNotEmpty ? firstName : fullName;
      });
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _sensorService.stopMonitoring();
    super.dispose();
  }

  void _triggerDirectSosAlert() {
    // Ruta única: el SERVICIO NATIVO es el dueño del GPS, despacho y rastreo.
    // Al invocar startEmergencyFlow, el nativo arranca su cuenta regresiva,
    // fija el GPS y notifica a Flutter (onTriggered) para mostrar el diálogo
    // de cancelación. Evita el doble envío y el segundo id_reporte.
    HardwareTriggerService().startEmergencyFlow('ROBO', 'BOTÓN ROJO PRINCIPAL');
  }

  static bool _isAlreadyDispatchedDialogOpen = false;

  void _showAlreadyDispatchedDialog(
    BuildContext context,
    String alertType,
    String source,
  ) {
    if (_isAlreadyDispatchedDialogOpen) return;
    _isAlreadyDispatchedDialogOpen = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.accentGreen, width: 1.5),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.accentGreen.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.check_circle, color: AppColors.accentGreen, size: 24),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Alerta Enviada con Éxito',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.accentGreen.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.emergency_share, color: AppColors.primaryRed, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        'TIPO: $alertType',
                        style: GoogleFonts.inter(
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryRed,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.settings_remote, color: AppColors.textSecondary, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        'ORIGEN: $source',
                        style: GoogleFonts.inter(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Tu alerta fue enviada automáticamente a la Central de Serenazgo con tus coordenadas GPS mientras la aplicación estaba cerrada o en segundo plano.\n\nLa Central de Monitoreo y Serenazgo ya cuenta con tu reporte y ubicación.',
              style: GoogleFonts.inter(
                fontSize: 13,
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentGreen,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              _isAlreadyDispatchedDialogOpen = false;
              Navigator.of(ctx).pop();
            },
            child: Text(
              'ENTENDIDO',
              style: GoogleFonts.inter(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    ).then((_) {
      _isAlreadyDispatchedDialogOpen = false;
    });
  }

  static bool _isStopTrackingDialogOpen = false;

  Future<void> _showStopTrackingDialog(
    BuildContext context,
    LocationTrackingService trackingService,
  ) async {
    if (_isStopTrackingDialogOpen) return;
    _isStopTrackingDialogOpen = true;
    final pinController = TextEditingController();
    String? errorMessage;
    final canUseBio = await BiometricAuthService.isBiometricsReady() &&
        await BiometricAuthService.isBiometricsEnabled();

    try {
      if (!context.mounted) return;
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                backgroundColor: AppColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: AppColors.primaryRed, width: 1.5),
                ),
                title: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppColors.primaryRed.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.lock_outline, color: AppColors.primaryRed, size: 22),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Desactivar Transmisión',
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (canUseBio) ...[
                        ElevatedButton.icon(
                          onPressed: () async {
                            AppLockService().isAuthenticatingBiometrics = true;
                            bool authenticated = false;
                            try {
                              authenticated = await BiometricAuthService.authenticate(
                                reason: 'Coloca tu huella digital para desactivar la transmisión de ubicación',
                              );
                            } finally {
                              await Future.delayed(const Duration(milliseconds: 300));
                              AppLockService().isAuthenticatingBiometrics = false;
                            }

                            if (authenticated) {
                              await trackingService.stopTracking();
                              if (dialogContext.mounted) {
                                Navigator.of(dialogContext).pop();
                              }
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Transmisión de ubicación finalizada con huella digital.',
                                      style: GoogleFonts.inter(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    backgroundColor: const Color(0xFF1E293B),
                                    behavior: SnackBarBehavior.floating,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                );
                              }
                            }
                          },
                          icon: const Icon(Icons.fingerprint, color: Colors.white, size: 24),
                          label: Text(
                            'DESACTIVAR CON HUELLA',
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.accentBlue,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            elevation: 3,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            const Expanded(child: Divider(color: Colors.white24)),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              child: Text(
                                'O CON PIN DE SEGURIDAD',
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textMuted,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            const Expanded(child: Divider(color: Colors.white24)),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                      Text(
                        'Ingresa tu PIN secreto de seguridad (4 dígitos) para detener la transmisión de ubicación.',
                        style: GoogleFonts.inter(fontSize: 13, color: AppColors.textSecondary),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: pinController,
                        keyboardType: TextInputType.number,
                        maxLength: 4,
                        obscureText: true,
                        obscuringCharacter: '•',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 8,
                          color: Colors.white,
                        ),
                        decoration: InputDecoration(
                          hintText: '••••',
                          counterText: '',
                          hintStyle: GoogleFonts.inter(letterSpacing: 4, color: AppColors.textMuted),
                          prefixIcon: const Icon(Icons.pin, color: AppColors.accentOrange, size: 18),
                          errorText: errorMessage,
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: Text(
                      'CANCELAR',
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.bold,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () async {
                      final pin = pinController.text.trim();
                      if (pin.isEmpty) {
                        setDialogState(() {
                          errorMessage = 'Ingresa tu PIN';
                        });
                        return;
                      }
                      final isValid = await SessionService.verifySecretPin(pin);
                      if (!isValid) {
                        setDialogState(() {
                          errorMessage = 'PIN secreto incorrecto';
                        });
                        return;
                      }
                      await trackingService.stopTracking();
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Transmisión de ubicación en tiempo real finalizada.',
                              style: GoogleFonts.inter(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            backgroundColor: const Color(0xFF1E293B),
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        );
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryRed,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: Text(
                      'DESACTIVAR',
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      _isStopTrackingDialogOpen = false;
    }
  }

  void _triggerCategoryEmergencyAlert(String categoryName) {
    if (categoryName.toUpperCase() == 'PERSONALIZADO') {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const NewReportView(initialCategory: 'PERSONALIZADO'),
        ),
      );
      return;
    }

    // Ruta única: el SERVICIO NATIVO es el dueño del GPS, despacho y rastreo.
    // El nativo arranca cuenta regresiva, fija el GPS y notifica a Flutter
    // (onTriggered) para mostrar el diálogo de cancelación. Evita el doble
    // envío y el segundo id_reporte.
    HardwareTriggerService().startEmergencyFlow(categoryName, 'BOTÓN CATEGORÍA ($categoryName)');
  }

  @override
  Widget build(BuildContext context) {
    final categories = AlertCategory.defaultCategories;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 22.0, vertical: 12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header with Status and Avatar
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: AppColors.accentGreen,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.accentGreen,
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'SISTEMA EN LÍNEA',
                            style: GoogleFonts.chakraPetch(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textMuted,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _citizenName.isNotEmpty ? 'Hola, $_citizenName' : 'Central de Seguridad',
                        style: GoogleFonts.inter(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  // Tactical Avatar
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFFFF6D00),
                        width: 1.8,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFFF6D00).withValues(alpha: 0.3),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: Container(
                        color: const Color(0xFF161F2E),
                        child: const Icon(
                          Icons.security_rounded,
                          color: Color(0xFFFF8A65),
                          size: 24,
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // Live GPS Tracking Banner (Only active for ROBO)
              AnimatedBuilder(
                animation: LocationTrackingService(),
                builder: (context, _) {
                  final trackingService = LocationTrackingService();
                  if (!trackingService.isTracking) {
                    return const SizedBox.shrink();
                  }

                  return Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF8B0000).withValues(alpha: 0.35),
                          AppColors.surface,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFFFF1744),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFFF1744).withValues(alpha: 0.25),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                color: Color(0xFFFF1744),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'SEGUIMIENTO GPS EN VIVO (ROBO)',
                                style: GoogleFonts.chakraPetch(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFFFF5252),
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFF1744).withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'TRANSMITIENDO',
                                style: GoogleFonts.chakraPetch(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFFFF5252),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(
                              Icons.wifi_tethering,
                              size: 14,
                              color: Color(0xFFFF8A80),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Transmitiendo tu ubicación en tiempo real a la Central de Video Vigilancia ...',
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFFFF8A80),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () => _showStopTrackingDialog(context, trackingService),
                            icon: const Icon(Icons.fingerprint, size: 16, color: Colors.white),
                            label: Text(
                              'DESACTIVAR TRANSMISIÓN (HUELLA O PIN)',
                              style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFC62828),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),

              const SizedBox(height: 24),

              // Central Pulsing Emergency Button
              Center(
                child: GestureDetector(
                  onTap: _triggerDirectSosAlert,
                  child: AnimatedBuilder(
                    animation: _pulseAnimation,
                    builder: (context, child) {
                      return SizedBox(
                        width: 220,
                        height: 220,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Outer ring 1
                            Container(
                              width: 210 * _pulseAnimation.value,
                              height: 210 * _pulseAnimation.value,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: AppColors.primaryRed.withValues(
                                    alpha: 0.15 * (2.0 - _pulseAnimation.value),
                                  ),
                                  width: 1.5,
                                ),
                              ),
                            ),
                            // Outer ring 2
                            Container(
                              width: 175 * _pulseAnimation.value,
                              height: 175 * _pulseAnimation.value,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: AppColors.primaryRed.withValues(
                                    alpha: 0.3 * (2.0 - _pulseAnimation.value),
                                  ),
                                  width: 1.5,
                                ),
                              ),
                            ),
                            // Inner Main Core Button
                            Container(
                              width: 142,
                              height: 142,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: const RadialGradient(
                                  colors: [
                                    Color(0xFFFF5252),
                                    Color(0xFFFF3B30),
                                    Color(0xFFC62828),
                                  ],
                                  stops: [0.2, 0.7, 1.0],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.primaryRed.withValues(alpha: 0.55),
                                    blurRadius: 30,
                                    spreadRadius: 6,
                                  ),
                                ],
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    width: 32,
                                    height: 32,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white.withValues(alpha: 0.8),
                                        width: 1.8,
                                      ),
                                    ),
                                    child: const Center(
                                      child: Icon(
                                        Icons.priority_high_rounded,
                                        size: 20,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'REPORTAR\nEMERGENCIA',
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.inter(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w900,
                                      color: Colors.white,
                                      letterSpacing: 0.8,
                                      height: 1.2,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),

              const SizedBox(height: 22),

              // Categories Header Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'CATEGORÍAS DE ALERTA',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textSecondary,
                      letterSpacing: 1.0,
                    ),
                  ),
                  Text(
                    'SELECCIONE UNA',
                    style: GoogleFonts.chakraPetch(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textMuted,
                      letterSpacing: 1.0,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // 2x3 Grid of Categories
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: categories.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 1.7,
                ),
                itemBuilder: (context, index) {
                  final cat = categories[index];
                  return InkWell(
                    onTap: () => _triggerCategoryEmergencyAlert(cat.name),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppColors.border,
                          width: 1.2,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Icon(
                                cat.icon,
                                color: cat.iconColor,
                                size: 22,
                              ),
                              const Icon(
                                Icons.north_east_rounded,
                                color: AppColors.textMuted,
                                size: 16,
                              ),
                            ],
                          ),
                          Text(
                            cat.name,
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),

              const SizedBox(height: 14),

              // Banner táctico para Reporte Libre / Personalizado
              InkWell(
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const NewReportView(initialCategory: 'PERSONALIZADO'),
                    ),
                  );
                },
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFFFF9100).withValues(alpha: 0.35),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFFF9100).withValues(alpha: 0.08),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF9100).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.edit_note_rounded,
                          color: Color(0xFFFF9100),
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'REPORTE PERSONALIZADO',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Describe una incidencia específica y adjunta evidencias',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.arrow_forward_ios_rounded,
                        color: Color(0xFFFF9100),
                        size: 16,
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
