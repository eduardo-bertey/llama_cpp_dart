import 'package:flutter_test/flutter_test.dart';

import 'package:app_openmoe/main.dart';

void main() {
  testWidgets('shows the launcher screen chips', (WidgetTester tester) async {
    await tester.pumpWidget(const OpenMoeApp());
    expect(find.textContaining('Librería llama.cpp'), findsOneWidget);
    expect(find.textContaining('Modelos de HuggingFace'), findsOneWidget);
  });
}
