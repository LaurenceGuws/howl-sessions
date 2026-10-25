import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'catalog.dart';
import 'native_identity.dart';
import 'native_library.dart';
import 'terminal_text.dart';

const _abiVersion = 1;
const _ok = 0;

final class _Ready extends Struct {
  @Uint64()
  external int serverId;
  @Uint64()
  external int sessionId;
  @Uint64()
  external int instanceId;
  @Uint64()
  external int treeRevision;
  @Uint64()
  external int clientId;
}

final class _Metadata extends Struct {
  @Uint64()
  external int deliveryRevision;
  @Uint64()
  external int terminalRevision;
  @Uint32()
  external int historyOffset;
  @Uint32()
  external int historyCount;
  @Uint32()
  external int historyRowBase;
  @Uint32()
  external int rowCount;
  @Uint32()
  external int cellCount;
  @Uint32()
  external int scalarCount;
  @Uint32()
  external int hyperlinkCount;
  @Uint16()
  external int rows;
  @Uint16()
  external int columns;
  @Uint16()
  external int cursorRow;
  @Uint16()
  external int cursorColumn;
  @Uint32()
  external int cursorShape;
  @Uint32()
  external int flags;
}

final class _Row extends Struct {
  @Uint32()
  external int cellOffset;
  @Uint32()
  external int cellCount;
  @Uint32()
  external int wrapped;
  @Uint32()
  external int geometry;
}

final class _Color extends Struct {
  @Uint32()
  external int kind;
  @Uint32()
  external int value;
}

final class _Cell extends Struct {
  @Uint32()
  external int scalarOffset;
  @Uint32()
  external int scalarCount;
  @Uint32()
  external int linkId;
  @Uint32()
  external int style;
  external _Color foreground;
  external _Color background;
  external _Color underlineColor;
  @Uint8()
  external int width;
  @Uint8()
  external int height;
  @Uint8()
  external int x;
  @Uint8()
  external int y;
  @Uint8()
  external int subscaleN;
  @Uint8()
  external int subscaleD;
  @Uint8()
  external int verticalAlign;
  @Uint8()
  external int horizontalAlign;
  @Uint8()
  external int semanticWidth;
  @Uint8()
  external int font;
  @Uint8()
  external int baseline;
  @Uint8()
  external int underlineStyle;
  @Uint8()
  external int protection;
  @Array(3)
  external Array<Uint8> reserved;
}

