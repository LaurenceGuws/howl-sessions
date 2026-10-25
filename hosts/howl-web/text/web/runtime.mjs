// Explicit browser host for the text target's four WASI imports. No files,
// sockets, font lookup, shaping or rasterization are implemented in JavaScript.
export const textImports = ['fd_close', 'fd_seek', 'fd_write', 'random_get'];

export function assertTextImports(module) {
  const imports = WebAssembly.Module.imports(module);
  if (imports.some(item => item.module !== 'wasi_snapshot_preview1' || item.kind !== 'function') ||
      imports.map(item => item.name).sort().join() !== textImports.join()) {
    throw new Error('Text runtime import contract changed');
  }
}

export function createTextRuntime({ entropy = globalThis.crypto, output = (fd, text) => (fd === 2 ? console.warn : console.log)(text) } = {}) {
  if (!entropy || typeof entropy.getRandomValues !== 'function') throw new Error('Secure entropy is required');
  const calls = Object.create(null);
  const stdio = new Set([1, 2]);
  let memory;
  let consoleBytes = 0;
  const count = name => { calls[name] = (calls[name] ?? 0) + 1; };
  function range(pointer, length) {
    pointer >>>= 0;
    length >>>= 0;
    if (!memory || pointer > memory.buffer.byteLength || length > memory.buffer.byteLength - pointer) {
      throw new RangeError('WASI memory range');
    }
    // Never retain a view across a Wasm call: libc may grow linear memory.
    return new Uint8Array(memory.buffer, pointer, length);
  }
  const wasi = {
    fd_close(fd) {
      count('fd_close');
      return stdio.delete(fd) ? 0 : 8; // BADF
    },
    fd_seek(fd) {
      count('fd_seek');
      return stdio.has(fd) ? 70 : 8; // SPIPE or BADF, never a filesystem.
    },
    fd_write(fd, vectors, length, written) {
      count('fd_write');
      if (!stdio.has(fd)) return 8;
      length >>>= 0;
      if (length > 128) return 28; // INVAL: bounded vector admission.
      let chunks;
      let total = 0;
      try {
        const packed = range(vectors, length * 8);
        const metadata = new DataView(packed.buffer, packed.byteOffset, packed.byteLength);
        chunks = [];
        for (let i = 0; i < length; i += 1) {
          const pointer = metadata.getUint32(i * 8, true);
          const size = metadata.getUint32(i * 8 + 4, true);
          total += size;
          if (total > 1048576 - consoleBytes) return 28;
          chunks.push(range(pointer, size));
        }
        range(written, 4);
      } catch { return 21; } // FAULT: no partial output on invalid memory.
      const decoder = new TextDecoder();
      const text = chunks.map(bytes => decoder.decode(bytes, { stream: true })).join('') + decoder.decode();
      output(fd, text);
      consoleBytes += total;
      new DataView(memory.buffer).setUint32(written >>> 0, total, true);
      return 0;
    },
    random_get(pointer, length) {
      count('random_get');
      length >>>= 0;
      if (length > 1048576) return 28;
      let bytes;
      try { bytes = range(pointer, length); } catch { return 21; }
      for (let offset = 0; offset < bytes.length; offset += 65536) {
        entropy.getRandomValues(bytes.subarray(offset, offset + 65536));
      }
      return 0;
    },
  };
  return {
    imports: { wasi_snapshot_preview1: wasi },
    calls,
    bind(value) {
      if (memory || !(value instanceof WebAssembly.Memory)) throw new Error('Bind one exported Wasm memory');
      memory = value;
    },
  };
}
