import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:trident_mail/data/providers/workspace_provider.dart';
import 'package:trident_mail/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => WorkspaceProvider(),
        child: const TridentMailApp(),
      ),
    );
    expect(find.byType(TridentMailApp), findsOneWidget);
  });
}
