import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:howl_server_client/src/native_identity.dart';
import 'package:howl_server_client/src/native_library.dart';

import 'frame.dart';

const _version = 1;
const _commandBytes = 64;
const _maximumCommands = 114689;
const _maximumPixels = 80 * 1024 * 1024;
const _maximumResources = 9;

final class _Bytes extends Struct {
  external Pointer<Uint8> data;
  @IntPtr()
  external int len;
}

final class _Config extends Struct {
  external _Bytes primary;
  external Pointer<_Bytes> fallbacks;
  @IntPtr()
  external int fallbackCount;
  @Uint16()
  external int pixelSize;
  @Uint16()
  external int reserved;
}

final class _CellSize extends Struct {
  @Uint16()
  external int width;
  @Uint16()
  external int height;
  @Uint32()
  external int reserved;
}

final class _Residency extends Struct {
  @Uint64()
  external int resource;
  @Uint64()
  external int generation;
  @Uint16()
  external int width;
  @Uint16()
  external int height;
  @Uint8()
  external int format;
  @Array(3)
  external Array<Uint8> reserved;
}

final class _Resource extends Struct {
  @Uint64()
  external int resource;
  @Uint64()
  external int generation;
  @Uint64()
  external int pixelCount;
  @Uint64()
  external int stride;
  @Uint16()
  external int width;
  @Uint16()
  external int height;
  @Uint8()
  external int format;
  @Array(3)
  external Array<Uint8> reserved;
}

final class _Upload extends Struct {
  external _Resource info;
  external Pointer<Uint8> pixels;
  @IntPtr()
  external int pixelLen;
}

final class _Removal extends Struct {
  @Uint64()
  external int resource;
  @Uint64()
  external int generation;
}

final class _FrameInfo extends Struct {
  @Uint64()
  external int revision;
  @Uint64()
  external int contentRevision;
  @Uint64()
  external int terminalRevision;
  @Uint32()
  external int commandCount;
  @Uint32()
  external int contentCommandCount;
  @Uint32()
  external int uploadCount;
  @Uint32()
  external int removalCount;
  @Uint32()
  external int historyOffset;
  @Uint32()
  external int historyCount;
  @Uint32()
  external int historyRowBase;
  @Uint32()
  external int backgroundRgba;
  @Uint16()
  external int surfaceWidth;
  @Uint16()
  external int surfaceHeight;
  @Uint16()
  external int cellWidth;
  @Uint16()
  external int cellHeight;
  @Uint8()
  external int alternateScreen;
  @Array(7)
  external Array<Uint8> reserved;
}

final class _FrameView extends Struct {
  external _FrameInfo info;
  external Pointer<Uint8> commands;
  external Pointer<_Upload> uploads;
  external Pointer<_Removal> removals;
}

typedef _VersionNative = Uint32 Function();
typedef _VersionDart = int Function();
typedef _CreateNative = Uint32 Function(
  Uint32,
  Pointer<_Config>,
  Pointer<Pointer<Void>>,
);
typedef _CreateDart = int Function(
  int,
  Pointer<_Config>,
  Pointer<Pointer<Void>>,
);
typedef _DestroyNative = Uint32 Function(Pointer<Pointer<Void>>);
typedef _DestroyDart = int Function(Pointer<Pointer<Void>>);
typedef _CellSizeNative = Uint32 Function(Pointer<Void>, Pointer<_CellSize>);
typedef _CellSizeDart = int Function(Pointer<Void>, Pointer<_CellSize>);
typedef _CaptureNative = Uint32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<_Residency>,
  IntPtr,
  Pointer<Pointer<Void>>,
);
typedef _CaptureDart = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<_Residency>,
  int,
  Pointer<Pointer<Void>>,
);
typedef _ReadNative = Uint32 Function(Pointer<Void>, Pointer<_FrameView>);
typedef _ReadDart = int Function(Pointer<Void>, Pointer<_FrameView>);
typedef _ReleaseNative = Void Function(Pointer<Pointer<Void>>);
typedef _ReleaseDart = void Function(Pointer<Pointer<Void>>);

final class _Abi {
  _Abi(String? libraryPath) : this._(openServerClientLibrary(libraryPath));