typedef _OpenNative = Uint32 Function(
  Uint32,
  Pointer<Uint8>,
  IntPtr,
  Uint64,
  Uint64,
  Uint64,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _OpenDart = int Function(
  int,
  Pointer<Uint8>,
  int,
  int,
  int,
  int,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _ReleaseNative = Void Function(Pointer<Pointer<Void>>);
typedef _ReleaseDart = void Function(Pointer<Pointer<Void>>);
typedef _InterruptCreateNative = Uint32 Function(
  Uint32,
  Pointer<Pointer<Void>>,
);
typedef _InterruptCreateDart = int Function(int, Pointer<Pointer<Void>>);
typedef _InterruptCancelNative = Uint32 Function(Pointer<Void>);
typedef _InterruptCancelDart = int Function(Pointer<Void>);
typedef _IdentityNative = Uint32 Function(Pointer<Void>, Pointer<_Ready>);
typedef _IdentityDart = int Function(Pointer<Void>, Pointer<_Ready>);
typedef _ObserveNative = Uint32 Function(
  Pointer<Void>,
  Uint64,
  Uint32,
  Pointer<Pointer<Void>>,
);
typedef _ObserveDart = int Function(
  Pointer<Void>,
  int,
  int,
  Pointer<Pointer<Void>>,
);
typedef _CacheCreateNative = Uint32 Function(
  Uint32,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _CacheCreateDart = int Function(
  int,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _ObserveCachedNative = Uint32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Uint64,
  Uint32,
  Pointer<Pointer<Void>>,
);
typedef _ObserveCachedDart = int Function(
  Pointer<Void>,
  Pointer<Void>,
  int,
  int,
  Pointer<Pointer<Void>>,
);
typedef _MetadataNative = Uint32 Function(Pointer<Void>, Pointer<_Metadata>);
typedef _MetadataDart = int Function(Pointer<Void>, Pointer<_Metadata>);
typedef _RowNative = Uint32 Function(Pointer<Void>, IntPtr, Pointer<_Row>);
typedef _RowDart = int Function(Pointer<Void>, int, Pointer<_Row>);
typedef _CellsNative = Uint32 Function(
  Pointer<Void>,
  IntPtr,
  Pointer<_Cell>,
  IntPtr,
  Pointer<IntPtr>,
);
typedef _CellsDart = int Function(
  Pointer<Void>,
  int,
  Pointer<_Cell>,
  int,
  Pointer<IntPtr>,
);
typedef _ScalarsNative = Uint32 Function(
  Pointer<Void>,
  Pointer<Pointer<Uint32>>,
  Pointer<IntPtr>,
);
typedef _ScalarsDart = int Function(
  Pointer<Void>,
  Pointer<Pointer<Uint32>>,
  Pointer<IntPtr>,
);
typedef _TextNative = Uint32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  IntPtr,
  Uint32,
);
typedef _TextDart = int Function(Pointer<Void>, Pointer<Uint8>, int, int);
typedef _ResizeNative = Uint32 Function(Pointer<Void>, Uint16, Uint16, Uint32);
typedef _ResizeDart = int Function(Pointer<Void>, int, int, int);

/// Exact attachment ABI from howl_server_client.h v1, not a host-owned wire.
final class _AttachmentAbi {
  _AttachmentAbi({String? libraryPath})
    : this._(openServerClientLibrary(libraryPath));

  _AttachmentAbi._(DynamicLibrary library)
    : createInterrupt = library
          .lookupFunction<_InterruptCreateNative, _InterruptCreateDart>(
            'hsc_interrupt_create',
          ),
      cancelInterrupt = library
          .lookupFunction<_InterruptCancelNative, _InterruptCancelDart>(
            'hsc_interrupt_cancel',
          ),
      releaseInterrupt = library.lookupFunction<_ReleaseNative, _ReleaseDart>(
        'hsc_interrupt_release',
      ),
      open = library.lookupFunction<_OpenNative, _OpenDart>(
        'hsc_attachment_open',
      ),
      release = library.lookupFunction<_ReleaseNative, _ReleaseDart>(
        'hsc_attachment_release',
      ),
      identity = library.lookupFunction<_IdentityNative, _IdentityDart>(
        'hsc_attachment_identity',
      ),
      observe = library.lookupFunction<_ObserveNative, _ObserveDart>(
        'hsc_observe',
      ),
      createCache = library
          .lookupFunction<_CacheCreateNative, _CacheCreateDart>(
            'hsc_cache_create',
          ),
      releaseCache = library.lookupFunction<_ReleaseNative, _ReleaseDart>(
        'hsc_cache_release',
      ),
      observeCached = library
          .lookupFunction<_ObserveCachedNative, _ObserveCachedDart>(
            'hsc_observe_cached',
          ),
      releaseSnapshot = library.lookupFunction<_ReleaseNative, _ReleaseDart>(
        'hsc_snapshot_release',
      ),
      metadata = library.lookupFunction<_MetadataNative, _MetadataDart>(
        'hsc_snapshot_metadata',
      ),
      row = library.lookupFunction<_RowNative, _RowDart>('hsc_snapshot_row'),
      cells = library.lookupFunction<_CellsNative, _CellsDart>(
        'hsc_snapshot_cells',
      ),
      scalars = library.lookupFunction<_ScalarsNative, _ScalarsDart>(
        'hsc_snapshot_scalars',
      ),
      text = library.lookupFunction<_TextNative, _TextDart>('hsc_text'),
      resize = library.lookupFunction<_ResizeNative, _ResizeDart>(
        'hsc_resize',
      ) {
    // Guard native C record shapes before any foreign write into Dart memory.
    if (sizeOf<_Ready>() != 40 ||
        sizeOf<_Metadata>() != 64 ||
        sizeOf<_Row>() != 16 ||
        sizeOf<_Cell>() != 56) {
      throw StateError('Server client native ABI record layout mismatch');
    }
  }

  final _InterruptCreateDart createInterrupt;
  final _InterruptCancelDart cancelInterrupt;
  final _ReleaseDart releaseInterrupt;
  final _OpenDart open;
  final _ReleaseDart release;
  final _IdentityDart identity;
  final _ObserveDart observe;
  final _CacheCreateDart createCache;
  final _ReleaseDart releaseCache;
  final _ObserveCachedDart observeCached;
  final _ReleaseDart releaseSnapshot;
  final _MetadataDart metadata;
  final _RowDart row;
  final _CellsDart cells;
  final _ScalarsDart scalars;
  final _TextDart text;
  final _ResizeDart resize;
}

void _check(String operation, int code) {
  if (code != _ok) throw ServerClientFailure(operation, code);
}

/// The initiating isolate owns this token throughout the worker's lifetime.
/// Only cancel may run across isolates; release follows worker exit.
final class NativeTerminalInterrupt {
  NativeTerminalInterrupt._(this._abi, this._slot);

  final _AttachmentAbi _abi;
  final Pointer<Pointer<Void>> _slot;
  bool _released = false;

  static NativeTerminalInterrupt create({String? libraryPath}) {
    final abi = _AttachmentAbi(libraryPath: libraryPath);
    final slot = calloc<Pointer<Void>>();
    try {
      _check('interrupt create', abi.createInterrupt(_abiVersion, slot));
      return NativeTerminalInterrupt._(abi, slot);
    } catch (_) {
      abi.releaseInterrupt(slot);
      calloc.free(slot);
      rethrow;
    }
  }

  int get address {
    if (_released) throw StateError('Interrupt already released');
    return _slot.value.address;
  }

  void cancel() {
    if (_released) return;
    _check('interrupt cancel', _abi.cancelInterrupt(_slot.value));
  }

  void close() {
    if (_released) return;
    _released = true;
    _abi.releaseInterrupt(_slot);
    calloc.free(_slot);
  }
}

/// Synchronous owner of one dedicated Instance connection.
///
/// Call it on one worker isolate, and release after all native calls return.
/// A production observer will keep this handle open; a one-shot preview may
/// release it immediately after copying a complete immutable observation.
final class NativeTerminalAttachment {
  NativeTerminalAttachment._(this._abi, this._slot, this._ready);

  final _AttachmentAbi _abi;
  final Pointer<Pointer<Void>> _slot;
  final _ReadyIdentity _ready;
  bool _released = false;
  Pointer<Pointer<Void>>? _cache;

  static NativeTerminalAttachment connect(
    String endpoint,
    BigInt serverId,
    BigInt sessionId,
    BigInt instanceId, {
    int? interruptAddress,
    String? libraryPath,
  }) {
    final abi = _AttachmentAbi(libraryPath: libraryPath);
    final addressBytes = utf8.encode(endpoint);
    final address = calloc<Uint8>(addressBytes.length);
    final attachment = calloc<Pointer<Void>>();
    final ready = calloc<_Ready>();
    try {
      address.asTypedList(addressBytes.length).setAll(0, addressBytes);
      _check(
        'attach',
        abi.open(
          _abiVersion,
          address,
          addressBytes.length,
          toNativeIdentity(serverId),
          toNativeIdentity(sessionId),
          toNativeIdentity(instanceId),
          interruptAddress == null
              ? nullptr
              : Pointer<Void>.fromAddress(interruptAddress),
          attachment,
        ),
      );
      _check('attachment identity', abi.identity(attachment.value, ready));
      final identity = _ReadyIdentity(
        fromNativeIdentity(ready.ref.serverId),
        fromNativeIdentity(ready.ref.sessionId),
        fromNativeIdentity(ready.ref.instanceId),
        fromNativeIdentity(ready.ref.clientId),
      );
      return NativeTerminalAttachment._(abi, attachment, identity);
    } catch (_) {
      abi.release(attachment);
      calloc.free(attachment);
      rethrow;
    } finally {
      calloc.free(ready);
      calloc.free(address);
    }
  }

  /// Enables the native row-delta transport cache for this exact attachment.
  /// The first cut is complete; subsequent observations reuse its baseline.
  void enableIncrementalObservation() {
    if (_released) throw StateError('Attachment already released');
    if (_cache != null) return;
    final slot = calloc<Pointer<Void>>();
    try {
      _check('cache create', _abi.createCache(_abiVersion, _slot.value, slot));
      _cache = slot;
    } catch (_) {
      _abi.releaseCache(slot);
      calloc.free(slot);
      rethrow;
    }
  }

  /// Borrows one immutable native snapshot only for the synchronous callback.
  /// The callback must copy all retained records before returning. Both the
  /// attachment and any native consumer must use the SAME shared library.
  T observeWith<T>(
    T Function(Pointer<Void> snapshot, BigInt deliveryRevision) copy, {
    BigInt? afterRevision,
    int historyOffset = 0,
  }) {
    if (_released) throw StateError('Attachment already released');
    if (historyOffset < 0 || historyOffset > 0xffffffff) {
      throw RangeError.range(historyOffset, 0, 0xffffffff, 'historyOffset');
    }
    final slot = calloc<Pointer<Void>>();
    final metadata = calloc<_Metadata>();
    try {
      final after = afterRevision == null || afterRevision == BigInt.zero
          ? 0
          : toNativeIdentity(afterRevision);
      _check(
        'observe',
        _cache == null
            ? _abi.observe(_slot.value, after, historyOffset, slot)
            : _abi.observeCached(
                _slot.value,
                _cache!.value,
                after,
                historyOffset,
                slot,
              ),
      );
      _check('snapshot metadata', _abi.metadata(slot.value, metadata));
      return copy(
        slot.value,
        fromNativeIdentity(metadata.ref.deliveryRevision),
      );
    } finally {
      _abi.releaseSnapshot(slot);
      calloc.free(slot);
      calloc.free(metadata);
    }
  }

  TerminalTextSnapshot observe({BigInt? afterRevision, int historyOffset = 0}) {
    return observeWith(
      (snapshot, _) {
        final metadata = calloc<_Metadata>();
        final row = calloc<_Row>();
        final scalarPointer = calloc<Pointer<Uint32>>();
        final scalarCount = calloc<IntPtr>();
        final written = calloc<IntPtr>();
        Pointer<_Cell>? cells;
        try {
          _check('snapshot metadata', _abi.metadata(snapshot, metadata));
          _check(
            'snapshot scalars',
            _abi.scalars(snapshot, scalarPointer, scalarCount),
          );
          if (scalarCount.value != metadata.ref.scalarCount) {
            throw const FormatException(
              'Snapshot scalar count differs from metadata',
            );
          }
          final scalars = scalarCount.value == 0
              ? const <int>[]
              : scalarPointer.value.asTypedList(scalarCount.value);
          cells = calloc<_Cell>(metadata.ref.cellCount);
          _check(
            'snapshot cells',
            _abi.cells(snapshot, 0, cells, metadata.ref.cellCount, written),
          );
          if (written.value != metadata.ref.cellCount) {
            throw const FormatException('Incomplete snapshot cell copy');
          }
          final lines = <String>[];
          for (var index = 0; index < metadata.ref.rowCount; index++) {
            _check('snapshot row', _abi.row(snapshot, index, row));
            final start = row.ref.cellOffset;
            final end = start + row.ref.cellCount;
            if (end > metadata.ref.cellCount) {
              throw const FormatException('Snapshot row exceeds cells');
            }
            final text = StringBuffer();
            for (var cellIndex = start; cellIndex < end; cellIndex++) {
              final cell = (cells + cellIndex).ref;
              if (cell.scalarCount == 0) {
                if (cell.x == 0 && cell.y == 0) text.write(' ');
                continue;
              }
              final scalarEnd = cell.scalarOffset + cell.scalarCount;
              if (scalarEnd > scalars.length) {
                throw const FormatException('Snapshot cell exceeds scalars');
              }
              text.write(
                String.fromCharCodes(
                  scalars.sublist(cell.scalarOffset, scalarEnd),
                ),
              );
            }
            lines.add(text.toString());
          }
          return TerminalTextSnapshot(
            serverId: _ready.serverId,
            sessionId: _ready.sessionId,
            instanceId: _ready.instanceId,
            clientId: _ready.clientId,
            deliveryRevision: fromNativeIdentity(metadata.ref.deliveryRevision),
            terminalRevision: fromNativeIdentity(metadata.ref.terminalRevision),
            rows: metadata.ref.rows,
            columns: metadata.ref.columns,
            cursorRow: metadata.ref.cursorRow,
            cursorColumn: metadata.ref.cursorColumn,
            lines: List.unmodifiable(lines),
          );
        } finally {
          if (cells != null) calloc.free(cells);
          calloc.free(written);
          calloc.free(scalarCount);
          calloc.free(scalarPointer);
          calloc.free(row);
          calloc.free(metadata);
        }
      },
      afterRevision: afterRevision,
      historyOffset: historyOffset,
    );
  }

  void sendText(String input) {
    if (_released) throw StateError('Attachment already released');
    final bytes = utf8.encode(input);
    final buffer = calloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      _check('text', _abi.text(_slot.value, buffer, bytes.length, 0));
    } finally {
      calloc.free(buffer);
    }
  }

  void resize(int rows, int columns) {
    if (_released) throw StateError('Attachment already released');
    if (rows < 1 || rows > 65535 || columns < 1 || columns > 65535) {
      throw RangeError('Terminal geometry must fit nonzero u16');
    }
    _check('resize', _abi.resize(_slot.value, rows, columns, 1));
  }

  void close() {
    if (_released) return;
    _released = true;
    final cache = _cache;
    if (cache != null) {
      _abi.releaseCache(cache);
      calloc.free(cache);
      _cache = null;
    }
    _abi.release(_slot);
    calloc.free(_slot);
  }
}

final class _ReadyIdentity {
  const _ReadyIdentity(
    this.serverId,
    this.sessionId,
    this.instanceId,
    this.clientId,
  );
  final BigInt serverId;
  final BigInt sessionId;
  final BigInt instanceId;
  final BigInt clientId;
}
