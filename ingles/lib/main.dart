import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const InglesDiarioApp());
}

class InglesDiarioApp extends StatelessWidget {
  const InglesDiarioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Speakazo',
      debugShowCheckedModeBanner: false,
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..loadFlutterAsset('assets/index.html');
  }

  @override
  Widget build(BuildContext context) {
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final bg = dark ? const Color(0xFF0F1226) : const Color(0xFFF1F2F7);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: bg,
        body: SafeArea(bottom: false, child: WebViewWidget(controller: _controller)),
      ),
    );
  }
}