  _Abi._(DynamicLibrary library)
    : version = library.lookupFunction<_VersionNative, _VersionDart>(
        'hsr_abi_version',
      ),
      create = library.lookupFunction<_CreateNative, _CreateDart>('hsr_create'),
      destroy = library.lookupFunction<_DestroyNative, _DestroyDart>(
        'hsr_try_destroy',
      ),
      cellSize = library.lookupFunction<_CellSizeNative, _CellSizeDart>(
        'hsr_cell_size',
      ),
      capture = library.lookupFunction<_CaptureNative, _CaptureDart>(
        'hsr_capture',
      ),
      read = library.lookupFunction<_ReadNative, _ReadDart>('hsr_frame_read'),
      release = library.lookupFunction<_ReleaseNative, _ReleaseDart>(
        'hsr_frame_release',
      ) {
    if (sizeOf<_Bytes>() != 16 ||
        sizeOf<_Config>() != 40 ||
        sizeOf<_CellSize>() != 8 ||
        sizeOf<_Residency>() != 24 ||
        sizeOf<_Resource>() != 40 ||
        sizeOf<_Upload>() != 56 ||
        sizeOf<_Removal>() != 16 ||
        sizeOf<_FrameInfo>() != 72 ||
        sizeOf<_FrameView>() != 96 ||
        version() != _version) {
      throw StateError('Howl Render native ABI identity/layout mismatch');
    }
  }

  final _VersionDart version;
  final _CreateDart create;
  final _DestroyDart destroy;
  final _CellSizeDart cellSize;
  final _CaptureDart capture;
  final _ReadDart read;
  final _ReleaseDart release;
}

final class RenderFailure implements Exception {
  const RenderFailure(this.operation, this.status);
  final String operation;
  final int status;

  @override
  String toString() => 'Howl Render $operation failed (status $status)';
}

void _check(String operation, int status) {
  if (status != 0) throw RenderFailure(operation, status);
}

Pointer<Uint8> _path(String text) {
  final bytes = utf8.encode(text);
  if (bytes.isEmpty || bytes.length > 4096 || bytes.contains(0)) {
    throw ArgumentError.value(text, 'font path', 'invalid path');
  }
  final result = calloc<Uint8>(bytes.length);
  result.asTypedList(bytes.length).setAll(0, bytes);
  return result;
}

/// Worker-isolate owner of canonical Render, using the EXACT shared library
/// as its Server Client snapshot producer. Never pass native pointers through
/// isolate messages or retain frame/snapshot borrows.
final class NativeRenderer {
  NativeRenderer._(this._abi, this._slot, this.cellWidth, this.cellHeight);

  final _Abi _abi;
  final Pointer<Pointer<Void>> _slot;
  final int cellWidth, cellHeight;
  bool _closed = false;

  static NativeRenderer create(
    String primaryFont, {
    List<String> fallbacks = const [],
    int pixelSize = 16,
    String? libraryPath,
  }) {
    if (fallbacks.length > 24 || pixelSize < 1 || pixelSize > 65535) {
      throw RangeError('Invalid native font settings');
    }
    final abi = _Abi(libraryPath);
    final slot = calloc<Pointer<Void>>();
    final config = calloc<_Config>();
    final paths = <Pointer<Uint8>>[];
    final fallbackValues = calloc<_Bytes>(fallbacks.length);
    try {
      final primary = _path(primaryFont);
      paths.add(primary);
      config.ref.primary.data = primary;
      config.ref.primary.len = utf8.encode(primaryFont).length;
      for (var i = 0; i < fallbacks.length; i++) {
        final pointer = _path(fallbacks[i]);
        paths.add(pointer);
        fallbackValues[i].data = pointer;
        fallbackValues[i].len = utf8.encode(fallbacks[i]).length;
      }
      config.ref.fallbacks = fallbacks.isEmpty ? nullptr : fallbackValues;
      config.ref.fallbackCount = fallbacks.length;
      config.ref.pixelSize = pixelSize;
      config.ref.reserved = 0;
      _check('create', abi.create(_version, config, slot));
      final cell = calloc<_CellSize>();
      try {
        _check('cell size', abi.cellSize(slot.value, cell));
        return NativeRenderer._(abi, slot, cell.ref.width, cell.ref.height);
      } finally {
        calloc.free(cell);
      }
    } catch (_) {
      _check('destroy after failed create', abi.destroy(slot));
      calloc.free(slot);
      rethrow;
    } finally {
      for (final path in paths) {
        calloc.free(path);
      }
      calloc.free(fallbackValues);
      calloc.free(config);
    }
  }

