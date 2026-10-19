import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/services/app_lock_service.dart';
import '../../../data/services/auth_service.dart';
import '../../../data/services/biometric_auth_service.dart';
import '../../../data/services/session_service.dart';


/// Pantalla de Bloqueo de Seguridad
/// Se superpone inmediatamente al regresar de segundo plano o abrir la aplicación con sesión iniciada.
/// Solicita huella digital o PIN secreto de 4 dígitos para otorgar acceso.
class SecurityUnlockView extends StatefulWidget {
  const SecurityUnlockView({super.key});

  @override
  State<SecurityUnlockView> createState() => _SecurityUnlockViewState();
}

class _SecurityUnlockViewState extends State<SecurityUnlockView> with SingleTickerProviderStateMixin {
  String _pin = '';
  String? _errorMessage;
  String _userName = 'Ciudadano';
  String _userDni = '';
  bool _isAuthenticatingBiometrics = false;
  bool _hasBiometrics = false;
  late AnimationController _shakeController;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _loadUser();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkBiometricsAndPrompt();
    });
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    final data = await SessionService.getUserData();
    var fullName = data['name'] ?? 'Ciudadano';
    var rawDni = data['dni'] ?? '';

    // Si el DNI no está en la sesión actual, consultar el último DNI o el DNI biométrico
    if (rawDni.isEmpty) {
      final lastDni = await SessionService.getLastDni();
      final enrolledDni = await BiometricAuthService.getEnrolledDni();
      rawDni = (lastDni != null && lastDni.isNotEmpty)
          ? lastDni
          : (enrolledDni ?? '');
    }

    // Si el nombre no está configurado o es el predeterminado 'Ciudadano', buscar los datos reales del usuario
    if (rawDni.isNotEmpty && (fullName.isEmpty || fullName == 'Ciudadano')) {
      final user = await AuthService.findUserByDni(rawDni);
      if (user != null) {
        final nombres = (user['nombres'] ?? '').toString().trim();
        final apellidos = (user['apellidos'] ?? '').toString().trim();
        final foundName = '$nombres $apellidos'.trim();
        if (foundName.isNotEmpty) {
          fullName = foundName;
          await SessionService.saveSession(
            dni: rawDni,
            name: fullName,
            phone: (user['telefono'] ?? user['phone'] ?? '').toString(),
            idPersona: user['id_persona'] is int
                ? user['id_persona'] as int
                : int.tryParse(user['id_persona']?.toString() ?? ''),
          );
        }
      }
    }

    final firstName = fullName.trim().split(' ').first;

    if (mounted) {
      setState(() {
        _userName = firstName.isNotEmpty ? firstName : 'Ciudadano';
        if (rawDni.length >= 8) {
          _userDni = '${rawDni.substring(0, 2)}••••${rawDni.substring(rawDni.length - 2)}';
        } else {
          _userDni = rawDni;
        }
      });
    }
  }

  Future<void> _checkBiometricsAndPrompt() async {
    final available = await BiometricAuthService.isBiometricsReady();
    if (mounted) {
      setState(() => _hasBiometrics = available);
    }
    if (available) {
      // Pequeño retardo para dar tiempo a la vista a renderizarse
      await Future.delayed(const Duration(milliseconds: 300));
      if (mounted && AppLockService().isLocked && !AppLockService().justUnlocked) {
        _authenticateWithBiometrics();
      }
    }
  }

  Future<void> _authenticateWithBiometrics() async {
    if (_isAuthenticatingBiometrics) return;
    if (AppLockService().justUnlocked) return;
    setState(() {
      _isAuthenticatingBiometrics = true;
      _errorMessage = null;
    });
    AppLockService().isAuthenticatingBiometrics = true;

    try {
      final success = await BiometricAuthService.authenticate(
        reason: 'Coloca tu huella digital para desbloquear Alerta Ciudadana',
      );
      if (success && mounted) {
        HapticFeedback.mediumImpact();
        AppLockService().unlock();
      }
    } catch (e) {
      developer.log('Error en autenticación biométrica: $e', name: 'SecurityUnlockView');
    } finally {
      // Pequeño retardo para dar tiempo a que Android termine de procesar el cierre del diálogo del sistema
      await Future.delayed(const Duration(milliseconds: 300));
      AppLockService().isAuthenticatingBiometrics = false;
      if (mounted) {
        setState(() => _isAuthenticatingBiometrics = false);
      }
    }
  }

  void _onKeyPressed(String digit) {
    if (_pin.length >= 4) return;
    HapticFeedback.lightImpact();

    setState(() {
      _pin += digit;
      _errorMessage = null;
    });

    if (_pin.length == 4) {
      _verifyPin(_pin);
    }
  }

  void _onBackspace() {
    if (_pin.isNotEmpty) {
      HapticFeedback.selectionClick();
      setState(() {
        _pin = _pin.substring(0, _pin.length - 1);
        _errorMessage = null;
      });
    }
  }

  Future<void> _verifyPin(String enteredPin) async {
    final isValid = await SessionService.verifySecretPin(enteredPin);
    if (!mounted) return;

    if (isValid) {
      HapticFeedback.mediumImpact();
      AppLockService().unlock();
    } else {
      HapticFeedback.heavyImpact();
      _shakeController.forward(from: 0.0);
      setState(() {
        _errorMessage = 'PIN incorrecto. Intenta nuevamente.';
        _pin = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // Al presionar atrás en la pantalla de bloqueo, minimizar la app
        SystemNavigator.pop();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Cabecera superior
                        Column(
                          children: [
                            const SizedBox(height: 12),
                            // Escudo / candado de seguridad con resplandor
                            Container(
                              width: 68,
                              height: 68,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.surface,
                                border: Border.all(color: AppColors.accentOrange, width: 2),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.accentOrange.withValues(alpha: 0.25),
                                    blurRadius: 20,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.shield_rounded,
                                size: 36,
                                color: AppColors.accentOrange,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              'ALERTA CIUDADANA',
                              style: GoogleFonts.chakraPetch(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.2,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'PISCO - SEGURIDAD Y VIGILANCIA',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.8,
                                color: AppColors.textMuted,
                              ),
                            ),
                            const SizedBox(height: 18),
                            // Saludo al usuario
                            Text(
                              'Hola, $_userName',
                              style: GoogleFonts.inter(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                            if (_userDni.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                'DNI: $_userDni',
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                            const SizedBox(height: 6),
                            Text(
                              'Ingresa tu huella digital o PIN secreto',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: AppColors.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 24),
                            // Indicadores de 4 dígitos PIN
                            AnimatedBuilder(
                              animation: _shakeController,
                              builder: (context, child) {
                                final double offset = (_shakeController.value < 0.5
                                        ? _shakeController.value
                                        : (1.0 - _shakeController.value)) *
                                    16 *
                                    (_shakeController.value < 0.25 || _shakeController.value > 0.75 ? 1 : -1);
                                return Transform.translate(
                                  offset: Offset(offset, 0),
                                  child: child,
                                );
                              },
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: List.generate(4, (index) {
                                  final isFilled = index < _pin.length;
                                  return Container(
                                    width: 18,
                                    height: 18,
                                    margin: const EdgeInsets.symmetric(horizontal: 10),
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: isFilled ? AppColors.accentOrange : AppColors.surface,
                                      border: Border.all(
                                        color: isFilled ? AppColors.accentOrange : AppColors.border,
                                        width: 2,
                                      ),
                                      boxShadow: isFilled
                                          ? [
                                              BoxShadow(
                                                color: AppColors.accentOrange.withValues(alpha: 0.5),
                                                blurRadius: 8,
                                                spreadRadius: 1,
                                              ),
                                            ]
                                          : null,
                                    ),
                                  );
                                }),
                              ),
                            ),
                            const SizedBox(height: 12),
                            // Mensaje de error
                            if (_errorMessage != null)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                decoration: BoxDecoration(
                                  color: AppColors.primaryRed.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: AppColors.primaryRed.withValues(alpha: 0.4)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.error_outline_rounded, color: AppColors.primaryRed, size: 16),
                                    const SizedBox(width: 6),
                                    Text(
                                      _errorMessage!,
                                      style: GoogleFonts.inter(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.primaryRed,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            else
                              const SizedBox(height: 30),
                          ],
                        ),

                        // Teclado numérico táctil estilizado
                        Column(
                          children: [
                            _buildKeypadRow(['1', '2', '3']),
                            const SizedBox(height: 12),
                            _buildKeypadRow(['4', '5', '6']),
                            const SizedBox(height: 12),
                            _buildKeypadRow(['7', '8', '9']),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                // Botón de huella digital
                                _buildSpecialKey(
                                  icon: Icons.fingerprint_rounded,
                                  color: _hasBiometrics ? AppColors.accentOrange : AppColors.textMuted,
                                  onTap: _hasBiometrics ? _authenticateWithBiometrics : null,
                                ),
                                const SizedBox(width: 20),
                                _buildNumberKey('0'),
                                const SizedBox(width: 20),
                                // Botón de borrar
                                _buildSpecialKey(
                                  icon: Icons.backspace_outlined,
                                  color: Colors.white70,
                                  onTap: _onBackspace,
                                ),
                              ],
                            ),
                          ],
                        ),

                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildKeypadRow(List<String> digits) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildNumberKey(digits[0]),
        const SizedBox(width: 20),
        _buildNumberKey(digits[1]),
        const SizedBox(width: 20),
        _buildNumberKey(digits[2]),
      ],
    );
  }

  Widget _buildNumberKey(String digit) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _onKeyPressed(digit),
        borderRadius: BorderRadius.circular(36),
        splashColor: AppColors.accentOrange.withValues(alpha: 0.2),
        highlightColor: AppColors.surfaceVariant,
        child: Container(
          width: 68,
          height: 68,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.surface,
            border: Border.all(color: AppColors.border, width: 1.2),
          ),
          alignment: Alignment.center,
          child: Text(
            digit,
            style: GoogleFonts.chakraPetch(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSpecialKey({
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(36),
        splashColor: color.withValues(alpha: 0.2),
        highlightColor: AppColors.surfaceVariant,
        child: Container(
          width: 68,
          height: 68,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.surface.withValues(alpha: 0.6),
            border: Border.all(color: AppColors.border.withValues(alpha: 0.6), width: 1),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 28, color: color),
        ),
      ),
    );
  }
}
