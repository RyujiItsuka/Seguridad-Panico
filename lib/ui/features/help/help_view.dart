import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/theme/app_theme.dart';

/// Pregunta frecuente de ayuda ciudadana.
class _Faq {
  final String pregunta;
  final String respuesta;
  final IconData icono;

  const _Faq({
    required this.pregunta,
    required this.respuesta,
    required this.icono,
  });
}

/// Vista de Ayuda y Preguntas Frecuentes para el ciudadano.
///
/// Es el equivalente móvil de la base de conocimiento del panel web, pero con
/// redacción para el vecino (sin tecnicismos). Cubre las fallas reales ya
/// atendidas: ubicación, alerta no despachada, gesto que no se detecta,
/// falsos positivos, app cerrada por el sistema y consumo de batería.
///
/// Al final ofrece el contacto humano por WhatsApp, que es el canal real del
/// ciudadano: la app NO abre un portal de tickets (el ciudadano no usa Jira).
class HelpView extends StatelessWidget {
  const HelpView({super.key});

  /// Número de la Central de Video Vigilancia (Perú).
  ///
  /// Se usa para el canal HUMANO de consulta del ciudadano. No es el número de
  /// despacho de alertas: ese lo resuelve el servidor al enviar la alerta.
  static const String _numeroCentral = '51976264949';

  static const List<_Faq> _preguntas = [
    _Faq(
      icono: Icons.location_off_rounded,
      pregunta: 'La app no muestra mi ubicación, ¿qué hago?',
      respuesta:
          'Revisa que la app tenga permiso de ubicación:\n\n'
          'Ajustes → Aplicaciones → Alerta Pisco → Permisos → Ubicación → "Permitir siempre".\n\n'
          'También activa la ubicación de alta precisión del teléfono. Si estás dentro de una '
          'casa o edificio, acércate a una ventana o sal a un espacio abierto para que el GPS '
          'encuentre los satélites. Puede tardar unos segundos.',
    ),
    _Faq(
      icono: Icons.smart_button_rounded,
      pregunta: '¿Cómo activo la alerta de emergencia?',
      respuesta:
          'Mantén presionado el botón rojo principal de la pantalla de inicio. Si tu teléfono '
          'tiene configurado el gesto de pánico, también puedes pulsar rápidamente el botón de '
          'encendido 3 veces seguidas, incluso con la pantalla apagada.\n\n'
          'Antes de enviar, la app muestra una cuenta regresiva para que puedas cancelar si fue '
          'un error. Si la dejas correr, la alerta se envía sola a la Central.',
    ),
    _Faq(
      icono: Icons.wifi_off_rounded,
      pregunta: 'Envié la alerta pero no sé si llegó',
      respuesta:
          'La app te confirma en pantalla cuando la alerta fue enviada, y queda registrada en la '
          'pestaña "Reportes" con su estado (Pendiente, En camino o Atendido).\n\n'
          'Necesitas tener internet (datos móviles o wifi) para que la alerta salga. Si no tienes '
          'señal, la app intenta enviarla de nuevo; acércate a un lugar con cobertura y revisa el '
          'estado en "Reportes".',
    ),
    _Faq(
      icono: Icons.battery_alert_rounded,
      pregunta: 'La app se cierra sola o gasta mucha batería',
      respuesta:
          'Algunos teléfonos apagan las apps que trabajan en segundo plano para ahorrar batería, '
          'y eso puede cortar el envío de la alerta.\n\n'
          'Para evitarlo: Ajustes → Batería → busca "Alerta Pisco" y elige "Sin restricciones" o '
          '"No optimizar". En algunos teléfonos también aparece como "Inicio automático" o '
          '"Ejecución en segundo plano": actívalo.',
    ),
    _Faq(
      icono: Icons.gesture_rounded,
      pregunta: 'El gesto de pánico no se activa cuando lo hago',
      respuesta:
          'El gesto requiere 3 pulsaciones rápidas seguidas del botón de encendido, no una sola. '
          'Deben ser rápidas, con menos de un segundo entre una y otra.\n\n'
          'Si aun así no responde, coméntalo al personal de la Central: puede que el detector '
          'necesite calibrarse para tu tipo de teléfono.',
    ),
    _Faq(
      icono: Icons.error_outline_rounded,
      pregunta: 'La alerta se activó sola sin que yo la hiciera',
      respuesta:
          'Puede pasar si guardas el teléfono en el bolsillo o lo mueves con fuerza. La app tiene '
          'una cuenta regresiva justo para esto: si la alerta se activa sin querer, pulsa '
          '"CANCELAR" durante el conteo.\n\n'
          'Si te ocurre con frecuencia, avisa a la Central para ajustar la sensibilidad del '
          'detector en tu dispositivo.',
    ),
    _Faq(
      icono: Icons.sim_card_alert_rounded,
      pregunta: 'No puedo instalar la app o no me deja actualizarla',
      respuesta:
          'Si ya tenías una versión instalada, desinstálala antes de instalar la nueva.\n\n'
          'Si el teléfono avisa que la instalación está bloqueada, ve a Ajustes → Seguridad (o '
          'Aplicaciones) y permite "Instalar apps de origen desconocido" para el navegador o la '
          'app desde donde te compartieron el archivo.',
    ),
  ];

