export const FRAME_SCHEMA_V4 = 'howl.web-frame/v4';
export const BINARY_COMMAND_STRIDE = 64;
const U64_MAX = (1n << 64n) - 1n;

function exactU64(value) {
  let parsed;
  if (typeof value === 'bigint') parsed = value;
  else if (typeof value === 'string' && /^[1-9][0-9]*$/.test(value)) parsed = BigInt(value);
  else throw new Error('invalid Web frame v4 resource identity');
  if (parsed <= 0n || parsed > U64_MAX) throw new Error('invalid Web frame v4 resource identity');
  return parsed;
}

export function qualifiedKeyV4(value, generation) {
  if (generation === undefined) {
    if (!Array.isArray(value) || value.length !== 2)
      throw new Error('invalid Web frame v4 qualified resource');
    return `${exactU64(value[0])}:${exactU64(value[1])}`;
  }
  return `${exactU64(value)}:${exactU64(generation)}`;
}

export class BinaryCommands {
  constructor(memory, pointer, count, stride) {
    pointer = Number(pointer);
    count = Number(count);
    stride = Number(stride);
    if (!Number.isSafeInteger(pointer) || pointer < 0 ||
        !Number.isSafeInteger(count) || count < 0 ||
        stride !== BINARY_COMMAND_STRIDE)
      throw new Error('invalid Web frame v4 command lane');
    const bytes = count * stride;
    if (!Number.isSafeInteger(bytes) || pointer + bytes > memory.buffer.byteLength)
      throw new Error('Web frame v4 command lane outside renderer memory');
    this.count = count;
    this.stride = stride;
    this.view = new DataView(memory.buffer, pointer, bytes);
  }

  base(i) { return i * this.stride; }
  kind(i) { return this.view.getUint8(this.base(i)); }
  format(i) { return this.view.getUint8(this.base(i) + 1); }
  cursor(i) { return this.view.getUint8(this.base(i) + 2) !== 0; }
  x(i) { return this.view.getInt32(this.base(i) + 4, true); }
  y(i) { return this.view.getInt32(this.base(i) + 8, true); }
  width(i) { return this.view.getUint16(this.base(i) + 12, true); }
  height(i) { return this.view.getUint16(this.base(i) + 14, true); }
  clipX(i) { return this.view.getInt32(this.base(i) + 16, true); }
  clipY(i) { return this.view.getInt32(this.base(i) + 20, true); }
  clipWidth(i) { return this.view.getUint16(this.base(i) + 24, true); }
  clipHeight(i) { return this.view.getUint16(this.base(i) + 26, true); }
  resource(i) { return this.view.getBigUint64(this.base(i) + 32, true); }
  generation(i) { return this.view.getBigUint64(this.base(i) + 40, true); }
  resourceWidth(i) { return this.view.getUint16(this.base(i) + 48, true); }
  resourceHeight(i) { return this.view.getUint16(this.base(i) + 50, true); }
  sourceX(i) { return this.view.getUint16(this.base(i) + 52, true); }
  sourceY(i) { return this.view.getUint16(this.base(i) + 54, true); }
  sourceWidth(i) { return this.view.getUint16(this.base(i) + 56, true); }
  sourceHeight(i) { return this.view.getUint16(this.base(i) + 58, true); }
  red(i) { return this.view.getUint8(this.base(i) + 60); }
  green(i) { return this.view.getUint8(this.base(i) + 61); }
  blue(i) { return this.view.getUint8(this.base(i) + 62); }
  alpha(i) { return this.view.getUint8(this.base(i) + 63); }
  key(i) { return `${this.resource(i)}:${this.generation(i)}`; }
}

export function selectRendererFrameV4(exports) {
  if (typeof exports?.rv_frame_format !== 'function' || typeof exports?.rv_set_frame_format !== 'function')
    throw new Error('renderer does not support Web frame v4 negotiation');
  if (Number(exports.rv_frame_format()) !== 2)
    throw new Error('renderer did not boot in backward-compatible Web frame v2 mode');
  if (exports.rv_set_frame_format(4) !== 1 || Number(exports.rv_frame_format()) !== 4)
    throw new Error('renderer refused Web frame v4');
}

export function parseRendererFrameV4(exports, text) {
  try {
    const frame = JSON.parse(text);
    if (frame?.schema !== FRAME_SCHEMA_V4) throw new Error('renderer returned incompatible Web frame v4 schema');
    if (Number(frame.command_stride) !== BINARY_COMMAND_STRIDE)
      throw new Error('Web frame v4 command stride mismatch');
    if (!Array.isArray(frame.uploads) || !Array.isArray(frame.removals))
      throw new Error('Web frame v4 resource lease is malformed');
    for (const upload of frame.uploads) qualifiedKeyV4(upload?.q);
    for (const removal of frame.removals) qualifiedKeyV4(removal);
    const commands = new BinaryCommands(
      exports.memory,
      exports.rv_commands_ptr(),
      exports.rv_commands_count(),
      exports.rv_commands_stride(),
    );
    if (Number(frame.command_count) !== commands.count)
      throw new Error('Web frame v4 command count mismatch');
    frame.commands = commands;
    return frame;
  } catch (error) {
    // rv_render has staged residency/text before metadata publication. Clear it
    // before surfacing an incompatible frame so no acknowledgment is stranded.
    exports?.rv_reset?.();
    throw error;
  }
}
