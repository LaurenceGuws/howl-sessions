export const FRAME_SCHEMA_V3 = 'howl.web-frame/v3';

export const CommandV3 = Object.freeze({
  kind:0,
  x:1, y:2, width:3, height:4,
  solidRed:5, solidGreen:6, solidBlue:7, solidAlpha:8,
  clipX:5, clipY:6, clipWidth:7, clipHeight:8,
  resource:9, generation:10, format:11, resourceWidth:12, resourceHeight:13,
  sourceX:14, sourceY:15, sourceWidth:16, sourceHeight:17,
  red:18, green:19, blue:20, alpha:21, cursorComponent:22,
});

export const CommandV3Length = Object.freeze({solid:9, alpha:23, rgba:18});

export function selectRendererFrameV3(exports) {
  if (typeof exports?.rv_frame_format !== 'function' || typeof exports?.rv_set_frame_format !== 'function')
    throw new Error('renderer does not support Web frame v3 negotiation');
  if (Number(exports.rv_frame_format()) !== 2)
    throw new Error('renderer did not boot in backward-compatible Web frame v2 mode');
  if (exports.rv_set_frame_format(3) !== 1 || Number(exports.rv_frame_format()) !== 3)
    throw new Error('renderer refused Web frame v3');
}

export function requireFrameV3(frame) {
  if (frame?.schema !== FRAME_SCHEMA_V3) throw new Error('renderer returned incompatible Web frame schema');
  return frame;
}

export function parseRendererFrameV3(exports, text) {
  try {
    return requireFrameV3(JSON.parse(text));
  } catch (error) {
    // rv_render has already staged pending residency/text before it publishes
    // metadata. Reset before propagating an incompatible frame so the next
    // render cannot be stranded behind an acknowledgment that never happened.
    exports?.rv_reset?.();
    throw error;
  }
}
