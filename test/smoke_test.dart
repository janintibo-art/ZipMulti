import 'package:flutter_test/flutter_test.dart';
import 'package:zip_multi/main.dart';

void main() {
  testWidgets('ZipMulti v0.3 démarre', (tester) async {
    await tester.pumpWidget(const ZipMultiApp());
    expect(find.text('ZipMulti'), findsOneWidget);
    expect(find.text('Créer un lot'), findsOneWidget);
    expect(find.text('Reconstruire'), findsOneWidget);
    expect(find.text('Créer le lot ZIP'), findsOneWidget);
  });
}
