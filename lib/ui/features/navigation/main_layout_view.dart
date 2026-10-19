import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/theme/app_theme.dart';
import '../home/home_view.dart';
import '../reports/new_report_view.dart';
import '../auth/login_view.dart';
import '../../../data/services/session_service.dart';
import '../../../data/services/report_storage_service.dart';
import '../../../data/services/auth_service.dart';
import '../../../data/services/biometric_auth_service.dart';
import '../../../data/services/app_lock_service.dart';

class MainLayoutView extends StatefulWidget {
  const MainLayoutView({super.key});

  @override
  State<MainLayoutView> createState() => _MainLayoutViewState();
}

class _MainLayoutViewState extends State<MainLayoutView> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final screens = [
      HomeView(
        onNavigateToReports: () {
          setState(() {
            _currentIndex = 1;
          });
        },
      ),
      const _ReportsListView(),
      const _ProfileView(),
    ];

    return Scaffold(
      backgroundColor: AppColors.background,
      body: IndexedStack(
        index: _currentIndex,
        children: screens,
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(
            top: BorderSide(color: AppColors.border, width: 1.0),
          ),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) {
            setState(() {
              _currentIndex = index;
            });
          },
          backgroundColor: AppColors.surface,
          selectedItemColor: AppColors.primaryRed,
          unselectedItemColor: AppColors.textMuted,
          type: BottomNavigationBarType.fixed,
          selectedLabelStyle: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
          unselectedLabelStyle: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
          items: const [
            BottomNavigationBarItem(
              icon: Padding(
                padding: EdgeInsets.only(bottom: 4.0),
                child: Icon(Icons.cancel_outlined, size: 22),
              ),
              label: 'Inicio',
            ),
            BottomNavigationBarItem(
              icon: Padding(
                padding: EdgeInsets.only(bottom: 4.0),
                child: Icon(Icons.segment_rounded, size: 22),
              ),
              label: 'Reportes',
            ),
            BottomNavigationBarItem(
              icon: Padding(
                padding: EdgeInsets.only(bottom: 4.0),
                child: Icon(Icons.person_outline_rounded, size: 22),
              ),
              label: 'Perfil',
            ),
          ],
        ),
      ),
    );
  }
}

/// Vista dinámica de historial de reportes reales conectados a la base de datos Supabase
class _ReportsListView extends StatefulWidget {
  const _ReportsListView();

  @override
  State<_ReportsListView> createState() => _ReportsListViewState();
}