  /// Abre WhatsApp con el número de la Central.
  ///
  /// Es el canal humano real del ciudadano. Se usa `wa.me` para que abra la app
  /// de WhatsApp ya instalada, con el mensaje de consulta precargado.
  Future<void> _contactarCentral(BuildContext context) async {
    final uri = Uri.parse(
      'https://wa.me/$_numeroCentral'
      '?text=${Uri.encodeComponent('Hola, necesito ayuda con la app Alerta Pisco.')}',
    );
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) {
        _mostrarErrorContacto(context);
      }
    } catch (_) {
      if (context.mounted) _mostrarErrorContacto(context);
    }
  }

  void _mostrarErrorContacto(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'No se pudo abrir WhatsApp. Marca al +51 976 264 949.',
          style: GoogleFonts.inter(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        backgroundColor: AppColors.surfaceElevated,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
          'AYUDA Y SOPORTE',
          style: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
            color: Colors.white,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Encabezado explicativo
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.accentBlue.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.help_outline_rounded, color: AppColors.accentBlue, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '¿Necesitas ayuda?',
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Revisa las respuestas más comunes. Si no encuentras tu caso, escríbenos por WhatsApp.',
                        style: GoogleFonts.inter(fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'PREGUNTAS FRECUENTES',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: AppColors.textMuted,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 10),

          // Lista de preguntas desplegables
          ..._preguntas.map((f) => _TarjetaFaq(faq: f)),

          const SizedBox(height: 20),

          // Contacto humano
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.accentGreen.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.support_agent_rounded, color: AppColors.accentGreen, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '¿No resolviste tu duda?',
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Contacta a la Central de Video Vigilancia. Atendemos consultas sobre el uso de la app las 24 horas.',
                  style: GoogleFonts.inter(fontSize: 12, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 14),
                ElevatedButton.icon(
                  onPressed: () => _contactarCentral(context),
                  icon: const Icon(Icons.chat_rounded, size: 18),
                  label: Text(
                    'ESCRIBIR POR WHATSAPP',
                    style: GoogleFonts.inter(fontWeight: FontWeight.w800, letterSpacing: 0.5),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accentGreen,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 10),
                // Aviso importante: este canal es para consultas, no para urgencias.
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.primaryRed.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.primaryRed.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: AppColors.primaryRed, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Para una emergencia real, usa el botón de pánico, no este chat.',
                          style: GoogleFonts.inter(
                            fontSize: 11.5,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// Tarjeta desplegable de una pregunta frecuente.
class _TarjetaFaq extends StatefulWidget {
  final _Faq faq;

  const _TarjetaFaq({required this.faq});

  @override
  State<_TarjetaFaq> createState() => _TarjetaFaqState();
}

class _TarjetaFaqState extends State<_TarjetaFaq> {
  bool _abierta = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _abierta ? AppColors.accentBlue.withValues(alpha: 0.4) : AppColors.border,
        ),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _abierta = !_abierta),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    widget.faq.icono,
                    size: 20,
                    color: _abierta ? AppColors.accentBlue : AppColors.textMuted,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.faq.pregunta,
                      style: GoogleFonts.inter(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1.35,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _abierta ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 22,
                    color: AppColors.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_abierta)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(color: AppColors.border, height: 1),
                  const SizedBox(height: 12),
                  Text(
                    widget.faq.respuesta,
                    style: GoogleFonts.inter(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
