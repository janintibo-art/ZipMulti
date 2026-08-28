import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zip_multi/src/screens/tutorial_screen.dart';

void main() {
  testWidgets('le tutoriel présente les premiers pas', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: TutorialScreen(),
      ),
    );

    expect(find.text('Tutoriel et aide'), findsOneWidget);
    expect(find.text('Bienvenue dans ZipMulti'), findsOneWidget);
    expect(find.text('Suivant'), findsOneWidget);
  });
}
