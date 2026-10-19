import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/services/whatsapp_api_service.dart';
import '../../../data/services/gps_location_service.dart';

class NewReportView extends StatefulWidget {
  final String initialCategory;

  const NewReportView({
    super.key,
    this.initialCategory = 'ROBO',
  });

  @override
  State<NewReportView> createState() => _NewReportViewState();
}

class _NewReportViewState extends State<NewReportView> {
  final _descriptionController = TextEditingController();
  String _currentAddress = 'Obteniendo GPS del dispositivo...';
  double _lat = -13.71450;
  double _lon = -76.20320;
  double? _accuracy;
  bool _isRefreshingGps = false;
  bool _isSubmitting = false;

  final List<XFile> _capturedImages = [];
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _refreshLocation();
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _refreshLocation() async {
    setState(() {
      _isRefreshingGps = true;
    });

    try {
      final position = await GpsLocationService.getCurrentLocation();
      if (mounted) {
        if (position != null) {
          final address = await GpsLocationService.getAddressFromCoordinates(position.latitude, position.longitude);
          if (!mounted) return;
          setState(() {
            _lat = position.latitude;
            _lon = position.longitude;
            _accuracy = position.accuracy;
            _currentAddress = address ?? 'GPS Satelital Activo (Pisco)';
            _isRefreshingGps = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'GPS Satelital fijado (Margen: ±${position.accuracy.toStringAsFixed(1)}m)',
                style: GoogleFonts.inter(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              backgroundColor: AppColors.surfaceElevated,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              duration: const Duration(seconds: 2),
            ),
          );
        } else {
          setState(() {
            _currentAddress = 'Pisco, Ica - Ubicación móvil';
            _isRefreshingGps = false;
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isRefreshingGps = false;
        });
      }
    }
  }

  Future<void> _addEvidence() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: AppColors.border, width: 1),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ADJUNTAR EVIDENCIA FOTOGRÁFICA',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFFFF6D00),
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF6D00).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.camera_alt, color: Color(0xFFFF6D00)),
                ),
                title: Text(
                  'Tomar Foto con la Cámara',
                  style: GoogleFonts.inter(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  'Captura instantánea del suceso',
                  style: GoogleFonts.inter(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    final photo = await _picker.pickImage(
                      source: ImageSource.camera,
                      imageQuality: 85,
                      maxWidth: 1920,
                    );
                    if (photo != null) {
                      setState(() {
                        _capturedImages.add(photo);
                      });
                    }
                  } catch (e) {
                    _showErrorSnackbar('Error al abrir la cámara: $e');
                  }
                },
              ),
              const Divider(color: AppColors.border),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blueAccent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.photo_library, color: Colors.blueAccent),
                ),
                title: Text(
                  'Seleccionar de la Galería',
                  style: GoogleFonts.inter(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  'Elegir fotos existentes del teléfono',
                  style: GoogleFonts.inter(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    final photos = await _picker.pickMultiImage(
                      imageQuality: 85,
                      maxWidth: 1920,
                    );
                    if (photos.isNotEmpty) {
                      setState(() {
                        _capturedImages.addAll(photos);
                      });
                    }
                  } catch (e) {
                    _showErrorSnackbar('Error al abrir galería: $e');
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _removeEvidence(int index) {
    setState(() {
      _capturedImages.removeAt(index);
    });
  }

  void _showErrorSnackbar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: GoogleFonts.inter(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
        backgroundColor: AppColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _sendReportViaWhatsApp() async {
    if (_isSubmitting) return;

    final customDesc = _descriptionController.text.trim();
    final photoCount = _capturedImages.length;

    // Formato unificado y ordenado (mismo que las alertas automáticas).
    final customMsg = WhatsAppApiService.buildAlertMessage(
      headline: '⚠️ REPORTE CIUDADANO PERSONALIZADO ⚠️',
      address: _currentAddress,
      lat: _lat,
      lon: _lon,
      source: 'FORMULARIO PERSONALIZADO',
      description: customDesc,
      photoCount: photoCount,
    );

    setState(() => _isSubmitting = true);

    await WhatsAppApiService.sendAutomatedEmergencyAlert(
      category: 'PERSONALIZADO',
      customMessage: customMsg,
      source: 'FORMULARIO PERSONALIZADO',
      recipientNumber: WhatsAppApiService.defaultEmergencyRecipient,
      imagePaths: _capturedImages.map((f) => f.path).toList(),
      lat: _lat,
      lon: _lon,
      address: _currentAddress,
    );

    if (!mounted) return;
    setState(() => _isSubmitting = false);

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
            const Icon(Icons.check_circle, color: AppColors.accentGreen, size: 24),
            const SizedBox(width: 8),
            Text(
              'Reporte Registrado',
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
        content: Text(
          'El reporte fue registrado en el sistema y despachado a la Central de Video Vigilancia.',
          style: GoogleFonts.inter(fontSize: 14, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).pop();
            },
            child: Text(
              'ENTENDIDO',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.bold,
                color: AppColors.accentGreen,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Top Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.arrow_back, size: 20, color: AppColors.textPrimary),
                      onPressed: () => Navigator.of(context).pop(),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Text(
                    'NUEVO REPORTE',
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  // Category Badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF201614),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFFFF6D00),
                        width: 1.2,
                      ),
                    ),
                    child: Text(
                      widget.initialCategory,
                      style: GoogleFonts.chakraPetch(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: const Color(0xFFFF6D00),
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Form content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Incident Details
                    Text(
                      'DETALLES DEL INCIDENTE',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textSecondary,
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      height: 140,
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: TextField(
                        controller: _descriptionController,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          color: AppColors.textPrimary,
                        ),
                        decoration: InputDecoration(
                          hintText:
                              'Describe la situación... (ej. sospechoso con abrigo negro huyendo hacia el norte)',
                          hintStyle: GoogleFonts.inter(
                            fontSize: 13,
                            color: AppColors.textMuted,
                            height: 1.4,
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.all(16),
                        ),
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Add Evidence
                    Text(
                      'AGREGAR EVIDENCIA (FOTO/VIDEO)',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textSecondary,
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 80,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          // Botón Añadir con Cámara o Galería
                          InkWell(
                            onTap: _addEvidence,
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              width: 80,
                              height: 80,
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: const Color(0xFFFF6D00),
                                  width: 1.2,
                                ),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.camera_alt_outlined,
                                    color: Color(0xFFFF6D00),
                                    size: 24,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'AÑADIR',
                                    style: GoogleFonts.inter(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                      color: const Color(0xFFFF6D00),
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // Renderizado dinámico de fotos reales capturadas
                          ..._capturedImages.asMap().entries.map((entry) {
                            final idx = entry.key;
                            final xfile = entry.value;
                            return Padding(
                              padding: const EdgeInsets.only(left: 12),
                              child: Stack(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: Container(
                                      width: 80,
                                      height: 80,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF1B2230),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(color: AppColors.border),
                                      ),
                                      child: Image.file(
                                        File(xfile.path),
                                        fit: BoxFit.cover,
                                        errorBuilder: (context, error, stackTrace) => const Center(
                                          child: Icon(Icons.broken_image, color: Colors.grey, size: 24),
                                        ),
                                      ),
                                    ),
                                  ),
                                  // Etiqueta táctica FOTO #N
                                  Positioned(
                                    bottom: 4,
                                    left: 4,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.75),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        'FOTO #${idx + 1}',
                                        style: const TextStyle(fontSize: 8, color: Colors.white, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ),
                                  // Botón eliminar foto
                                  Positioned(
                                    top: 2,
                                    right: 2,
                                    child: GestureDetector(
                                      onTap: () => _removeEvidence(idx),
                                      child: Container(
                                        padding: const EdgeInsets.all(3),
                                        decoration: const BoxDecoration(
                                          color: Colors.redAccent,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(Icons.close, color: Colors.white, size: 12),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),

                          // Placeholder si no hay fotos todavía
                          if (_capturedImages.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(left: 12),
                              child: Container(
                                width: 160,
                                height: 80,
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: AppColors.surface.withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: AppColors.border.withValues(alpha: 0.5)),
                                ),
                                child: Center(
                                  child: Text(
                                    'Toque AÑADIR para capturar fotos con la cámara o elegirlas de su galería',
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.inter(
                                      fontSize: 10,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 28),

                    // Current GPS Location Card
                    Text(
                      'UBICACIÓN ACTUAL GPS',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textSecondary,
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Row(
                        children: [
                          // GPS Radar Icon
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFF0D2520),
                              border: Border.all(
                                color: AppColors.accentGreen.withValues(alpha: 0.5),
                              ),
                            ),
                            child: const Center(
                              child: Icon(
                                Icons.my_location,
                                color: AppColors.accentGreen,
                                size: 18,
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _currentAddress,
                                  style: GoogleFonts.inter(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Lat: ${_lat.toStringAsFixed(5)}, Lon: ${_lon.toStringAsFixed(5)}${_accuracy != null ? " • ±${_accuracy!.toStringAsFixed(1)}m" : ""}',
                                  style: GoogleFonts.chakraPetch(
                                    fontSize: 11,
                                    color: _accuracy != null && _accuracy! <= 15 ? AppColors.accentGreen : AppColors.textSecondary,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: _isRefreshingGps ? null : _refreshLocation,
                            icon: _isRefreshingGps
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(0xFFFF6D00),
                                    ),
                                  )
                                : const Icon(
                                    Icons.refresh_rounded,
                                    color: Color(0xFFFF6D00),
                                    size: 22,
                                  ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 32),

                    // WhatsApp Action Button
                    ElevatedButton(
                      onPressed: _isSubmitting ? null : _sendReportViaWhatsApp,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accentGreen,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: AppColors.accentGreen.withValues(alpha: 0.6),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        elevation: 8,
                        shadowColor: AppColors.accentGreen.withValues(alpha: 0.4),
                      ),
                      child: _isSubmitting
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 26,
                                  height: 26,
                                  decoration: const BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Center(
                                    child: Icon(
                                      Icons.chat_bubble_outline_rounded,
                                      color: AppColors.accentGreen,
                                      size: 16,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  'ENVIAR REPORTE VÍA WHATSAPP',
                                  style: GoogleFonts.inter(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.8,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                    ),

                    const SizedBox(height: 48),
                  ],
                ),
              ),
            ),

            // Footer note
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: const BoxDecoration(
                color: Color(0xFF0F141E),
                border: Border(
                  top: BorderSide(color: AppColors.borderSubtle),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.cell_tower_rounded,
                    color: Color(0xFFFF6D00),
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'El mensaje será enviado automáticamente a la Central de Cámaras para despacho inmediato.',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
