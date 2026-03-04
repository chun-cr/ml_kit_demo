// Basic smoke test for ML Kit Demo app.
import 'package:flutter_test/flutter_test.dart';
import 'package:ml_kit_demo/main.dart';

void main() {
  testWidgets('App renders without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const MLKitApp());
    // The app should at least render the loading indicator
    // (camera init happens asynchronously).
    expect(find.byType(MLKitApp), findsOneWidget);
  });
}
