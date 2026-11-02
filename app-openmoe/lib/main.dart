import 'dart:async';

import 'package:flutter/material.dart';

import 'crash_log.dart';
import 'setup_page.dart';

void _reportFlutterError(FlutterErrorDetails details) {
  appendCrashLog(
    'flutter-error: ${details.exceptionAsString()}\n'
    '${details.stack}',
  );
}

void main() {
  runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = _reportFlutterError;
      final crash = readCrashLogTail();
      if (crash != null) {
        await appendCrashLog('--- previous session ended above ---');
      }
      runApp(OpenMoeApp(lastSessionCrash: crash));
    },
    (error, stack) {
      appendCrashLog('uncaught: $error\n$stack');
    },
  );
}

class OpenMoeApp extends StatelessWidget {
  final String? lastSessionCrash;

  const OpenMoeApp({super.key, this.lastSessionCrash});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenMoe',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7C4DFF)),
      ),
      home: SetupPage(lastSessionCrash: lastSessionCrash),
    );
  }
}
