import 'package:flutter/material.dart';

import 'setup_page.dart';

void main() {
  runApp(const OpenMoeApp());
}

class OpenMoeApp extends StatelessWidget {
  const OpenMoeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenMoe',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7C4DFF)),
      ),
      home: const SetupPage(),
    );
  }
}
