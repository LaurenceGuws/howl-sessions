import 'dart:ffi';
import 'dart:io';

/// Locates the exact composed native library. Legacy standalone callers may
/// opt into their earlier client-only artifact with an explicit environment
/// path; a Render snapshot must never cross between the two artifacts.
DynamicLibrary openServerClientLibrary([String? libraryPath]) {
  if (libraryPath != null && libraryPath.isNotEmpty) {
    return DynamicLibrary.open(libraryPath);
  }
  if (Platform.isIOS) return DynamicLibrary.process();
  final configured = Platform.environment['HOWL_SERVER_CLIENT_LIBRARY'];
  if (configured != null && configured.isNotEmpty) {
    return DynamicLibrary.open(configured);
  }
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libhowl_sessions_native.so');
  }
  final bundle = File(Platform.resolvedExecutable).parent.path;
  return DynamicLibrary.open('$bundle/lib/libhowl_sessions_native.so');
}
