import 'dart:io';

import 'package:flutter/material.dart' show BuildContext, Rect, RenderBox, Offset, MediaQuery;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import 'san.dart';

/// Historial del san en PDF (KLK Plus): quién pagó cada turno y a quién se entregó.
/// Se hace en el móvil; no pasa por ningún servidor.
Future<void> shareSanPdf(BuildContext context, San san, {required String chatTitle}) async {
  final bytes = await buildSanPdf(san, chatTitle: chatTitle);
  final dir = await getTemporaryDirectory();
  final safe = san.name.replaceAll(RegExp(r'[^A-Za-z0-9áéíóúñÁÉÍÓÚÑ _-]'), '').trim();
  final file = File('${dir.path}/San ${safe.isEmpty ? 'KLK' : safe}.pdf');
  await file.writeAsBytes(bytes, flush: true);
  if (!context.mounted) return;
  final box = context.findRenderObject() as RenderBox?;
  final screen = MediaQuery.sizeOf(context);
  final origin = box != null && box.hasSize
      ? box.localToGlobal(Offset.zero) & box.size
      : Rect.fromLTWH(screen.width / 2 - 1, screen.height / 2 - 1, 2, 2);
  await Share.shareXFiles([XFile(file.path, mimeType: 'application/pdf')],
      subject: 'Historial del san «${san.name}»', sharePositionOrigin: origin);
}

Future<List<int>> buildSanPdf(San san, {required String chatTitle}) async {
  final doc = pw.Document(title: 'San ${san.name}', author: 'KLK messenger');
  final verde = PdfColor.fromInt(0xFF1F7A4D);
  final gris = PdfColor.fromInt(0xFF6B7280);
  final fecha = DateFormat('d/M/y');
  final now = DateTime.now();

  String pay(SanPay p) => switch (p) {
        SanPay.paid => 'Pagó',
        SanPay.claimed => 'Dice que pagó',
        SanPay.none => 'Falta',
      };
  String out(int r) => switch (san.outOf(r)) {
        'got' => 'Entregado y recibido',
        'sent' => 'Enviado (sin confirmar)',
        _ => san.roundComplete(r) ? 'Reunido, sin enviar' : '—',
      };

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    footer: (ctx) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
      pw.Text('Hecho con KLK messenger · ${fecha.format(now)}', style: pw.TextStyle(fontSize: 8, color: gris)),
      pw.Text('Página ${ctx.pageNumber} de ${ctx.pagesCount}', style: pw.TextStyle(fontSize: 8, color: gris)),
    ]),
    build: (ctx) => [
      pw.Container(
        padding: const pw.EdgeInsets.all(16),
        decoration: pw.BoxDecoration(color: verde, borderRadius: pw.BorderRadius.circular(10)),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('San «${san.name}»',
              style: pw.TextStyle(color: PdfColors.white, fontSize: 22, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          pw.Text(
            '$chatTitle · ${san.money(san.amount)} ${san.periodLabel} · se lleva ${san.money(san.pot)}',
            style: const pw.TextStyle(color: PdfColors.white, fontSize: 11),
          ),
          pw.Text(
            'Del ${fecha.format(san.dateOf(0))} al ${fecha.format(san.endDate)} · ${san.rounds} turnos'
            '${san.ended ? ' · terminado' : ''}',
            style: const pw.TextStyle(color: PdfColors.white, fontSize: 11),
          ),
        ]),
      ),
      pw.SizedBox(height: 14),
      pw.Text('Resumen de turnos', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 6),
      pw.TableHelper.fromTextArray(
        headers: ['#', 'Le toca a', 'Fecha', 'Pagaron', 'Entrega'],
        data: [
          for (var r = 0; r < san.rounds; r++)
            ['${r + 1}', san.slots[r].name, fecha.format(san.dateOf(r)), '${san.paidCount(r)}/${san.slots.length}', out(r)],
        ],
        headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 10),
        headerDecoration: pw.BoxDecoration(color: verde),
        cellStyle: const pw.TextStyle(fontSize: 10),
        cellAlignments: {0: pw.Alignment.center, 3: pw.Alignment.center},
      ),
      for (var r = 0; r < san.rounds; r++) ...[
        pw.SizedBox(height: 12),
        pw.Text('Turno ${r + 1} · ${san.slots[r].name} · ${fecha.format(san.dateOf(r))}',
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.TableHelper.fromTextArray(
          headers: ['Número', 'Persona', 'Pago'],
          data: [
            for (var s = 0; s < san.slots.length; s++) ['#${s + 1}', san.slots[s].name, pay(san.payOf(r, s))],
          ],
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
          cellStyle: const pw.TextStyle(fontSize: 9),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
        ),
      ],
      pw.SizedBox(height: 16),
      pw.Text(
        'KLK solo lleva la cuenta del san: el dinero se mueve entre los participantes. '
        'Este historial refleja lo que se marcó en la app.',
        style: pw.TextStyle(fontSize: 8.5, color: gris),
      ),
    ],
  ));
  return doc.save();
}