  RenderFrame capture(
    Pointer<Void> borrowedSnapshot, {
    List<RenderResidency> resident = const [],
  }) {
    if (_closed) throw StateError('Renderer already closed');
    if (resident.length > _maximumResources) {
      throw RangeError('Too many resident resources');
    }
    final current = calloc<_Residency>(resident.length);
    final frame = calloc<Pointer<Void>>();
    final view = calloc<_FrameView>();
    try {
      for (var i = 0; i < resident.length; i++) {
        final entry = resident[i];
        current[i].resource = toNativeIdentity(entry.key.resource);
        current[i].generation = toNativeIdentity(entry.key.generation);
        current[i].width = entry.width;
        current[i].height = entry.height;
        current[i].format = entry.format;
      }
      _check(
        'capture',
        _abi.capture(
          _slot.value,
          borrowedSnapshot,
          resident.isEmpty ? nullptr : current,
          resident.length,
          frame,
        ),
      );
      _check('read', _abi.read(frame.value, view));
      return _copy(view.ref);
    } finally {
      _abi.release(frame);
      calloc.free(view);
      calloc.free(frame);
      calloc.free(current);
    }
  }

  RenderFrame _copy(_FrameView value) {
    final info = value.info;
    if (info.commandCount > _maximumCommands ||
        info.uploadCount > _maximumResources ||
        info.removalCount > _maximumResources ||
        (info.commandCount != 0 && value.commands == nullptr) ||
        (info.uploadCount != 0 && value.uploads == nullptr) ||
        (info.removalCount != 0 && value.removals == nullptr)) {
      throw const FormatException('Howl Render frame ABI bounds');
    }
    final bytes = info.commandCount == 0
        ? Uint8List(0)
        : Uint8List.fromList(
            value.commands.asTypedList(info.commandCount * _commandBytes),
          );
    final uploads = <RenderUpload>[];
    var totalPixels = 0;
    for (var i = 0; i < info.uploadCount; i++) {
      final upload = value.uploads[i];
      totalPixels += upload.pixelLen;
      if (upload.pixelLen < 0 ||
          totalPixels > _maximumPixels ||
          (upload.pixelLen != 0 && upload.pixels == nullptr)) {
        throw const FormatException('Howl Render upload ABI bounds');
      }
      final resource = upload.info;
      uploads.add(
        RenderUpload(
          RenderResidency(
            RenderKey(
              fromNativeIdentity(resource.resource),
              fromNativeIdentity(resource.generation),
            ),
            resource.width,
            resource.height,
            resource.format,
          ),
          resource.stride,
          upload.pixelLen == 0
              ? Uint8List(0)
              : Uint8List.fromList(upload.pixels.asTypedList(upload.pixelLen)),
        ),
      );
    }
    final removals = <RenderKey>[];
    for (var i = 0; i < info.removalCount; i++) {
      final removal = value.removals[i];
      removals.add(
        RenderKey(
          fromNativeIdentity(removal.resource),
          fromNativeIdentity(removal.generation),
        ),
      );
    }
    return RenderFrame(
      revision: info.revision,
      contentRevision: info.contentRevision,
      terminalRevision: info.terminalRevision,
      width: info.surfaceWidth,
      height: info.surfaceHeight,
      cellWidth: info.cellWidth,
      cellHeight: info.cellHeight,
      backgroundRgba: info.backgroundRgba,
      alternateScreen: info.alternateScreen != 0,
      commands: bytes,
      uploads: List.unmodifiable(uploads),
      removals: List.unmodifiable(removals),
    );
  }

  void close() {
    if (_closed) return;
    _check('destroy', _abi.destroy(_slot));
    _closed = true;
    calloc.free(_slot);
  }
}
