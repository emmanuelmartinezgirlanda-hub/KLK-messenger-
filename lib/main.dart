import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'features/home/home_screen.dart';
import 'features/messaging/app_controller.dart';
import 'features/onboarding/welcome_screen.dart';
import 'features/theming/presentation/theme_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('es');
  runApp(const ProviderScope(child: KlkApp()));
}

class KlkApp extends ConsumerStatefulWidget {
  const KlkApp({super.key});

  @override
  ConsumerState<KlkApp> createState() => _KlkAppState();
}

class _KlkAppState extends ConsumerState<KlkApp> with WidgetsBindingObserver {
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
    if (state == AppLifecycleState.resumed) ref.read(appProvider).onResume();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(themeProvider);
    final phase = ref.watch(appProvider.select((a) => a.phase));

    return MaterialApp(
      title: 'KLK',
      debugShowCheckedModeBanner: false,
      theme: theme.toThemeData(),
      locale: const Locale('es'),
      supportedLocales: const [Locale('es'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: switch (phase) {
        AppPhase.loading => const _Splash(),
        AppPhase.onboarding => const WelcomeScreen(),
        AppPhase.ready => const HomeScreen(),
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Text('KLK',
              style: TextStyle(
                  fontSize: 56, fontWeight: FontWeight.w900, color: Theme.of(context).colorScheme.primary)),
        ),
      );
}
