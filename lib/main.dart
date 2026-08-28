import 'package:flutter/material.dart';

import 'src/screens/home_screen.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  final initialZipPaths = args
      .where((arg) => arg.toLowerCase().endsWith('.zip'))
      .toList(growable: false);
  runApp(ZipMultiApp(initialZipPaths: initialZipPaths));
}

class ZipMultiApp extends StatelessWidget {
  const ZipMultiApp({super.key, this.initialZipPaths = const []});

  final List<String> initialZipPaths;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF8B5CF6),
      brightness: Brightness.dark,
      surface: const Color(0xFF121521),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ZipMulti',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF080A10),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withValues(alpha: .035),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: .08)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: .08)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF8B5CF6), width: 1.4),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
          ),
        ),
      ),
      home: HomeScreen(initialZipPaths: initialZipPaths),
    );
  }
}
