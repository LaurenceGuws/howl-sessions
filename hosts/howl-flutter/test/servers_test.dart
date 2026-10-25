import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:howl_sessions/servers/configured_server.dart';
import 'package:howl_sessions/servers/server_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('host endpoints persist without Server or Session identity', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final store = ServerStore();
    expect(await store.load(), isEmpty);
    await store.save(const [
      ConfiguredServer(name: 'Home', endpoint: 'tcp://127.0.0.1:43150'),
      ConfiguredServer(name: 'Portable', endpoint: 'tcp://127.0.0.1:43151'),
    ]);
    final saved = await ServerStore().load();
    expect(saved.map((server) => server.name), ['Home', 'Portable']);
    expect(saved[1].endpoint, 'tcp://127.0.0.1:43151');
  });

  test('invalid stored endpoints are rejected, not silently lost', () {
    expect(
      () => ConfiguredServer.fromJson({'name': 'Bad', 'endpoint': ''}),
      throwsFormatException,
    );
  });
}
