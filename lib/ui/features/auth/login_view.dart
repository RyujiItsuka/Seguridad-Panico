import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/tactical_shield_logo.dart';
import '../../../data/services/auth_service.dart';
import '../../../data/services/hardware_trigger_service.dart';
import '../../../data/services/session_service.dart';
import '../../../data/services/app_lock_service.dart';
import '../../../data/services/biometric_auth_service.dart';
import 'register_view.dart';
import '../navigation/main_layout_view.dart';

class LoginView extends StatefulWidget {
  const LoginView({super.key});

  @override
  State<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {
  final _dniController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;
  bool _canUseBiometrics = false;
  bool _isBiometricsHardwareReady = false;
  String? _enrolledDni;

  @override
  void initState() {
    super.initState();
    _dniController.addListener(_onDniInputChanged);
    // Asegurar que si el usuario está en la vista de login, el servicio de pánico en segundo plano
    // y cualquier alarma pendiente queden completamente detenidos
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      HardwareTriggerService().cancelEmergency();
      HardwareTriggerService().stopBackgroundService();
      await _initBiometricsAndDni();
    });
  }

  void _onDniInputChanged() {
    _updateBiometricState();
  }

  void _updateBiometricState() {
    final currentDni = _dniController.text.trim();
    final isMatchingEnrolled = _enrolledDni != null &&
        _enrolledDni!.isNotEmpty &&
        _enrolledDni == currentDni;

    final nextCanUse = _isBiometricsHardwareReady && isMatchingEnrolled;
    if (mounted && _canUseBiometrics != nextCanUse) {
      setState(() {
        _canUseBiometrics = nextCanUse;
      });
    }
  }

  Future<void> _initBiometricsAndDni() async {
    final enrolled = await BiometricAuthService.getEnrolledDni();
    _enrolledDni = enrolled;

    if (enrolled != null && enrolled.isNotEmpty && mounted) {
      _dniController.text = enrolled;
    } else {
      final lastDni = await SessionService.getLastDni();
      if (lastDni != null && lastDni.isNotEmpty && mounted) {
        _dniController.text = lastDni;
      }
    }

    final canBio = await BiometricAuthService.isBiometricsReady();
    final bioEnabled = await BiometricAuthService.isBiometricsEnabled();
    _isBiometricsHardwareReady = canBio && bioEnabled;

    _updateBiometricState();
  }

  @override
  void dispose() {
    _dniController.removeListener(_onDniInputChanged);
    _dniController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onLogin() async {
    if (_isLoading) return;

    final dni = _dniController.text.trim();
    final password = _passwordController.text.trim();

    if (dni.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Por favor ingresa tu número de DNI',
            style: GoogleFonts.inter(fontWeight: FontWeight.w600, color: Colors.white),
          ),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
      return;
    }

    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Por favor ingresa tu contraseña',
            style: GoogleFonts.inter(fontWeight: FontWeight.w600, color: Colors.white),
          ),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    final result = await AuthService.login(
      dni: dni,
      password: password,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result.success) {
      // SEGURIDAD: Vincular legítimamente este DNI al sensor de huella de este celular
      await BiometricAuthService.enrollUser(dni: dni);
      _enrolledDni = dni;
      _updateBiometricState();

      AppLockService().markJustLoggedIn();
      // Iniciar el servicio nativo de segundo plano sólo tras verificar autenticación
      await HardwareTriggerService().startBackgroundService();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainLayoutView()),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.errorMessage ?? 'Error al iniciar sesión',
            style: GoogleFonts.inter(
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
    }
  }

  void _onBiometricLogin() async {
    if (_isLoading) return;

    final targetDni = _dniController.text.trim();
    if (targetDni.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Ingresa tu DNI al menos una vez para vincular tu huella digital.',
            style: GoogleFonts.inter(fontWeight: FontWeight.w600, color: Colors.white),
          ),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
      return;
    }

    // SEGURIDAD ESTRICTA: La huella solo puede desbloquear el DNI previamente autenticado en este dispositivo
    final enrolled = await BiometricAuthService.getEnrolledDni();
    if (!mounted) return;
    if (enrolled == null || enrolled.isEmpty || enrolled != targetDni) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Esta huella no está vinculada al DNI $targetDni. Debe ingresar primero con la contraseña de esta cuenta.',
            style: GoogleFonts.inter(fontWeight: FontWeight.w600, color: Colors.white),
          ),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
      return;
    }

    AppLockService().isAuthenticatingBiometrics = true;
    bool authenticated = false;
    try {
      authenticated = await BiometricAuthService.authenticate(
        reason: 'Coloca tu huella digital para acceder a Alerta Ciudadana',
      );
    } finally {
      await Future.delayed(const Duration(milliseconds: 300));
      AppLockService().isAuthenticatingBiometrics = false;
    }

    if (!authenticated) {
      return;
    }

    setState(() => _isLoading = true);

    // Si ya existe sesión activa localmente para este mismo DNI, entrar directamente
    final isLogged = await SessionService.isLoggedIn();
    final sessionDni = (await SessionService.getUserData())['dni'];
    if (isLogged && sessionDni == targetDni) {
      AppLockService().markJustLoggedIn();
      await HardwareTriggerService().startBackgroundService();
      if (!mounted) return;
      setState(() => _isLoading = false);
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainLayoutView()),
      );
      return;
    }

    // Si no está la sesión en memoria, restaurar los datos del usuario vinculado
    final user = await AuthService.findUserByDni(targetDni);
    if (!mounted) return;
    setState(() => _isLoading = false);

    if (user != null) {
      final name = '${user['nombres'] ?? ''} ${user['apellidos'] ?? ''}'.trim();
      final phone = (user['telefono'] ?? user['phone'] ?? '').toString();
      final idPersona = user['id_persona'] is int ? user['id_persona'] as int : int.tryParse(user['id_persona']?.toString() ?? '');

      await SessionService.saveSession(
        dni: targetDni,
        name: name.isNotEmpty ? name : 'Ciudadano',
        phone: phone.isNotEmpty ? phone : '+51 999 999 999',
        idPersona: idPersona,
      );

      AppLockService().markJustLoggedIn();
      await HardwareTriggerService().startBackgroundService();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MainLayoutView()),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No se encontró una cuenta con el DNI $targetDni. Inicia con tu contraseña la primera vez.',
            style: GoogleFonts.inter(fontWeight: FontWeight.w600, color: Colors.white),
          ),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
    }
  }

  void _showForgotPasswordFlow() {
    final initialDni = _dniController.text.trim();
    final dniRecoveryController = TextEditingController(text: initialDni);
    final otpController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();

    int step = 1; // 1: DNI, 2: OTP, 3: Nueva Contraseña
    bool isProcessing = false;
    String? errorMessage;
    String targetPhone = '';
    String verifiedDni = '';
    String? resetToken;
    bool obscureNewPass = true;
    bool obscureConfirmPass = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (builderCtx, setDialogState) {
            String maskPhone(String p) {
              final digits = p.replaceAll(RegExp(r'\D'), '');
              if (digits.length >= 7) {
                final start = digits.substring(0, 3);
                final end = digits.substring(digits.length - 2);
                return '+$start *** **$end';
              }
              return p;
            }

            return AlertDialog(
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: AppColors.accentOrange, width: 1.5),
              ),
              titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 10),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.accentOrange.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      step == 1
                          ? Icons.lock_reset_rounded
                          : step == 2
                              ? Icons.mark_chat_unread_outlined
                              : Icons.key_rounded,
                      color: AppColors.accentOrange,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      step == 1
                          ? 'Recuperar Contraseña'
                          : step == 2
                              ? 'Verificación WhatsApp'
                              : 'Nueva Contraseña',
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (errorMessage != null) ...[
                        Container(
                          padding: const EdgeInsets.all(10),
                          margin: const EdgeInsets.only(bottom: 14),
                          decoration: BoxDecoration(
                            color: AppColors.error.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.error),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline, color: AppColors.error, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  errorMessage!,
                                  style: GoogleFonts.inter(fontSize: 12, color: AppColors.error),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (step == 1) ...[
                        Text(
                          'Ingresa tu DNI para localizar tu cuenta y enviarte un código de seguridad de 6 dígitos a tu WhatsApp vinculado.',
                          style: GoogleFonts.inter(fontSize: 13, color: AppColors.textSecondary),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'DOCUMENTO NACIONAL (DNI)',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textSecondary,
                            letterSpacing: 1.1,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: dniRecoveryController,
                          keyboardType: TextInputType.number,
                          maxLength: 8,
                          style: GoogleFonts.inter(fontSize: 15, color: Colors.white),
                          decoration: const InputDecoration(
                            counterText: '',
                            hintText: '8 dígitos de tu DNI',
                            prefixIcon: Icon(Icons.badge_outlined, color: AppColors.textMuted, size: 20),
                          ),
                        ),
                      ] else if (step == 2) ...[
                        Text(
                          'Hemos enviado un código de 6 dígitos a tu WhatsApp vinculado (${maskPhone(targetPhone)}).',
                          style: GoogleFonts.inter(fontSize: 13, color: AppColors.textSecondary),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.timer_outlined, size: 16, color: AppColors.accentOrange),
                            const SizedBox(width: 6),
                            Text(
                              'Válido por: 5 minutos',
                              style: GoogleFonts.chakraPetch(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppColors.accentOrange,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: otpController,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 8,
                            color: Colors.white,
                          ),
                          decoration: InputDecoration(
                            hintText: '••••••',
                            counterText: '',
                            hintStyle: GoogleFonts.inter(letterSpacing: 6, color: AppColors.textMuted),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: isProcessing
                              ? null
                              : () async {
                                  setDialogState(() {
                                    isProcessing = true;
                                    errorMessage = null;
                                  });
                                  await AuthService.sendWhatsAppOtp(
                                    dni: verifiedDni,
                                    phone: targetPhone,
                                    purpose: 'recuperar tu contraseña',
                                  );
                                  setDialogState(() {
                                    isProcessing = false;
                                    errorMessage = 'Código reenviado por WhatsApp';
                                  });
                                },
                          child: Text(
                            '¿No te llegó el código? Reenviar por WhatsApp',
                            style: GoogleFonts.inter(fontSize: 12, color: AppColors.accentOrange),
                          ),
                        ),
                      ] else if (step == 3) ...[
                        Text(
                          'Ingresa tu nueva contraseña para acceder a la aplicación.',
                          style: GoogleFonts.inter(fontSize: 13, color: AppColors.textSecondary),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'NUEVA CONTRASEÑA',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textSecondary,
                            letterSpacing: 1.1,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: newPasswordController,
                          obscureText: obscureNewPass,
                          style: GoogleFonts.inter(fontSize: 15, color: Colors.white),
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.lock_outline_rounded, color: AppColors.textMuted, size: 20),
                            suffixIcon: IconButton(
                              icon: Icon(
                                obscureNewPass ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                color: AppColors.textMuted,
                                size: 20,
                              ),
                              onPressed: () => setDialogState(() => obscureNewPass = !obscureNewPass),
                            ),
                            hintText: 'Mínimo 6 caracteres',
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'CONFIRMAR CONTRASEÑA',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textSecondary,
                            letterSpacing: 1.1,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: confirmPasswordController,
                          obscureText: obscureConfirmPass,
                          style: GoogleFonts.inter(fontSize: 15, color: Colors.white),
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.lock_outline_rounded, color: AppColors.textMuted, size: 20),
                            suffixIcon: IconButton(
                              icon: Icon(
                                obscureConfirmPass ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                color: AppColors.textMuted,
                                size: 20,
                              ),
                              onPressed: () => setDialogState(() => obscureConfirmPass = !obscureConfirmPass),
                            ),
                            hintText: 'Repite la nueva contraseña',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(),
                  child: Text(
                    'CANCELAR',
                    style: GoogleFonts.inter(color: AppColors.textSecondary, fontWeight: FontWeight.bold),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.accentOrange),
                  onPressed: isProcessing
                      ? null
                      : () async {
                          if (step == 1) {
                            final dni = dniRecoveryController.text.trim();
                            if (dni.length != 8 || int.tryParse(dni) == null) {
                              setDialogState(() {
                                errorMessage = 'Por favor ingresa un DNI válido de 8 dígitos.';
                              });
                              return;
                            }

                            setDialogState(() {
                              isProcessing = true;
                              errorMessage = null;
                            });

                            final user = await AuthService.findUserByDni(dni);
                            if (user == null) {
                              setDialogState(() {
                                isProcessing = false;
                                errorMessage = 'No se encontró una cuenta registrada con este DNI.';
                              });
                              return;
                            }

                            final phone = (user['telefono'] ?? user['phone'] ?? '').toString().trim();
                            if (phone.isEmpty) {
                              setDialogState(() {
                                isProcessing = false;
                                errorMessage = 'No hay teléfono vinculado a este DNI. Contacte a la central.';
                              });
                              return;
                            }

                            final otpRes = await AuthService.sendWhatsAppOtp(
                              dni: dni,
                              phone: phone,
                              purpose: 'recuperar tu contraseña',
                            );

                            if (!otpRes.success) {
                              setDialogState(() {
                                isProcessing = false;
                                errorMessage = otpRes.errorMessage ?? 'Error al enviar código.';
                              });
                              return;
                            }

                            setDialogState(() {
                              isProcessing = false;
                              verifiedDni = dni;
                              targetPhone = phone;
                              step = 2;
                              errorMessage = null;
                            });
                          } else if (step == 2) {
                            final code = otpController.text.trim();
                            if (code.length != 6) {
                              setDialogState(() {
                                errorMessage = 'El código debe tener 6 dígitos.';
                              });
                              return;
                            }

                            setDialogState(() {
                              isProcessing = true;
                              errorMessage = null;
                            });

                            final verifyRes = await AuthService.verifyRecoveryOtp(
                              dni: verifiedDni,
                              phone: targetPhone,
                              code: code,
                            );

                            if (!verifyRes.success) {
                              setDialogState(() {
                                isProcessing = false;
                                errorMessage = verifyRes.errorMessage ?? 'Código inválido o expirado.';
                              });
                              return;
                            }

                            setDialogState(() {
                              isProcessing = false;
                              resetToken = verifyRes.token;
                              step = 3;
                              errorMessage = null;
                            });
                          } else if (step == 3) {
                            final newPass = newPasswordController.text.trim();
                            final confirmPass = confirmPasswordController.text.trim();

                            if (newPass.length < 6) {
                              setDialogState(() {
                                errorMessage = 'La contraseña debe tener al menos 6 caracteres.';
                              });
                              return;
                            }

                            if (newPass != confirmPass) {
                              setDialogState(() {
                                errorMessage = 'Las contraseñas no coinciden.';
                              });
                              return;
                            }

                            setDialogState(() {
                              isProcessing = true;
                              errorMessage = null;
                            });

                            final resetRes = await AuthService.resetPassword(
                              dni: verifiedDni,
                              newPassword: newPass,
                              resetToken: resetToken ?? '',
                            );

                            if (!resetRes.success) {
                              setDialogState(() {
                                isProcessing = false;
                                errorMessage = resetRes.errorMessage ?? 'Error al actualizar contraseña.';
                              });
                              return;
                            }

                            if (dialogCtx.mounted) {
                              Navigator.of(dialogCtx).pop();
                            }

                            if (!mounted) return;
                            _dniController.text = verifiedDni;
                            _passwordController.text = newPass;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  '¡Contraseña actualizada con éxito! Ya puedes iniciar sesión.',
                                  style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: Colors.black),
                                ),
                                backgroundColor: AppColors.accentGreen,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
                        },
                  child: isProcessing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2),
                        )
                      : Text(
                          step == 1
                              ? 'ENVIAR CÓDIGO'
                              : step == 2
                                  ? 'VERIFICAR CÓDIGO'
                                  : 'GUARDAR CONTRASEÑA',
                          style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: Colors.black),
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Stack(
          children: [
            // Background city skyline painter
            Positioned(
              top: 40,
              left: 0,
              right: 0,
              height: 220,
              child: CustomPaint(
                painter: SkylineBackgroundPainter(),
              ),
            ),
            SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 36),

                  // Emblem & Branding
                  const Center(
                    child: TacticalShieldLogo(
                      size: 80,
                      iconSize: 38,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Center(
                    child: Text(
                      'AlertaCiudadana',
                      style: GoogleFonts.inter(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        color: AppColors.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Center(
                    child: Text(
                      'CENTRAL DE SEGURIDAD MÓVIL',
                      style: GoogleFonts.chakraPetch(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primaryRed,
                        letterSpacing: 2.2,
                      ),
                    ),
                  ),

                  const SizedBox(height: 48),

                  // DNI Field
                  Text(
                    'DNI',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _dniController,
                    keyboardType: TextInputType.number,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Ingresa tu DNI',
                      prefixIcon: Icon(
                        Icons.badge_outlined,
                        color: AppColors.textMuted,
                        size: 20,
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Password Field
                  Text(
                    'CONTRASEÑA',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: AppColors.textPrimary,
                    ),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(
                        Icons.lock_outline_rounded,
                        color: AppColors.textMuted,
                        size: 20,
                      ),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: AppColors.textMuted,
                          size: 20,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscurePassword = !_obscurePassword;
                          });
                        },
                      ),
                      hintText: '••••••••••••',
                    ),
                  ),

                  const SizedBox(height: 28),

                  // Login Button
                  ElevatedButton(
                    onPressed: _onLogin,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primaryRed,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      elevation: 6,
                      shadowColor: AppColors.primaryRed.withValues(alpha: 0.5),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.2,
                            ),
                          )
                        : Text(
                            'INICIAR SESIÓN',
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.2,
                              color: Colors.white,
                            ),
                          ),
                  ),

                  // Botón de Inicio con Huella Digital
                  if (_canUseBiometrics) ...[
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _isLoading ? null : _onBiometricLogin,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(
                          color: AppColors.accentBlue.withValues(alpha: 0.7),
                          width: 1.5,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        backgroundColor: AppColors.accentBlue.withValues(alpha: 0.08),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.fingerprint,
                            color: AppColors.accentBlue,
                            size: 24,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'INGRESAR CON HUELLA DIGITAL',
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                              color: AppColors.accentBlue,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Center(
                      child: Text(
                        '🔒 Huella vinculada a esta cuenta en este dispositivo',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: AppColors.textMuted,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 20),

                  // Actions row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      GestureDetector(
                        onTap: _showForgotPasswordFlow,
                        child: Text(
                          'Olvidé mi contraseña',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: AppColors.accentOrange,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const RegisterView(),
                            ),
                          );
                        },
                        child: Text(
                          'Crear cuenta',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: AppColors.accentOrange,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
