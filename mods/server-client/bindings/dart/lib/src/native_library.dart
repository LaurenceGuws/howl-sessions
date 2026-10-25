import 'dart:ffi';
import 'dart:io';

/// Locates the module-owned C ABI, independent of the host's UI runtime.
DynamicLibrary openServerClientLibrary() {
  if (Platform.isIOS) return DynamicLibrary.process();
  final configured = Platform.environment['HOWL_SERVER_CLIENT_LIBRARY'];
  if (configured != null && configured.isNotEmpty) {
    return DynamicLibrary.open(configured);
  }
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libhowl_server_client.so');
  }
  final bundle = File(Platform.resolvedExecutable).parent.path;
  return DynamicLibrary.open('$bundle/lib/libhowl_server_client.so');
}
