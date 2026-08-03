import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:moto_taxi_douka/main.dart';

void main() {
  testWidgets('App demarre sans erreur', (WidgetTester tester) async {
    await tester.pumpWidget(const MotoTaxiApp());
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
