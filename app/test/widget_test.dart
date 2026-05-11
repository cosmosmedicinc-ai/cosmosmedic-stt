import 'package:flutter_test/flutter_test.dart';

import 'package:medibridge_realtime/main.dart';

void main() {
  testWidgets('shows realtime MVP controls', (WidgetTester tester) async {
    await tester.pumpWidget(const MediBridgeApp());

    expect(find.text('MediBridge Realtime'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Status: disconnected'), findsOneWidget);
    expect(find.text('Recent original'), findsOneWidget);
    expect(find.text('Recent translation'), findsOneWidget);
  });
}
