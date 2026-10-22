import 'package:flutter/material.dart';
import 'core/theme/app_theme.dart';
import 'data/services/app_lock_service.dart';
import 'data/services/session_service.dart';
import 'ui/features/auth/login_view.dart';
import 'ui/features/navigation/main_layout_view.dart';
import 'ui/features/security/security_unlock_view.dart';

/// Clave global de navegación para redirecciones y cambio de cuenta
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var loggedIn = await SessionService.isLoggedIn();
  // Si hay una sesión local, confirmar contra el servidor que no fue revocada
  // (por reporte de robo o por exposición de tokens). Si el servidor dice que
  // ya no es válida, isSessionValidOnServer() limpia la sesión y devuelve false.
  if (loggedIn) {
    loggedIn = await SessionService.isSessionValidOnServer();
  }
  await AppLockService().initOnLaunch(isLoggedIn: loggedIn);
  runApp(AlertaCiudadanaApp(isLoggedIn: loggedIn));
}

class AlertaCiudadanaApp extends StatefulWidget {
  final bool isLoggedIn;
  const AlertaCiudadanaApp({super.key, required this.isLoggedIn});

  @override
  State<AlertaCiudadanaApp> createState() => _AlertaCiudadanaAppState();
}

class _AlertaCiudadanaAppState extends State<AlertaCiudadanaApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      AppLockService().onAppPaused();
    } else if (state == AppLifecycleState.resumed) {
      AppLockService().onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'AlertaCiudadana',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: widget.isLoggedIn ? const MainLayoutView() : const LoginView(),
      builder: (context, child) {
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => AppLockService().recordUserActivity(),
          onPointerMove: (_) => AppLockService().recordUserActivity(),
          onPointerUp: (_) => AppLockService().recordUserActivity(),
          child: ValueListenableBuilder<bool>(
            valueListenable: AppLockService().isLockedNotifier,
            builder: (context, isLocked, _) {
              return Stack(
                children: [
                  child ?? const SizedBox.shrink(),
                  if (isLocked)
                    const Positioned.fill(
                      child: SecurityUnlockView(),
                    ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
