import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'catalog.dart';
import 'launch.dart';

const _abiVersion = 1;
const _ok = 0;
final _maximumIdentity = BigInt.parse('18446744073709551615');

// Dart VM ints are signed 64-bit; C identities are unsigned u64.
// Keep identities lossless and round-trip raw low bits only at the FFI boundary.
BigInt _identity(int raw) => BigInt.from(raw).toUnsigned(64);

int _rawIdentity(BigInt identity) {
  if (identity <= BigInt.zero || identity > _maximumIdentity) {
    throw ArgumentError.value(identity, 'identity', 'must fit nonzero u64');
  }
  return identity.toInt();
}

void _validateGeometry(InstanceLaunch launch) {
  for (final cells in [launch.rows, launch.columns, launch.historyRows]) {
    if (cells < 1 || cells > 65535) {
      throw ArgumentError.value(cells, 'geometry', 'must fit nonzero u16');
    }
  }
}

final class _Status extends Struct {
  @Uint64()
  external int serverId;
  @Uint64()
  external int revision;
  @Uint16()
  external int sessionCount;
  @Uint16()
  external int instanceCount;
  @Uint16()
  external int sessionCapacity;
  @Uint16()
  external int instancesPerSession;
}

final class _Session extends Struct {
  @Uint64()
  external int id;
  external Pointer<Uint8> name;
  @IntPtr()
  external int nameLength;
  @IntPtr()
  external int instanceCount;
}

final class _Instance extends Struct {
  @Uint64()
  external int id;
  @Uint32()
  external int state;
}

final class _Launch extends Struct {
  @Uint64()
  external int sessionId;
  @Uint16()
  external int rows;
  @Uint16()
  external int columns;
  @Uint16()
  external int historyRows;
  @Uint16()
  external int reserved;
  external Pointer<Uint8> shell;
  @IntPtr()
  external int shellLength;
  external Pointer<Uint8> command;
  @IntPtr()
  external int commandLength;
  external Pointer<Uint8> cwd;
  @IntPtr()
  external int cwdLength;
}

final class _Identity extends Struct {
  @Uint64()
  external int sessionId;
  @Uint64()
  external int instanceId;
}

typedef _OpenNative = Uint32 Function(
  Uint32,
  Pointer<Uint8>,
  IntPtr,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _OpenDart = int Function(
  int,
  Pointer<Uint8>,
  int,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _ReleaseNative = Void Function(Pointer<Pointer<Void>>);
typedef _ReleaseDart = void Function(Pointer<Pointer<Void>>);
typedef _TreeNative = Uint32 Function(
  Pointer<Void>,
  Uint64,
  Pointer<Pointer<Void>>,
);
typedef _TreeDart = int Function(Pointer<Void>, int, Pointer<Pointer<Void>>);
typedef _StatusNative = Uint32 Function(Pointer<Void>, Pointer<_Status>);
typedef _StatusDart = int Function(Pointer<Void>, Pointer<_Status>);
typedef _SessionNative = Uint32 Function(
  Pointer<Void>,
  IntPtr,
  Pointer<_Session>,
);
typedef _SessionDart = int Function(Pointer<Void>, int, Pointer<_Session>);
typedef _InstanceNative = Uint32 Function(
  Pointer<Void>,
  IntPtr,
  IntPtr,
  Pointer<_Instance>,
);
typedef _InstanceDart = int Function(
  Pointer<Void>,
  int,
  int,
  Pointer<_Instance>,
);
typedef _CreateNative = Uint32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  IntPtr,
  Pointer<Uint64>,
);
typedef _CreateDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint64>,
);
typedef _CloseNative = Uint32 Function(Pointer<Void>, Uint64);
typedef _CloseDart = int Function(Pointer<Void>, int);
typedef _LaunchNative = Uint32 Function(
  Pointer<Void>,
  Pointer<_Launch>,
  Pointer<_Identity>,
);
typedef _LaunchDart = int Function(
  Pointer<Void>,
  Pointer<_Launch>,
  Pointer<_Identity>,
);
typedef _CloseInstanceNative = Uint32 Function(Pointer<Void>, _Identity);
typedef _CloseInstanceDart = int Function(Pointer<Void>, _Identity);