class _ReportsListViewState extends State<_ReportsListView> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _reports = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadReports();
  }

  Future<void> _loadReports() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final reports = await ReportStorageService.loadAllReports();
      if (mounted) {
        setState(() {
          _reports = reports;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Error cargando historial de reportes: $e';
          _isLoading = false;
        });
      }
    }
  }

  Color _getBadgeColor(String type) {
    switch (type.toUpperCase()) {
      case 'ROBO':
        return AppColors.primaryRed;
      case 'ACCIDENTE':
        return const Color(0xFFFF8A65);
      case 'INCENDIO':
        return const Color(0xFFFF3D00);
      case 'GRESCA':
        return const Color(0xFFFF7043);
      case 'SECUESTRO':
        return const Color(0xFFD50000);
      case 'PERSONALIZADO':
        return const Color(0xFF00B0FF);
      default:
        return AppColors.accentOrange;
    }
  }

  String _formatDate(String? rawDate) {
    if (rawDate == null) return 'Reciente';
    try {
      final now = DateTime.now();
      final parsed = DateTime.parse(rawDate);
      DateTime dt;

      // Soporte inteligente para reportes guardados con hora local de Perú pero sufijo UTC (+00:00)
      final localWithoutTz = DateTime.parse(rawDate.replaceAll(RegExp(r'(\+00:00|Z)$'), ''));
      final diffWithoutTz = now.difference(localWithoutTz);

      if (parsed.isUtc && diffWithoutTz >= Duration.zero && diffWithoutTz < const Duration(hours: 4)) {
        dt = localWithoutTz;
      } else {
        dt = parsed.isUtc ? parsed.toLocal() : parsed;
      }

      final diff = now.difference(dt);

      if (diff.isNegative || diff.inSeconds < 45) {
        return 'Hace un momento';
      } else if (diff.inMinutes < 60) {
        return 'Hace ${diff.inMinutes} min';
      } else if (diff.inHours < 24) {
        return 'Hace ${diff.inHours} h';
      } else {
        return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      }
    } catch (_) {
      return rawDate;
    }
  }

  Map<String, dynamic> _getStatusConfig(dynamic idEstado, String? rawStatusName) {
    final id = idEstado is int ? idEstado : int.tryParse(idEstado?.toString() ?? '') ?? 1;
    final name = rawStatusName?.toString().toLowerCase().trim() ?? '';

    if (id == 3 || name.contains('atendido') || name.contains('resuelto') || name.contains('finalizado')) {
      return {
        'color': AppColors.accentGreen,
        'label': rawStatusName?.isNotEmpty == true ? rawStatusName! : 'Atendido',
        'icon': Icons.check_circle_rounded,
      };
    } else if (id == 2 || name.contains('camino') || name.contains('despach') || name.contains('atendiendo') || name.contains('proceso')) {
      return {
        'color': AppColors.accentOrange,
        'label': rawStatusName?.isNotEmpty == true ? rawStatusName! : 'En camino',
        'icon': Icons.directions_car_rounded,
      };
    } else {
      // Estado 1 / Pendiente / Enviado a la espera
      return {
        'color': AppColors.primaryRed,
        'label': rawStatusName?.isNotEmpty == true && rawStatusName != 'Enviado' ? rawStatusName! : 'Pendiente',
        'icon': Icons.access_time_rounded,
      };
    }
  }

  void _showReportDetails(Map<String, dynamic> item) {
    final typeName = item['tipo_incidencia']?['nombre'] ?? 'EMERGENCIA';
    final idEstado = item['id_estado'];
    final rawStatusName = item['estado_reporte']?['nombre']?.toString();
    final statusConfig = _getStatusConfig(idEstado, rawStatusName);
    final statusColor = statusConfig['color'] as Color;
    final statusName = statusConfig['label'] as String;
    final statusIcon = statusConfig['icon'] as IconData;
    final dateStr = _formatDate(item['fecha_hora']);
    final desc = item['descripcion'] ?? 'Sin descripción';
    final address = item['direccion_texto'] ?? 'Ubicación móvil GPS';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: _getBadgeColor(typeName), width: 1.5),
        ),
        title: Row(
          children: [
            Icon(Icons.shield, color: _getBadgeColor(typeName), size: 24),
            const SizedBox(width: 8),
            Text(
              'Reporte #REP-${item['id_reporte']}',
              style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _getBadgeColor(typeName).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: _getBadgeColor(typeName)),
                ),
                child: Text(
                  typeName,
                  style: GoogleFonts.chakraPetch(fontWeight: FontWeight.bold, color: _getBadgeColor(typeName)),
                ),
              ),
              const SizedBox(height: 12),
              Text('Fecha y Hora:', style: GoogleFonts.inter(fontSize: 11, color: AppColors.textMuted)),
              Text(dateStr, style: GoogleFonts.inter(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text('Ubicación registrada:', style: GoogleFonts.inter(fontSize: 11, color: AppColors.textMuted)),
              Text(address, style: GoogleFonts.inter(fontSize: 13, color: Colors.white)),
              const SizedBox(height: 8),
              Text('Estado:', style: GoogleFonts.inter(fontSize: 11, color: AppColors.textMuted)),
              Row(
                children: [
                  Icon(statusIcon, color: statusColor, size: 14),
                  const SizedBox(width: 4),
                  Text(statusName, style: GoogleFonts.inter(fontSize: 13, color: statusColor, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(color: AppColors.border),
              const SizedBox(height: 8),
              Text('Contenido del Despacho:', style: GoogleFonts.inter(fontSize: 11, color: AppColors.textMuted)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  desc,
                  style: GoogleFonts.inter(fontSize: 12, color: AppColors.textPrimary),
                ),
              ),
              if (item['fotos'] is List && (item['fotos'] as List).isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Evidencias Fotográficas (${(item['fotos'] as List).length}):',
                  style: GoogleFonts.inter(fontSize: 11, color: AppColors.textMuted),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 110,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: (item['fotos'] as List).length,
                    itemBuilder: (ctx, fIdx) {
                      final fItem = (item['fotos'] as List)[fIdx];
                      final dataStr = (fItem is Map ? fItem['data'] : null)?.toString() ?? '';
                      Widget imgChild;
                      if (dataStr.startsWith('data:image')) {
                        try {
                          final b64 = dataStr.split(',').last;
                          imgChild = Image.memory(
                            base64Decode(b64),
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, color: Colors.grey),
                          );
                        } catch (_) {
                          imgChild = const Icon(Icons.broken_image, color: Colors.grey);
                        }
                      } else {
                        imgChild = const Icon(Icons.image, color: Colors.grey);
                      }

                      return Container(
                        width: 110,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.border),
                          color: AppColors.background,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: imgChild,
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('CERRAR', style: GoogleFonts.inter(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: Text(
          'HISTORIAL DE REPORTES',
          style: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
            color: Colors.white,
          ),
        ),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.accentOrange),
            tooltip: 'Actualizar',
            onPressed: _loadReports,
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline, color: AppColors.primaryRed),
            tooltip: 'Nuevo Reporte',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NewReportView()),
              );
              _loadReports();
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.accentOrange),
            )
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.cloud_off_rounded, size: 54, color: AppColors.primaryRed),
                        const SizedBox(height: 16),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(color: Colors.white70, fontSize: 14),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: _loadReports,
                          icon: const Icon(Icons.refresh),
                          label: const Text('REINTENTAR'),
                          style: ElevatedButton.styleFrom(backgroundColor: AppColors.surfaceVariant),
                        ),
                      ],
                    ),
                  ),
                )
              : _reports.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32.0),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.surface,
                                border: Border.all(color: AppColors.border),
                              ),
                              child: const Icon(
                                Icons.shield_outlined,
                                size: 48,
                                color: AppColors.textMuted,
                              ),
                            ),
                            const SizedBox(height: 18),
                            Text(
                              'No tienes reportes registrados aún',
                              style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Los incidentes y alertas de emergencia que envíes con tu cuenta quedarán registrados aquí.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      color: AppColors.accentOrange,
                      backgroundColor: AppColors.surface,
                      onRefresh: _loadReports,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _reports.length,
                        itemBuilder: (context, index) {
                          final item = _reports[index];
                          final typeName = item['tipo_incidencia']?['nombre'] ?? 'EMERGENCIA';
                          final idEstado = item['id_estado'];
                          final rawStatusName = item['estado_reporte']?['nombre']?.toString();
                          final statusConfig = _getStatusConfig(idEstado, rawStatusName);
                          final statusColor = statusConfig['color'] as Color;
                          final statusName = statusConfig['label'] as String;
                          final statusIcon = statusConfig['icon'] as IconData;
                          final badgeColor = _getBadgeColor(typeName);
                          final dateText = _formatDate(item['fecha_hora']);
                          final desc = item['descripcion'] ?? 'Sin descripción';
                          final id = item['id_reporte']?.toString() ?? '${index + 1}';

                          return InkWell(
                            onTap: () => _showReportDetails(item),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: statusColor.withValues(alpha: 0.35),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: badgeColor.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(6),
                                          border: Border.all(color: badgeColor.withValues(alpha: 0.5)),
                                        ),
                                        child: Text(
                                          typeName,
                                          style: GoogleFonts.chakraPetch(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w800,
                                            color: badgeColor,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        dateText,
                                        style: GoogleFonts.inter(fontSize: 11, color: AppColors.textMuted),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    desc,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.inter(fontSize: 13, color: AppColors.textPrimary),
                                  ),
                                  if ((item['fotos'] is List && (item['fotos'] as List).isNotEmpty) || desc.contains('📸') || desc.contains('fotografía')) ...[
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        const Icon(Icons.photo_camera_rounded, size: 13, color: AppColors.accentOrange),
                                        const SizedBox(width: 4),
                                        Text(
                                          'Evidencia fotográfica adjunta',
                                          style: GoogleFonts.inter(
                                            fontSize: 11,
                                            color: AppColors.accentOrange,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                  const SizedBox(height: 12),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        'REP-$id',
                                        style: GoogleFonts.chakraPetch(fontSize: 10, color: AppColors.textMuted),
                                      ),
                                      Row(
                                        children: [
                                          Icon(statusIcon, size: 12, color: statusColor),
                                          const SizedBox(width: 5),
                                          Text(
                                            statusName,
                                            style: GoogleFonts.inter(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w700,
                                              color: statusColor,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}

/// Vista dinámica de Perfil Ciudadano conectado a la sesión activa y almacenamiento seguro
class _ProfileView extends StatefulWidget {
  const _ProfileView();

  @override
  State<_ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<_ProfileView> {
  Map<String, String> _userData = {
    'dni': '...',
    'name': 'Cargando...',
    'phone': '...',
  };
  bool _isLoading = true;
  bool _hasBiometrics = false;
  bool _biometricsEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadUserProfile();
  }

  Future<void> _loadUserProfile() async {
    final user = await SessionService.getUserData();
    final hasBio = await BiometricAuthService.isBiometricsReady();
    final bioEnabled = await BiometricAuthService.isBiometricsEnabled();

    if (mounted) {
      setState(() {
        _userData = user;
        _hasBiometrics = hasBio;
        _biometricsEnabled = bioEnabled;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = _userData['name'] ?? 'Ciudadano';
    final dni = _userData['dni'] ?? 'No registrado';
    final phone = _userData['phone'] ?? '+51 999 999 999';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: Text(
          'PERFIL CIUDADANO',
          style: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
            color: Colors.white,
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: AppColors.accentOrange))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                children: [
                  Center(
                    child: Stack(
                      children: [
                        Container(
                          width: 90,
                          height: 90,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.surface,
                            border: Border.all(color: AppColors.accentOrange, width: 2),
                          ),
                          child: const Icon(
                            Icons.person,
                            size: 52,
                            color: AppColors.accentOrange,
                          ),
                        ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: AppColors.accentGreen,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.check, size: 14, color: Colors.black),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    name,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.accentGreen.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.accentGreen.withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      'CIUDADANO VERIFICADO',
                      style: GoogleFonts.chakraPetch(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: AppColors.accentGreen,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildProfileTile(Icons.badge_outlined, 'Documento Nacional (DNI)', dni),
                  _buildProfileTile(Icons.phone_outlined, 'Teléfono Vinculado (WhatsApp)', phone),
                  _buildProfileTile(
                    Icons.lock_clock_outlined,
                    'PIN Secreto',
                    '•••• (PIN de seguridad protegido)',
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.accentOrange.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppColors.accentOrange.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.edit, color: AppColors.accentOrange, size: 14),
                          const SizedBox(width: 4),
                          Text(
                            'CAMBIAR',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: AppColors.accentOrange,
                            ),
                          ),
                        ],
                      ),
                    ),
                    onTap: () => _showChangePinOptionsDialog(context, dni, phone),
                  ),
                  if (_hasBiometrics)
                    _buildProfileTile(
                      Icons.fingerprint,
                      'Acceso con Huella Digital',
                      _biometricsEnabled
                          ? 'Activado (Inicio rápido y cancelar alertas)'
                          : 'Desactivado (Usar solo PIN)',
                      trailing: Transform.scale(
                        scale: 0.85,
                        child: Switch(
                          value: _biometricsEnabled,
                          activeThumbColor: AppColors.accentBlue,
                          onChanged: (val) async {
                            if (val) {
                              AppLockService().isAuthenticatingBiometrics = true;
                              bool ok = false;
                              try {
                                ok = await BiometricAuthService.authenticate(
                                  reason: 'Coloca tu huella digital para activar esta opción',
                                );
                              } finally {
                                await Future.delayed(const Duration(milliseconds: 300));
                                AppLockService().isAuthenticatingBiometrics = false;
                              }
                              if (!ok) return;
                            } else {
                              final pinConfirmed = await _showDisableBiometricsPinDialog();
                              if (!pinConfirmed) return;
                            }
                            await BiometricAuthService.setBiometricsEnabled(val);
                            if (mounted) {
                              setState(() => _biometricsEnabled = val);
                              if (!val && mounted) {
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Acceso con huella digital desactivado.',
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
                        ),
                      ),
                    ),
                  const SizedBox(height: 32),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await SessionService.clearSession();
                      if (!context.mounted) return;
                      Navigator.of(context).pushAndRemoveUntil(
                        MaterialPageRoute(builder: (_) => const LoginView()),
                        (route) => false,
                      );
                    },
                    icon: const Icon(Icons.logout, color: AppColors.primaryRed),
                    label: Text(
                      'CERRAR SESIÓN',
                      style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: AppColors.primaryRed),
                    ),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      side: const BorderSide(color: AppColors.primaryRed),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Future<bool> _showDisableBiometricsPinDialog() async {
    final pinController = TextEditingController();
    String? errorMessage;
    bool confirmed = false;

    if (!mounted) return false;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDState) {
            return AlertDialog(
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: AppColors.accentOrange, width: 1.5),
              ),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColors.accentOrange.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.fingerprint, color: AppColors.accentOrange, size: 24),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Desactivar Huella',
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
                    Text(
                      'Ingresa tu PIN secreto de seguridad (4 dígitos) para confirmar la desactivación del acceso con huella digital.',
                      style: GoogleFonts.inter(fontSize: 13, color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: pinController,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      obscureText: true,
                      obscuringCharacter: '•',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 22,
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
                      setDState(() {
                        errorMessage = 'Ingresa tu PIN';
                      });
                      return;
                    }
                    final isValid = await SessionService.verifySecretPin(pin);
                    if (!isValid) {
                      setDState(() {
                        errorMessage = 'PIN secreto incorrecto';
                      });
                      return;
                    }
                    confirmed = true;
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
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

    return confirmed;
  }

  void _showChangePinOptionsDialog(BuildContext context, String dni, String phone) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: AppColors.accentOrange, width: 1.5),
      ),
      builder: (bctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(Icons.pin, color: AppColors.accentOrange, size: 24),
                    const SizedBox(width: 10),
                    Text(
                      'Cambiar PIN Secreto',
                      style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Selecciona una opción para actualizar tu PIN secreto de seguridad (4 dígitos):',
                  style: GoogleFonts.inter(fontSize: 13, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 20),
                // Opción 1: Conozco mi PIN actual
                InkWell(
                  onTap: () {
                    Navigator.of(bctx).pop();
                    _showChangePinWithCurrentPinDialog(context, dni);
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.accentOrange.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.password_rounded, color: AppColors.accentOrange, size: 24),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Conozco mi PIN actual',
                                style: GoogleFonts.inter(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Ingresa tu PIN actual y luego escribe tu nuevo PIN.',
                                style: GoogleFonts.inter(fontSize: 12, color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: AppColors.accentOrange),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // Opción 2: Olvidé mi PIN
                InkWell(
                  onTap: () {
                    Navigator.of(bctx).pop();
                    _showChangePinWithOtpDialog(context, dni, phone);
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.accentGreen.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.mark_chat_unread_outlined, color: AppColors.accentGreen, size: 24),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Olvidé mi PIN',
                                style: GoogleFonts.inter(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Recupera enviando un código a tu WhatsApp.',
                                style: GoogleFonts.inter(fontSize: 12, color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: AppColors.accentGreen),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showChangePinWithCurrentPinDialog(BuildContext context, String dni) {
    final currentPinController = TextEditingController();
    final newPinController = TextEditingController();
    final confirmPinController = TextEditingController();
    String? errorMessage;
    bool isSaving = false;

    showDialog(
      context: context,
      builder: (dctx) {
        return StatefulBuilder(
          builder: (context, setDState) {
            return AlertDialog(
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: AppColors.accentOrange, width: 1.5),
              ),
              title: Row(
                children: [
                  const Icon(Icons.password_rounded, color: AppColors.accentOrange, size: 24),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Cambiar PIN Actual',
                      style: GoogleFonts.inter(
                        fontSize: 17,
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
                    if (errorMessage != null) ...[
                      Container(
                        padding: const EdgeInsets.all(8),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: AppColors.error.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.error),
                        ),
                        child: Text(
                          errorMessage!,
                          style: GoogleFonts.inter(fontSize: 12, color: AppColors.error),
                        ),
                      ),
                    ],
                    Text(
                      'PIN ACTUAL (4 DÍGITOS)',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textSecondary,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: currentPinController,
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      maxLength: 4,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(fontSize: 18, color: Colors.white, letterSpacing: 6),
                      decoration: const InputDecoration(counterText: '', hintText: '••••'),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'NUEVO PIN (4 DÍGITOS)',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textSecondary,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: newPinController,
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      maxLength: 4,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(fontSize: 18, color: Colors.white, letterSpacing: 6),
                      decoration: const InputDecoration(counterText: '', hintText: '••••'),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'CONFIRMAR NUEVO PIN',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textSecondary,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: confirmPinController,
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      maxLength: 4,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(fontSize: 18, color: Colors.white, letterSpacing: 6),
                      decoration: const InputDecoration(counterText: '', hintText: '••••'),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dctx).pop(),
                  child: Text(
                    'CANCELAR',
                    style: GoogleFonts.inter(color: AppColors.textSecondary, fontWeight: FontWeight.bold),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.accentOrange),
                  onPressed: isSaving
                      ? null
                      : () async {
                          final curPin = currentPinController.text.trim();
                          final nPin = newPinController.text.trim();
                          final cPin = confirmPinController.text.trim();

                          if (curPin.length != 4 || nPin.length != 4 || cPin.length != 4) {
                            setDState(() => errorMessage = 'Todos los campos deben tener 4 dígitos.');
                            return;
                          }

                          if (int.tryParse(nPin) == null) {
                            setDState(() => errorMessage = 'El PIN debe ser numérico.');
                            return;
                          }

                          if (nPin != cPin) {
                            setDState(() => errorMessage = 'El nuevo PIN y su confirmación no coinciden.');
                            return;
                          }

                          final pinSecError = AuthService.validatePinSecurity(nPin);
                          if (pinSecError != null) {
                            setDState(() => errorMessage = pinSecError);
                            return;
                          }

                          setDState(() {
                            isSaving = true;
                            errorMessage = null;
                          });

                          final isCurrentValid = await SessionService.verifySecretPin(curPin);
                          if (!isCurrentValid) {
                            setDState(() {
                              isSaving = false;
                              errorMessage = 'El PIN actual ingresado es incorrecto.';
                            });
                            return;
                          }

                          final pinOk = await AuthService.updatePin(dni: dni, newPin: nPin);
                          if (!pinOk) {
                            setDState(() {
                              isSaving = false;
                              errorMessage =
                                  'No se pudo actualizar el PIN en la Central. Verifique su conexión e intente de nuevo.';
                            });
                            return;
                          }

                          if (dctx.mounted) Navigator.of(dctx).pop();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  '¡PIN secreto actualizado con éxito!',
                                  style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: Colors.black),
                                ),
                                backgroundColor: AppColors.accentGreen,
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                            setState(() {});
                          }
                        },
                  child: isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2),
                        )
                      : Text(
                          'CAMBIAR PIN',
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

  void _showChangePinWithOtpDialog(BuildContext context, String dni, String phone) {
    final otpController = TextEditingController();
    final newPinController = TextEditingController();
    final confirmPinController = TextEditingController();

    int step = 1; // 1: Enviar OTP, 2: Ingresar OTP, 3: Nuevo PIN
    bool isProcessing = false;
    String? errorMessage;

    String maskPhone(String p) {
      final digits = p.replaceAll(RegExp(r'\D'), '');
      if (digits.length >= 7) {
        final start = digits.substring(0, 3);
        final end = digits.substring(digits.length - 2);
        return '+$start *** **$end';
      }
      return p;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dctx) {
        return StatefulBuilder(
          builder: (context, setDState) {
            return AlertDialog(
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: const BorderSide(color: AppColors.accentOrange, width: 1.5),
              ),
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
                          ? Icons.phonelink_ring_outlined
                          : step == 2
                              ? Icons.mark_chat_unread_outlined
                              : Icons.pin_outlined,
                      color: AppColors.accentOrange,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      step == 1
                          ? 'Recuperar PIN'
                          : step == 2
                              ? 'Validar WhatsApp'
                              : 'Nuevo PIN',
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
                          padding: const EdgeInsets.all(8),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: AppColors.error.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.error),
                          ),
                          child: Text(
                            errorMessage!,
                            style: GoogleFonts.inter(fontSize: 12, color: AppColors.error),
                          ),
                        ),
                      ],
                      if (step == 1) ...[
                        Text(
                          'Enviaremos un código de seguridad de 6 dígitos a tu WhatsApp vinculado (${maskPhone(phone)}) para autorizar el restablecimiento de tu PIN secreto.',
                          style: GoogleFonts.inter(fontSize: 13, color: AppColors.textSecondary),
                        ),
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceElevated,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.phone_outlined, color: AppColors.accentGreen, size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  phone,
                                  style: GoogleFonts.chakraPetch(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else if (step == 2) ...[
                        Text(
                          'Ingresa el código de 6 dígitos que enviamos a tu WhatsApp (${maskPhone(phone)}):',
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
                          decoration: const InputDecoration(hintText: '••••••', counterText: ''),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: isProcessing
                              ? null
                              : () async {
                                  setDState(() {
                                    isProcessing = true;
                                    errorMessage = null;
                                  });
                                  await AuthService.sendWhatsAppOtp(
                                    dni: dni,
                                    phone: phone,
                                    purpose: 'cambio de PIN secreto',
                                  );
                                  setDState(() {
                                    isProcessing = false;
                                    errorMessage = 'Código reenviado a tu WhatsApp';
                                  });
                                },
                          child: Text(
                            '¿No te llegó el código? Reenviar por WhatsApp',
                            style: GoogleFonts.inter(fontSize: 12, color: AppColors.accentOrange),
                          ),
                        ),
                      ] else if (step == 3) ...[
                        Text(
                          'Código verificado. Ingresa tu nuevo PIN secreto de 4 dígitos para cancelar alarmas:',
                          style: GoogleFonts.inter(fontSize: 13, color: AppColors.textSecondary),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'NUEVO PIN (4 DÍGITOS)',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textSecondary,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: newPinController,
                          keyboardType: TextInputType.number,
                          obscureText: true,
                          maxLength: 4,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(fontSize: 20, color: Colors.white, letterSpacing: 8),
                          decoration: const InputDecoration(counterText: '', hintText: '••••'),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'CONFIRMAR NUEVO PIN',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textSecondary,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: confirmPinController,
                          keyboardType: TextInputType.number,
                          obscureText: true,
                          maxLength: 4,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(fontSize: 20, color: Colors.white, letterSpacing: 8),
                          decoration: const InputDecoration(counterText: '', hintText: '••••'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dctx).pop(),
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
                            setDState(() {
                              isProcessing = true;
                              errorMessage = null;
                            });

                            final res = await AuthService.sendWhatsAppOtp(
                              dni: dni,
                              phone: phone,
                              purpose: 'cambio de PIN secreto',
                            );

                            setDState(() {
                              isProcessing = false;
                              if (res.success) {
                                step = 2;
                              } else {
                                errorMessage = res.errorMessage ?? 'Error al enviar código.';
                              }
                            });
                          } else if (step == 2) {
                            final code = otpController.text.trim();
                            if (code.length != 6) {
                              setDState(() => errorMessage = 'El código debe tener 6 dígitos.');
                              return;
                            }

                            setDState(() {
                              isProcessing = true;
                              errorMessage = null;
                            });

                            final verifyRes = await AuthService.verifyRecoveryOtp(
                              dni: dni,
                              phone: phone,
                              code: code,
                            );

                            setDState(() {
                              isProcessing = false;
                              if (verifyRes.success) {
                                step = 3;
                              } else {
                                errorMessage = verifyRes.errorMessage ?? 'Código inválido o expirado.';
                              }
                            });
                          } else if (step == 3) {
                            final nPin = newPinController.text.trim();
                            final cPin = confirmPinController.text.trim();

                            if (nPin.length != 4 || cPin.length != 4) {
                              setDState(() => errorMessage = 'El PIN debe tener 4 dígitos.');
                              return;
                            }

                            if (int.tryParse(nPin) == null) {
                              setDState(() => errorMessage = 'El PIN debe ser numérico.');
                              return;
                            }

                            if (nPin != cPin) {
                              setDState(() => errorMessage = 'Los pines ingresados no coinciden.');
                              return;
                            }

                            final pinSecError = AuthService.validatePinSecurity(nPin);
                            if (pinSecError != null) {
                              setDState(() => errorMessage = pinSecError);
                              return;
                            }

                            setDState(() {
                              isProcessing = true;
                              errorMessage = null;
                            });

                            final pinOk = await AuthService.updatePin(dni: dni, newPin: nPin);
                            if (!pinOk) {
                              setDState(() {
                                isProcessing = false;
                                errorMessage =
                                    'No se pudo guardar el PIN. Verifique su conexión e intente nuevamente.';
                              });
                              return;
                            }

                            if (dctx.mounted) Navigator.of(dctx).pop();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '¡Nuevo PIN secreto establecido con éxito!',
                                    style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: Colors.black),
                                  ),
                                  backgroundColor: AppColors.accentGreen,
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                              setState(() {});
                            }
                          }
                        },
                  child: isProcessing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2),
                        )
                      : Text(
                          step == 1
                              ? 'ENVIAR CÓDIGO'
                              : step == 2
                                  ? 'VERIFICAR CÓDIGO'
                                  : 'GUARDAR PIN',
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

  Widget _buildProfileTile(
    IconData icon,
    String title,
    String subtitle, {
    VoidCallback? onTap,
    Widget? trailing,
  }) {
    final content = Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.accentOrange, size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                Text(
                  subtitle,
                  style: GoogleFonts.inter(fontSize: 12, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );

    if (onTap != null) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: content,
      );
    }
    return content;
  }
}
