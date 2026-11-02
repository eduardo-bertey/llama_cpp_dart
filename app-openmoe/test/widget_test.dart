import 'package:flutter_test/flutter_test.dart';

import 'package:app_openmoe/main.dart';

void main() {
  testWidgets('shows the launcher screen chips', (WidgetTester tester) async {
    await tester.pumpWidget(const OpenMoeApp());

    // Home: menu + launcher chips.
    expect(find.text('OpenMoe'), findsOneWidget);
    expect(find.text('Recuperar chat'), findsOneWidget);
    expect(find.text('Descargar modelo'), findsOneWidget);
    expect(find.text('Cargar desde carpeta'), findsOneWidget);
  });
}