/// Native struct layouts and signatures follow howl_server_client.h v1.
/// This package owns the mapping; hosts never recreate it.
final class _Abi {
  _Abi(DynamicLibrary library)
    : open = library.lookupFunction<_OpenNative, _OpenDart>('hsc_control_open'),
      close = library.lookupFunction<_ReleaseNative, _ReleaseDart>(
        'hsc_control_release',
      ),
      tree = library.lookupFunction<_TreeNative, _TreeDart>('hsc_control_tree'),
      releaseTree = library.lookupFunction<_ReleaseNative, _ReleaseDart>(
        'hsc_tree_release',
      ),
      treeStatus = library.lookupFunction<_StatusNative, _StatusDart>(
        'hsc_tree_status',
      ),
      session = library.lookupFunction<_SessionNative, _SessionDart>(
        'hsc_tree_session',
      ),
      instance = library.lookupFunction<_InstanceNative, _InstanceDart>(
        'hsc_tree_instance',
      ),
      create = library.lookupFunction<_CreateNative, _CreateDart>(
        'hsc_session_create',
      ),
      closeSession = library.lookupFunction<_CloseNative, _CloseDart>(
        'hsc_session_close',
      ),
      createInstance = library.lookupFunction<_LaunchNative, _LaunchDart>(
        'hsc_instance_create',
      ),
      closeInstance = library
          .lookupFunction<_CloseInstanceNative, _CloseInstanceDart>(
            'hsc_instance_close',
          );

  final _OpenDart open;
  final _ReleaseDart close;
  final _TreeDart tree;
  final _ReleaseDart releaseTree;
  final _StatusDart treeStatus;
  final _SessionDart session;
  final _InstanceDart instance;
  final _CreateDart create;
  final _CloseDart closeSession;
  final _LaunchDart createInstance;
  final _CloseInstanceDart closeInstance;

  static _Abi load() {
    if (Platform.isIOS) return _Abi(DynamicLibrary.process());
    final configured = Platform.environment['HOWL_SERVER_CLIENT_LIBRARY'];
    if (configured != null && configured.isNotEmpty) {
      return _Abi(DynamicLibrary.open(configured));
    }
    if (Platform.isAndroid) {
      return _Abi(DynamicLibrary.open('libhowl_server_client.so'));
    }
    // Flutter's Linux bundle puts host-owned native assets beside the runner.
    final bundle = File(Platform.resolvedExecutable).parent.path;
    return _Abi(DynamicLibrary.open('$bundle/lib/libhowl_server_client.so'));
  }
}

/// Executes one bounded catalog transaction in the caller's worker isolate.
/// Every native handle and borrowed view is released before returning.
final class NativeServerClient {
  late final _Abi _abi = _Abi.load();

  SessionTree readTree(String endpoint) => _withControl(endpoint, (control) {
    final snapshot = calloc<Pointer<Void>>();
    try {
      _check('tree', _abi.tree(control, 0, snapshot));
      final status = calloc<_Status>();
      final session = calloc<_Session>();
      final instance = calloc<_Instance>();
      try {
        _check('tree status', _abi.treeStatus(snapshot.value, status));
        final sessions = <SessionEntry>[];
        for (var s = 0; s < status.ref.sessionCount; s++) {
          _check('session', _abi.session(snapshot.value, s, session));
          final bytes = session.ref.name.asTypedList(session.ref.nameLength);
          final name = utf8.decode(bytes);
          final instances = <InstanceEntry>[];
          for (var i = 0; i < session.ref.instanceCount; i++) {
            _check('instance', _abi.instance(snapshot.value, s, i, instance));
            instances.add(
              InstanceEntry(
                id: _identity(instance.ref.id),
                running: instance.ref.state == 1,
              ),
            );
          }
          sessions.add(
            SessionEntry(
              id: _identity(session.ref.id),
              name: name,
              instances: List.unmodifiable(instances),
            ),
          );
        }
        return SessionTree(
          serverId: _identity(status.ref.serverId),
          revision: _identity(status.ref.revision),
          sessionCapacity: status.ref.sessionCapacity,
          instancesPerSession: status.ref.instancesPerSession,
          sessions: List.unmodifiable(sessions),
        );
      } finally {
        calloc.free(instance);
        calloc.free(session);
        calloc.free(status);
      }
    } finally {
      _abi.releaseTree(snapshot);
      calloc.free(snapshot);
    }
  });

