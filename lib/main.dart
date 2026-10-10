import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/brand/klk_brand.dart';
import 'core/brand/klk_logo.dart';
import 'core/media/media_store.dart';
import 'features/calls/call_controller.dart';
import 'features/home/home_screen.dart';
import 'features/messaging/app_controller.dart';
import 'features/lock/app_lock.dart';
import 'features/onboarding/welcome_screen.dart';
import 'features/privacy/presentation/privacy_provider.dart';
import 'features/theming/domain/klk_theme.dart';
import 'features/theming/presentation/theme_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('es');
  await MediaStore.init();
  runApp(const ProviderScope(child: KlkApp()));
}

class KlkApp extends ConsumerStatefulWidget {
  const KlkApp({super.key});

  @override
  ConsumerState<KlkApp> createState() => _KlkAppState();
}

class _KlkAppState extends ConsumerState<KlkApp> with WidgetsBindingObserver {
  /// Bloqueo con Face ID: hasta saber si está activado, no se enseña nada.
  bool _lockChecked = false;
  bool _locked = false;
  DateTime? _backgroundSince;
  static const _relockAfter = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Crea el controlador de llamadas desde el arranque para recibir llamadas entrantes.
    ref.read(callProvider);
    ref.read(privacyProvider.notifier).loaded.then((_) {
      if (!mounted) return;
      setState(() {
        _locked = ref.read(privacyProvider).appLock;
        _lockChecked = true;
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _backgroundSince ??= DateTime.now();
    if (state == AppLifecycleState.resumed) {
      ref.read(appProvider).onResume();
      final since = _backgroundSince;
      _backgroundSince = null;
      // Si estuvo en segundo plano un rato, vuelve a pedir Face ID.
      if (since != null && ref.read(privacyProvider).appLock && DateTime.now().difference(since) >= _relockAfter) {
        setState(() => _locked = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final phase = ref.watch(appProvider.select((a) => a.phase));

    return MaterialApp(
      navigatorKey: ref.watch(navigatorKeyProvider),
      title: KlkBrand.fullName,
      debugShowCheckedModeBanner: false,
      theme: theme.isAuto ? KlkTheme.klkClaro.toThemeData() : theme.toThemeData(),
      darkTheme: theme.isAuto ? KlkTheme.klkOscuro.toThemeData() : null,
      themeMode: theme.isAuto ? ThemeMode.system : ThemeMode.light,
      locale: const Locale('es'),
      supportedLocales: const [Locale('es'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => Stack(children: [
        if (child != null) child,
        if (_locked && phase == AppPhase.ready) LockScreen(onUnlocked: () => setState(() => _locked = false)),
      ]),
      home: switch (phase) {
        AppPhase.loading => const _Splash(),
        AppPhase.ready when !_lockChecked => const _Splash(),
        AppPhase.onboarding => const WelcomeScreen(),
        AppPhase.ready => const HomeScreen(),
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(child: KlkEmblem(size: 120)),
      );
}