  BigInt createSession(String endpoint, String name) =>
      _withControl(endpoint, (control) {
        final nameBytes = utf8.encode(name);
        final nameBuffer = calloc<Uint8>(nameBytes.length);
        final identity = calloc<Uint64>();
        try {
          nameBuffer.asTypedList(nameBytes.length).setAll(0, nameBytes);
          _check(
            'create session',
            _abi.create(control, nameBuffer, nameBytes.length, identity),
          );
          return _identity(identity.value);
        } finally {
          calloc.free(identity);
          calloc.free(nameBuffer);
        }
      });

  void closeSession(String endpoint, BigInt sessionId) => _withControl(
    endpoint,
    (control) => _check(
      'close session',
      _abi.closeSession(control, _rawIdentity(sessionId)),
    ),
  );

  BigInt createInstance(String endpoint, InstanceLaunch launch) =>
      _withControl(endpoint, (control) {
        _validateGeometry(launch);
        final shellBytes = utf8.encode(launch.shell);
        final commandBytes = launch.command == null
            ? null
            : utf8.encode(launch.command!);
        final cwdBytes = launch.cwd == null ? null : utf8.encode(launch.cwd!);
        final shell = calloc<Uint8>(shellBytes.length);
        final command = commandBytes == null
            ? Pointer<Uint8>.fromAddress(0)
            : calloc<Uint8>(commandBytes.length);
        final cwd = cwdBytes == null
            ? Pointer<Uint8>.fromAddress(0)
            : calloc<Uint8>(cwdBytes.length);
        final request = calloc<_Launch>();
        final identity = calloc<_Identity>();
        try {
          shell.asTypedList(shellBytes.length).setAll(0, shellBytes);
          if (commandBytes != null) {
            command.asTypedList(commandBytes.length).setAll(0, commandBytes);
          }
          if (cwdBytes != null) {
            cwd.asTypedList(cwdBytes.length).setAll(0, cwdBytes);
          }
          request.ref
            ..sessionId = _rawIdentity(launch.sessionId)
            ..rows = launch.rows
            ..columns = launch.columns
            ..historyRows = launch.historyRows
            ..reserved = 0
            ..shell = shell
            ..shellLength = shellBytes.length
            ..command = command
            ..commandLength = commandBytes?.length ?? 0
            ..cwd = cwd
            ..cwdLength = cwdBytes?.length ?? 0;
          _check(
            'create instance',
            _abi.createInstance(control, request, identity),
          );
          return _identity(identity.ref.instanceId);
        } finally {
          calloc.free(identity);
          calloc.free(request);
          calloc.free(cwd);
          calloc.free(command);
          calloc.free(shell);
        }
      });

  void closeInstance(String endpoint, BigInt sessionId, BigInt instanceId) =>
      _withControl(endpoint, (control) {
        final identity = calloc<_Identity>();
        try {
          identity.ref
            ..sessionId = _rawIdentity(sessionId)
            ..instanceId = _rawIdentity(instanceId);
          _check('close instance', _abi.closeInstance(control, identity.ref));
        } finally {
          calloc.free(identity);
        }
      });

  T _withControl<T>(String endpoint, T Function(Pointer<Void>) transaction) {
    final endpointBytes = utf8.encode(endpoint);
    final address = calloc<Uint8>(endpointBytes.length);
    final control = calloc<Pointer<Void>>();
    try {
      address.asTypedList(endpointBytes.length).setAll(0, endpointBytes);
      _check(
        'open',
        _abi.open(_abiVersion, address, endpointBytes.length, nullptr, control),
      );
      return transaction(control.value);
    } finally {
      _abi.close(control);
      calloc.free(control);
      calloc.free(address);
    }
  }

  void _check(String operation, int code) {
    if (code != _ok) throw ServerClientFailure(operation, code);
  }
}
