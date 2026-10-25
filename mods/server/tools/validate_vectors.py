#!/usr/bin/env python3
"""Independent Server wire v2 vector decoder and validator.

This tool intentionally does not import, execute, or inspect the Zig
implementation.  The duplicated constants below are the client-facing wire
contract. Consequence payload semantics remain witnessed by Zig protocol tests; this
independent corpus currently treats established consequence bodies as bounded opaque bytes.  Keeping this decoder boring and separate gives the tracked golden
vectors a witness with a different implementation and language.
"""

from __future__ import annotations

import json
import struct
import sys
import zlib
from pathlib import Path


MAGIC = b"SRVR"
FRAMING_VERSION = 2
HEADER_BYTES = 12
MAXIMUM_PAYLOAD_BYTES = 1024 * 1024
MAXIMUM_TEXT_SNAPSHOT_BYTES = 4 * 1024 * 1024
MAXIMUM_PACKED_TEXT_BYTES = MAXIMUM_TEXT_SNAPSHOT_BYTES + 0xFFFF

CONTROL_KINDS = {1: 'hello', 2: 'welcome', 3: 'status', 4: 'status_snapshot', 5: 'observe_tree', 6: 'tree_snapshot', 7: 'create_session', 8: 'close_session', 9: 'create_instance', 10: 'close_instance', 11: 'attach_instance', 12: 'attach_ready', 13: 'control_result'}
TERMINAL_KINDS = {32: 'observe', 33: 'snapshot_begin', 34: 'snapshot_data', 35: 'snapshot_end', 36: 'input', 37: 'assign_leader', 38: 'resize', 39: 'signal', 40: 'result', 41: 'interaction_state', 42: 'interaction_state_snapshot', 43: 'assign_consequence_leader', 44: 'consequence_observe', 45: 'consequence_begin', 46: 'consequence_data', 47: 'consequence_end', 48: 'consequence_consume', 49: 'consequence_reply', 50: 'text_extract', 51: 'text_extract_data', 52: 'snapshot_graphics', 53: 'image_request', 54: 'image_begin', 55: 'image_data', 56: 'image_end', 57: 'observe_raw', 58: 'snapshot_raw_data', 59: 'observe_delta', 60: 'snapshot_delta_data', 61: 'snapshot_properties', 62: 'observe_packed', 63: 'snapshot_packed_data'}
KINDS = CONTROL_KINDS | TERMINAL_KINDS

INPUT_KINDS = {1: "bytes", 2: "paste", 3: "key", 4: "mouse", 5: "focus"}
KEY_KINDS = {1: "named", 2: "unicode"}
KEY_ACTIONS = {1: "press", 2: "repeat", 3: "release"}
MOUSE_KINDS = {1: "press", 2: "release", 3: "move", 4: "wheel"}
MOUSE_BUTTONS = {
    0: "none",
    1: "left",
    2: "middle",
    3: "right",
    4: "wheel_up",
    5: "wheel_down",
}
FOCUS = {1: "in", 2: "out"}
SIGNALS = {1: "hangup", 2: "interrupt", 3: "resize_notify", 9: "kill", 15: "terminate"}
RESULT_CODES = {
    0: "ok",
    1: "malformed",
    2: "unsupported",
    3: "no_such_client",
    4: "not_leader",
    5: "rejected",
}

TEXT_RECORD_KINDS = {1: "presentation", 2: "row", 3: "hyperlink", 4: "row_shift"}
TEXT_COLOR_KINDS = {0: "default", 1: "indexed", 2: "rgb"}

TEXT_PRESENTATION_BYTES = 1060
TEXT_RECORD_HEADER_BYTES = 8
TEXT_ROW_HEADER_BYTES = 4
TEXT_CELL_HEADER_BYTES = 35
TEXT_HYPERLINK_HEADER_BYTES = 6
TEXT_MAXIMUM_CELL_SCALARS = 24
TEXT_MAXIMUM_HYPERLINKS = 4096
TEXT_MAXIMUM_HYPERLINK_URI_BYTES = 2048
TEXT_PRESENTATION_PRESENCE_KNOWN = 0x0F
TEXT_PRESENTATION_FLAGS_KNOWN = 0x01
TEXT_STYLE_KNOWN = 0x01FF

GRAPHICS_HEADER_BYTES = 28
GRAPHICS_IMAGE_BYTES = 20
GRAPHICS_PLACEMENT_BYTES = 52
GRAPHICS_MAXIMUM_IMAGES = 256
GRAPHICS_MAXIMUM_PLACEMENTS = 16384
GRAPHICS_MAXIMUM_DIMENSION = 4096
GRAPHICS_MAXIMUM_IMAGE_BYTES = 16 * 1024 * 1024
GRAPHICS_DATA_CHUNK_BYTES = 256 * 1024

TYPED_KEY_HEADER_BYTES = 20
TYPED_MAXIMUM_LEGACY_KEY_BYTES = 511
TYPED_MAXIMUM_KEY_TEXT_BYTES = 64
TYPED_MOUSE_BYTES = 19
TYPED_FOCUS_BYTES = 1

INTERACTION_STATE_FLAGS = {
    0: "keyboard_action_mode",
    1: "auto_repeat",
    2: "newline_mode",
    3: "application_cursor_keys",
    4: "application_keypad",
    5: "meta_sends_escape",
    6: "report_key_up",
    7: "bracketed_paste",
    8: "focus_reporting",
    9: "termios_signals",
    10: "alternate_scroll",
    11: "paste_events",
    12: "inband_resize_notifications",
}
INTERACTION_MOUSE_TRACKING = {0: "off", 1: "x10", 2: "normal", 3: "button_event", 4: "any_event"}
INTERACTION_MOUSE_PROTOCOL = {0: "none", 1: "utf8", 2: "sgr", 3: "sgr_pixel", 4: "urxvt"}
INTERACTION_STATE_BYTES = 20

NAMED_KEY_MAXIMUM = 58


class WireError(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def reject(code: str) -> None:
    raise WireError(code)


def require(condition: bool, code: str) -> None:
    if not condition:
        reject(code)


def u16(data: bytes) -> int:
    require(len(data) == 2, "internal_u16")
    return int.from_bytes(data, "big")


def u32(data: bytes) -> int:
    require(len(data) == 4, "internal_u32")
    return int.from_bytes(data, "big")


def i32(data: bytes) -> int:
    require(len(data) == 4, "internal_i32")
    return struct.unpack(">i", data)[0]


def u64(data: bytes) -> int:
    require(len(data) == 8, "internal_u64")
    return int.from_bytes(data, "big")


def valid_scalar(value: int) -> bool:
    return value <= 0x10FFFF and not 0xD800 <= value <= 0xDFFF


def decode_hello(payload: bytes) -> dict:
    require(len(payload) == 0, "hello_size")
    return {}


def decode_welcome(payload: bytes) -> dict:
    require(len(payload) == 32, "welcome_size")
    require(payload[24:] == bytes(8), "welcome_reserved")
    server_id, revision, sessions, instances, session_capacity, instance_capacity = struct.unpack(">QQHHHH", payload[:24])
    require(server_id != 0 and revision != 0, "welcome_identity")
    require(0 < session_capacity <= 16 and 0 < instance_capacity <= 16, "welcome_capacity")
    require(sessions <= session_capacity and instances <= sessions * instance_capacity, "welcome_counts")
    return {"server_id": server_id, "tree_revision": revision, "session_count": sessions,
            "instance_count": instances, "session_capacity": session_capacity,
            "instances_per_session": instance_capacity}


def decode_attach_ready(payload: bytes) -> dict:
    require(len(payload) == 40, "attach_ready_size")
    values = struct.unpack(">QQQQQ", payload)
    require(all(value != 0 for value in values), "attach_ready_identity")
    return dict(zip(("server_id", "session_id", "instance_id", "tree_revision", "client_id"), values))


def decode_attach_instance(payload: bytes) -> dict:
    require(len(payload) == 16, "attach_instance_size")
    session_id, instance_id = struct.unpack(">QQ", payload)
    require(session_id != 0 and instance_id != 0, "attach_instance_identity")
    return {"session_id": session_id, "instance_id": instance_id}


def decode_observe(payload: bytes) -> dict:
    require(len(payload) == 12, "observe_size")
    return {
        "after_revision": u64(payload[0:8]),
        "history_offset": u32(payload[8:12]),
    }


def decode_snapshot_begin(payload: bytes) -> dict:
    require(len(payload) == 38, "snapshot_begin_size")
    flags = payload[37]
    require(flags & 0x80 == 0, "snapshot_flags")
    return {
        "revision": u64(payload[0:8]),
        "terminal_revision": u64(payload[8:16]),
        "history_offset": u32(payload[16:20]),
        "history_count": u32(payload[20:24]),
        "history_row_base": u32(payload[24:28]),
        "rows": u16(payload[28:30]),
        "columns": u16(payload[30:32]),
        "cursor_row": u16(payload[32:34]),
        "cursor_column": u16(payload[34:36]),
        "cursor_shape": payload[36],
        "cursor_visible": bool(flags & (1 << 0)),
        "cursor_blink": bool(flags & (1 << 1)),
        "alternate_screen": bool(flags & (1 << 2)),
        "stream_closed": bool(flags & (1 << 3)),
        "child_exited": bool(flags & (1 << 4)),
        "leader_present": bool(flags & (1 << 5)),
        "you_are_leader": bool(flags & (1 << 6)),
    }


def decode_snapshot_end(payload: bytes) -> dict:
    require(len(payload) == 8, "snapshot_end_size")
    return {"revision": u64(payload)}


def decode_assign_leader(payload: bytes) -> dict:
    require(len(payload) == 8, "assign_leader_size")
    return {"client_id": u64(payload)}


def decode_resize(payload: bytes) -> dict:
    require(len(payload) == 8, "resize_size")
    width, height = u16(payload[4:6]), u16(payload[6:8])
    require((width == 0) == (height == 0), "resize_pixels")
    return {"rows": u16(payload[0:2]), "columns": u16(payload[2:4]),
            "cell_pixel_width": width, "cell_pixel_height": height}


def decode_signal(payload: bytes) -> dict:
    require(len(payload) == 1, "signal_size")
    require(payload[0] in SIGNALS, "signal_value")
    return {"signal": SIGNALS[payload[0]]}


def decode_interaction_state(payload: bytes) -> dict:
    require(len(payload) == 0, "interaction_state_size")
    return {}


def decode_interaction_state_snapshot(payload: bytes) -> dict:
    require(len(payload) == INTERACTION_STATE_BYTES, "interaction_state_snapshot_size")
    flags = u32(payload[8:12])
    known_mask = (1 << len(INTERACTION_STATE_FLAGS)) - 1
    require(flags & ~known_mask == 0, "interaction_state_flags")
    require(payload[12] in INTERACTION_MOUSE_TRACKING, "interaction_mouse_tracking")
    require(payload[13] in INTERACTION_MOUSE_PROTOCOL, "interaction_mouse_protocol")
    require(payload[15] & 0x80 == 0, "interaction_kitty_flags")
    require(payload[18] <= 3, "interaction_pointer_mode")
    require(payload[19] == 0, "interaction_reserved")
    result = {
        "terminal_revision": u64(payload[0:8]),
        "mouse_tracking": INTERACTION_MOUSE_TRACKING[payload[12]],
        "mouse_protocol": INTERACTION_MOUSE_PROTOCOL[payload[13]],
        "modify_other_keys": struct.unpack("b", payload[14:15])[0],
        "kitty_keyboard_flags": payload[15],
        "key_format_resource_4": u16(payload[16:18]),
        "pointer_mode": payload[18],
    }
    for bit, name in INTERACTION_STATE_FLAGS.items():
        result[name] = bool(flags & (1 << bit))
    return result


def decode_result(payload: bytes) -> dict:
    require(len(payload) == 2, "result_size")
    require(payload[0] in TERMINAL_KINDS, "result_request_kind")
    require(payload[1] in RESULT_CODES, "result_code")
    return {
        "request_kind": KINDS[payload[0]],
        "code": RESULT_CODES[payload[1]],
    }


def decode_typed_key(body: bytes) -> dict:
    require(len(body) >= TYPED_KEY_HEADER_BYTES, "key_size")
    key_kind = body[0]
    action = body[1]
    modifiers = body[2]
    presence = body[3]
    require(key_kind in KEY_KINDS, "key_kind")
    require(action in KEY_ACTIONS, "key_action")
    require(presence & ~0x03 == 0, "key_presence")

    key_value = u32(body[4:8])
    shifted_raw = u32(body[8:12])
    alternate_raw = u32(body[12:16])
    legacy_len = u16(body[16:18])
    text_len = u16(body[18:20])
    require(legacy_len <= TYPED_MAXIMUM_LEGACY_KEY_BYTES, "key_legacy_limit")
    require(text_len <= TYPED_MAXIMUM_KEY_TEXT_BYTES, "key_text_limit")
    require(len(body) == TYPED_KEY_HEADER_BYTES + legacy_len + text_len, "key_size")

    if key_kind == 1:
        require(1 <= key_value <= NAMED_KEY_MAXIMUM, "key_name")
    else:
        require(valid_scalar(key_value), "key_unicode")

    shifted_present = bool(presence & 0x01)
    alternate_present = bool(presence & 0x02)
    if shifted_present:
        require(valid_scalar(shifted_raw), "key_shifted_unicode")
        shifted = shifted_raw
    else:
        require(shifted_raw == 0, "key_shifted_canonical")
        shifted = None
    if alternate_present:
        require(valid_scalar(alternate_raw), "key_alternate_unicode")
        alternate = alternate_raw
    else:
        require(alternate_raw == 0, "key_alternate_canonical")
        alternate = None

    legacy = body[20 : 20 + legacy_len]
    text_bytes = body[20 + legacy_len :]
    try:
        text = text_bytes.decode("utf-8")
    except UnicodeDecodeError:
        reject("key_text_utf8")

    return {
        "kind": KEY_KINDS[key_kind],
        "key_value": key_value,
        "action": KEY_ACTIONS[action],
        "modifiers": modifiers,
        "shifted": shifted,
        "alternate": alternate,
        "legacy_len": legacy_len,
        "legacy_hex": legacy.hex(),
        "text_len": text_len,
        "text": text,
    }


def decode_typed_mouse(body: bytes) -> dict:
    require(len(body) == TYPED_MOUSE_BYTES, "mouse_size")
    require(body[0] in MOUSE_KINDS, "mouse_kind")
    require(body[1] in MOUSE_BUTTONS, "mouse_button")
    require(body[3] & ~0x07 == 0, "mouse_buttons_down")
    presence = body[10]
    require(presence & ~0x01 == 0, "mouse_presence")
    pixel_x_raw = u32(body[11:15])
    pixel_y_raw = u32(body[15:19])
    pixels_present = bool(presence & 0x01)
    if not pixels_present:
        require(pixel_x_raw == 0 and pixel_y_raw == 0, "mouse_pixels_canonical")
    return {
        "kind": MOUSE_KINDS[body[0]],
        "button": MOUSE_BUTTONS[body[1]],
        "modifiers": body[2],
        "buttons_down": body[3],
        "row": i32(body[4:8]),
        "column": u16(body[8:10]),
        "pixel_x": pixel_x_raw if pixels_present else None,
        "pixel_y": pixel_y_raw if pixels_present else None,
    }


def decode_typed_focus(body: bytes) -> dict:
    require(len(body) == TYPED_FOCUS_BYTES, "focus_size")
    require(body[0] in FOCUS, "focus_value")
    return {"focus": FOCUS[body[0]]}


def decode_input(payload: bytes) -> dict:
    require(len(payload) >= 1, "input_size")
    input_kind = payload[0]
    require(input_kind in INPUT_KINDS, "input_kind")
    body = payload[1:]
    name = INPUT_KINDS[input_kind]
    if name in ("bytes", "paste"):
        return {"kind": name, "bytes_hex": body.hex()}
    if name == "key":
        return {"kind": name, "key": decode_typed_key(body)}
    if name == "mouse":
        return {"kind": name, "mouse": decode_typed_mouse(body)}
    return {"kind": name, **decode_typed_focus(body)}


def decode_color(data: bytes) -> dict:
    require(len(data) == 5, "text_color_size")
    kind = data[0]
    value = u32(data[1:5])
    require(kind in TEXT_COLOR_KINDS, "text_color_kind")
    if kind == 0:
        require(value == 0, "text_color_default")
    elif kind == 1:
        require(value <= 255, "text_color_indexed")
    else:
        require(value <= 0x00FFFFFF, "text_color_rgb")
    return {"kind": TEXT_COLOR_KINDS[kind], "value": value}


def rgba(data: bytes) -> str:
    require(len(data) == 4, "internal_rgba")
    return data.hex()


def decode_presentation(payload: bytes) -> dict:
    require(len(payload) == TEXT_PRESENTATION_BYTES, "text_presentation_size")
    presence = payload[8]
    flags = payload[9]
    require(presence & ~TEXT_PRESENTATION_PRESENCE_KNOWN == 0, "text_presentation_presence")
    require(flags & ~TEXT_PRESENTATION_FLAGS_KNOWN == 0, "text_presentation_flags")
    require(payload[10] == 0 and payload[11] == 0, "text_presentation_reserved")

    palette = payload[12:1036]
    foreground = payload[1036:1040]
    background = payload[1040:1044]
    cursor = payload[1044:1048]
    cursor_text = payload[1048:1052]
    selection_background = payload[1052:1056]
    selection_foreground = payload[1056:1060]
    return {
        "cursor_age_ns": u64(payload[0:8]),
        "presence": presence,
        "reverse_screen": bool(flags & 0x01),
        "palette_samples": {
            "0": rgba(palette[0:4]),
            "1": rgba(palette[4:8]),
            "255": rgba(palette[1020:1024]),
        },
        "foreground": rgba(foreground),
        "background": rgba(background),
        "cursor": rgba(cursor) if presence & 0x01 else None,
        "cursor_text": rgba(cursor_text) if presence & 0x02 else None,
        "selection_background": rgba(selection_background) if presence & 0x04 else None,
        "selection_foreground": rgba(selection_foreground) if presence & 0x08 else None,
    }


def decode_text_row(payload: bytes, columns: int, referenced_links: set[int]) -> dict:
    require(len(payload) >= TEXT_ROW_HEADER_BYTES, "text_row_size")
    require(payload[0] <= 1, "text_row_wrapped")
    require(payload[1] <= 3, "text_row_geometry")
    require(u16(payload[2:4]) == columns, "text_row_columns")

    offset = TEXT_ROW_HEADER_BYTES
    cells = []
    for _ in range(columns):
        require(len(payload) - offset >= TEXT_CELL_HEADER_BYTES, "text_cell_size")
        cell = payload[offset : offset + TEXT_CELL_HEADER_BYTES]
        scalar_count = cell[0]
        width = cell[1]
        height = cell[2]
        x = cell[3]
        y = cell[4]
        require(scalar_count <= TEXT_MAXIMUM_CELL_SCALARS, "text_scalar_count")
        require(width > 0 and height > 0 and x < width and y < height, "text_cell_geometry")
        require(cell[5] <= 15 and cell[6] <= 15, "text_cell_subscale")
        require(cell[7] <= 3 and cell[8] <= 3, "text_cell_alignment")
        require(cell[9] <= 1, "text_cell_semantic_width")
        require(cell[10] <= 15, "text_cell_font")
        require(cell[11] <= 2, "text_cell_baseline")
        require(cell[12] <= 4, "text_cell_underline")
        require(cell[13] <= 2, "text_cell_protection")
        style = u16(cell[14:16])
        require(style & ~TEXT_STYLE_KNOWN == 0, "text_style_bits")
        fg = decode_color(cell[16:21])
        bg = decode_color(cell[21:26])
        underline = decode_color(cell[26:31])
        link_id = u32(cell[31:35])
        require(link_id <= TEXT_MAXIMUM_HYPERLINKS, "text_link_id")
        if link_id:
            referenced_links.add(link_id)

        offset += TEXT_CELL_HEADER_BYTES
        scalar_bytes = scalar_count * 4
        require(len(payload) - offset >= scalar_bytes, "text_scalar_bytes")
        scalars = []
        for scalar_offset in range(offset, offset + scalar_bytes, 4):
            scalar = u32(payload[scalar_offset : scalar_offset + 4])
            require(valid_scalar(scalar), "text_scalar_unicode")
            scalars.append(scalar)
        require((x == 0 and y == 0) or not scalars, "text_continuation_scalars")
        offset += scalar_bytes

        cells.append(
            {
                "scalars": scalars,
                "width": width,
                "height": height,
                "x": x,
                "y": y,
                "subscale_n": cell[5],
                "subscale_d": cell[6],
                "vertical_align": cell[7],
                "horizontal_align": cell[8],
                "semantic_width": bool(cell[9]),
                "font": cell[10],
                "baseline": cell[11],
                "underline_style": cell[12],
                "protection": cell[13],
                "style": style,
                "fg": fg,
                "bg": bg,
                "underline_color": underline,
                "link_id": link_id,
            }
        )
    require(offset == len(payload), "text_row_trailing")
    return {
        "wrapped": bool(payload[0]),
        "line_geometry": payload[1],
        "columns": columns,
        "cells": cells,
    }


def decode_hyperlink(payload: bytes, resolved_links: dict[int, str]) -> dict:
    require(len(payload) >= TEXT_HYPERLINK_HEADER_BYTES, "text_hyperlink_size")
    link_id = u32(payload[0:4])
    uri_len = u16(payload[4:6])
    require(1 <= link_id <= TEXT_MAXIMUM_HYPERLINKS, "text_hyperlink_id")
    require(1 <= uri_len <= TEXT_MAXIMUM_HYPERLINK_URI_BYTES, "text_hyperlink_uri_limit")
    require(len(payload) == TEXT_HYPERLINK_HEADER_BYTES + uri_len, "text_hyperlink_size")
    require(link_id not in resolved_links, "text_hyperlink_duplicate")
    uri_hex = payload[6:].hex()
    resolved_links[link_id] = uri_hex
    return {"link_id": link_id, "uri_hex": uri_hex}


def new_snapshot(begin: dict, delta_request: dict | None = None, baseline: dict | None = None) -> dict:
    return {
        "begin": begin,
        "encoded_body": bytearray(),
        "body_encoding": None,
        "presentation": None,
        "text_rows": [],
        "hyperlinks": [],
        "referenced_links": set(),
        "resolved_links": {},
        "phase": "presentation",
        "graphics": None,
        "properties": None,
        "delta_request": delta_request,
        "baseline": baseline,
        "row_shift": None,
        "reuse_rows": None,
    }


def decode_text_records(payload: bytes, snapshot: dict) -> list[dict]:
    records = []
    offset = 0
    while offset < len(payload):
        require(len(payload) - offset >= TEXT_RECORD_HEADER_BYTES, "text_record_size")
        header = payload[offset : offset + TEXT_RECORD_HEADER_BYTES]
        kind = header[0]
        require(header[1:4] == b"\x00\x00\x00", "text_record_reserved")
        require(kind in TEXT_RECORD_KINDS, "text_record_kind")
        payload_len = u32(header[4:8])
        offset += TEXT_RECORD_HEADER_BYTES
        require(len(payload) - offset >= payload_len, "text_record_size")
        record_payload = payload[offset : offset + payload_len]
        offset += payload_len
        name = TEXT_RECORD_KINDS[kind]

        if name == "presentation":
            require(snapshot["phase"] == "presentation" and snapshot["presentation"] is None, "text_record_order")
            decoded = decode_presentation(record_payload)
            snapshot["presentation"] = decoded
            snapshot["phase"] = "links" if snapshot["begin"]["rows"] == 0 else "rows"
        elif name == "row_shift":
            require(snapshot["body_encoding"] == "delta", "text_row_shift_encoding")
            require(snapshot["phase"] == "rows" and snapshot["presentation"] is not None, "text_record_order")
            require(snapshot["row_shift"] is None and not snapshot["text_rows"], "text_row_shift_duplicate")
            require(len(record_payload) == 2, "text_row_shift_size")
            rows_up = u16(record_payload)
            require(rows_up == 0 or rows_up < snapshot["begin"]["rows"], "text_row_shift_range")
            baseline = snapshot["baseline"]
            require(baseline is not None, "snapshot_delta_baseline")
            require(len(baseline["rows"]) == snapshot["begin"]["rows"], "snapshot_delta_baseline_rows")
            snapshot["row_shift"] = rows_up
            snapshot["reuse_rows"] = baseline["rows"][rows_up:] + [None] * rows_up
            decoded = {"rows_up": rows_up}
        elif name == "row":
            require(snapshot["phase"] == "rows", "text_record_order")
            if snapshot["body_encoding"] == "delta":
                require(snapshot["row_shift"] is not None, "text_row_shift_missing")
            require(len(snapshot["text_rows"]) < snapshot["begin"]["rows"], "text_row_count")
            row_index = len(snapshot["text_rows"])
            if not record_payload:
                require(snapshot["body_encoding"] == "delta", "text_row_reuse_encoding")
                reuse_rows = snapshot["reuse_rows"]
                require(reuse_rows is not None and row_index < len(reuse_rows), "snapshot_delta_baseline_rows")
                decoded = reuse_rows[row_index]
                require(decoded is not None, "snapshot_delta_shift_exposed_reuse")
                for cell in decoded["cells"]:
                    if cell["link_id"]:
                        snapshot["referenced_links"].add(cell["link_id"])
            else:
                decoded = decode_text_row(
                    record_payload,
                    snapshot["begin"]["columns"],
                    snapshot["referenced_links"],
                )
            snapshot["text_rows"].append(decoded)
            if len(snapshot["text_rows"]) == snapshot["begin"]["rows"]:
                snapshot["phase"] = "links"
        else:
            require(snapshot["phase"] == "links", "text_record_order")
            decoded = decode_hyperlink(record_payload, snapshot["resolved_links"])
            snapshot["hyperlinks"].append(decoded)
        records.append({"kind": name, "payload": decoded})
    return records



def unpack_text_v1(packed: bytes, expected_text_len: int) -> bytes:
    require(0 < len(packed) <= MAXIMUM_PACKED_TEXT_BYTES, "snapshot_packed_limit")
    require(0 < expected_text_len <= MAXIMUM_TEXT_SNAPSHOT_BYTES, "snapshot_raw_limit")
    output = bytearray()
    offset = 0
    while offset < len(packed):
        require(len(packed) - offset >= TEXT_RECORD_HEADER_BYTES, "snapshot_packed_record")
        header = packed[offset:offset + TEXT_RECORD_HEADER_BYTES]
        kind = header[0]
        require(header[1:4] == b"\0\0\0" and kind in TEXT_RECORD_KINDS, "snapshot_packed_record")
        payload_len = u32(header[4:8])
        output.extend(header)
        offset += TEXT_RECORD_HEADER_BYTES
        if kind in (1, 3):
            require(payload_len <= len(packed) - offset, "snapshot_packed_record")
            output.extend(packed[offset:offset + payload_len])
            offset += payload_len
        elif kind == 2:
            require(offset < len(packed), "snapshot_packed_row")
            mode = packed[offset]
            offset += 1
            if mode == 0:
                require(payload_len <= len(packed) - offset, "snapshot_packed_row")
                output.extend(packed[offset:offset + payload_len])
                offset += payload_len
            else:
                require(mode == 1, "snapshot_packed_row_mode")
                payload_start = len(output)
                require(len(packed) - offset >= TEXT_ROW_HEADER_BYTES + 2, "snapshot_packed_row")
                row_header = packed[offset:offset + TEXT_ROW_HEADER_BYTES]
                columns = u16(row_header[2:4])
                output.extend(row_header)
                offset += TEXT_ROW_HEADER_BYTES
                run_count = u16(packed[offset:offset + 2])
                offset += 2
                require(run_count != 0 or columns == 0, "snapshot_packed_run_count")
                require(run_count <= columns if columns else run_count == 0, "snapshot_packed_run_count")
                emitted = 0
                for _ in range(run_count):
                    require(len(packed) - offset >= 2 + (TEXT_CELL_HEADER_BYTES - 1), "snapshot_packed_run")
                    run_len = u16(packed[offset:offset + 2])
                    offset += 2
                    require(run_len != 0 and run_len <= columns - emitted, "snapshot_packed_run_length")
                    attrs = packed[offset:offset + TEXT_CELL_HEADER_BYTES - 1]
                    offset += TEXT_CELL_HEADER_BYTES - 1
                    for _ in range(run_len):
                        require(offset < len(packed), "snapshot_packed_cell")
                        scalar_count = packed[offset]
                        offset += 1
                        require(scalar_count <= TEXT_MAXIMUM_CELL_SCALARS, "snapshot_packed_scalar_count")
                        scalar_bytes = scalar_count * 4
                        require(scalar_bytes <= len(packed) - offset, "snapshot_packed_cell")
                        output.append(scalar_count)
                        output.extend(attrs)
                        output.extend(packed[offset:offset + scalar_bytes])
                        offset += scalar_bytes
                        emitted += 1
                require(emitted == columns, "snapshot_packed_columns")
                require(len(output) - payload_start == payload_len, "snapshot_packed_row_size")
        else:
            reject("snapshot_packed_record_kind")
        require(len(output) <= expected_text_len, "snapshot_packed_text_size")
    require(offset == len(packed) and len(output) == expected_text_len, "snapshot_packed_text_size")
    return bytes(output)


def finish_snapshot(snapshot: dict, end: dict) -> dict:
    begin = snapshot["begin"]
    require(end["revision"] == begin["revision"], "snapshot_revision")
    encoded = bytes(snapshot["encoded_body"])
    encoding = snapshot["body_encoding"]
    require(encoding is not None, "snapshot_data_missing")
    if encoding == "raw" or encoding == "delta":
        require(0 < len(encoded) <= MAXIMUM_TEXT_SNAPSHOT_BYTES, "snapshot_raw_limit")
        if encoding == "delta":
            request = snapshot["delta_request"]
            baseline = snapshot["baseline"]
            require(request is not None and request["after_revision"] != 0, "snapshot_delta_request")
            require(baseline is not None, "snapshot_delta_baseline")
            require(baseline["begin"]["revision"] == request["after_revision"], "snapshot_delta_revision")
            require(baseline["begin"]["history_offset"] == request["history_offset"], "snapshot_delta_history")
            require(baseline["begin"]["rows"] == begin["rows"] and baseline["begin"]["columns"] == begin["columns"], "snapshot_delta_geometry")
        body = encoded
    elif encoding == "packed":
        require(len(encoded) > 8, "snapshot_compressed_size")
        text_len = u32(encoded[0:4])
        packed_len = u32(encoded[4:8])
        require(0 < text_len <= MAXIMUM_TEXT_SNAPSHOT_BYTES, "snapshot_raw_limit")
        require(0 < packed_len <= MAXIMUM_PACKED_TEXT_BYTES, "snapshot_packed_limit")
        inflater = zlib.decompressobj()
        try:
            packed_body = inflater.decompress(encoded[8:], packed_len + 1)
            packed_body += inflater.flush()
        except zlib.error:
            reject("snapshot_compression")
        require(inflater.eof and not inflater.unused_data and not inflater.unconsumed_tail, "snapshot_compression")
        require(len(packed_body) == packed_len, "snapshot_packed_size")
        body = unpack_text_v1(packed_body, text_len)
    else:
        require(len(encoded) > 4, "snapshot_compressed_size")
        raw_len = u32(encoded[0:4])
        require(0 < raw_len <= MAXIMUM_TEXT_SNAPSHOT_BYTES, "snapshot_raw_limit")
        inflater = zlib.decompressobj()
        try:
            body = inflater.decompress(encoded[4:], raw_len + 1)
            body += inflater.flush()
        except zlib.error:
            reject("snapshot_compression")
        require(inflater.eof and not inflater.unused_data and not inflater.unconsumed_tail, "snapshot_compression")
        require(len(body) == raw_len, "snapshot_raw_size")
    decode_text_records(body, snapshot)
    require((encoding == "delta") == (snapshot["row_shift"] is not None), "text_row_shift_missing")
    require(snapshot["presentation"] is not None, "text_presentation_missing")
    require(len(snapshot["text_rows"]) == begin["rows"], "text_row_count")
    require(snapshot["referenced_links"] == set(snapshot["resolved_links"]), "text_unresolved_hyperlink")
    require(snapshot["graphics"] is not None, "snapshot_graphics_missing")
    require(snapshot["properties"] is not None, "snapshot_properties_missing")
    return {
        "begin": begin,
        "presentation": snapshot["presentation"],
        "rows": snapshot["text_rows"],
        "hyperlinks": snapshot["hyperlinks"],
        "graphics": snapshot["graphics"],
        "properties": snapshot["properties"],
        "end": end,
        "encoding": encoding,
    }


def decode_properties(payload: bytes) -> dict:
    require(36 <= len(payload) <= 6180, "properties_size")
    require(payload[0] == 1 and payload[1] & 0x80 == 0 and payload[22:24] == b"\0\0", "properties_header")
    flags = payload[1]
    lengths = struct.unpack_from(">6H", payload, 24)
    require(all(n <= 1024 for n in lengths) and sum(lengths) + 36 == len(payload), "properties_size")
    values = []
    offset = 36
    for index, count in enumerate(lengths):
        present = index == 5 or bool(flags & (1 << (5 if index == 4 else index)))
        require(present or count == 0, "properties_presence")
        values.append(payload[offset:offset + count].hex() if present else None)
        offset += count
    directory_kind, mark_kind = payload[2], payload[3]
    shell_version = u32(payload[4:8])
    mark_generation, mark_status = u64(payload[8:16]), i32(payload[16:20])
    require((values[2] is None and directory_kind == 0) or (values[2] is not None and directory_kind in (1, 2)), "properties_directory")
    require(bool(flags & 16) or (values[4] is None and shell_version == 0), "properties_shell")
    require(bool(flags & 64) or mark_status == 0, "properties_status")
    require((mark_kind == 0 and mark_generation == 0 and not flags & 64 and values[5] == "") or
            (65 <= mark_kind <= 68 and mark_generation != 0 and (not flags & 64 or mark_kind == 68)), "properties_mark")
    kind, value = payload[20], payload[21]
    require(kind <= 4 and value <= 100 and (kind not in (0, 3) or value == 0), "properties_progress")
    return {"title_hex": values[0], "icon_hex": values[1], "directory_kind": directory_kind,
            "directory_hex": values[2], "remote_host_hex": values[3],
            "shell_version": shell_version if flags & 16 else None, "shell_name_hex": values[4],
            "mark_kind": mark_kind, "mark_generation": mark_generation,
            "mark_status": mark_status if flags & 64 else None, "mark_metadata_hex": values[5],
            "progress_kind": kind, "progress_value": value}


def decode_snapshot_graphics(payload: bytes, begin: dict) -> dict:
    require(len(payload) >= GRAPHICS_HEADER_BYTES, "snapshot_graphics_size")
    generation = u64(payload[0:8])
    content_generation = u64(payload[8:16])
    cell_pixel_width = u32(payload[16:20])
    cell_pixel_height = u32(payload[20:24])
    image_count = u16(payload[24:26])
    placement_count = u16(payload[26:28])
    require(cell_pixel_width != 0 and cell_pixel_height != 0, "snapshot_graphics_cell_pixels")
    require(image_count <= GRAPHICS_MAXIMUM_IMAGES, "snapshot_graphics_images")
    require(placement_count <= GRAPHICS_MAXIMUM_PLACEMENTS, "snapshot_graphics_placements")
    expected = GRAPHICS_HEADER_BYTES + image_count * GRAPHICS_IMAGE_BYTES + placement_count * GRAPHICS_PLACEMENT_BYTES
    require(len(payload) == expected, "snapshot_graphics_size")
    images = []
    image_by_id = {}
    offset = GRAPHICS_HEADER_BYTES
    for _ in range(image_count):
        item = payload[offset : offset + GRAPHICS_IMAGE_BYTES]
        image_id = u32(item[0:4])
        image_generation = u64(item[4:12])
        width = u32(item[12:16])
        height = u32(item[16:20])
        require(image_id != 0 and image_generation != 0, "snapshot_image_identity")
        require(0 < width <= GRAPHICS_MAXIMUM_DIMENSION and 0 < height <= GRAPHICS_MAXIMUM_DIMENSION, "snapshot_image_extent")
        require(width * height * 4 <= GRAPHICS_MAXIMUM_IMAGE_BYTES, "snapshot_image_bytes")
        require(image_id not in image_by_id, "snapshot_image_duplicate")
        decoded = {"image_id": image_id, "generation": image_generation, "width": width, "height": height}
        image_by_id[image_id] = decoded
        images.append(decoded)
        offset += GRAPHICS_IMAGE_BYTES
    placements = []
    referenced = set()
    for _ in range(placement_count):
        item = payload[offset : offset + GRAPHICS_PLACEMENT_BYTES]
        image_id = u32(item[0:4])
        placement_generation = u64(item[4:12])
        row = u16(item[12:14])
        column = u16(item[14:16])
        source_x = u32(item[16:20])
        source_y = u32(item[20:24])
        source_width = u32(item[24:28])
        source_height = u32(item[28:32])
        cell_x = u32(item[32:36])
        cell_y = u32(item[36:40])
        pixel_width = u32(item[40:44])
        pixel_height = u32(item[44:48])
        z = i32(item[48:52])
        require(image_id != 0 and placement_generation != 0, "snapshot_placement_identity")
        require(source_width != 0 and source_height != 0 and pixel_width != 0 and pixel_height != 0, "snapshot_placement_extent")
        require(row < begin["rows"] and column < begin["columns"], "snapshot_placement_cell")
        require(image_id in image_by_id, "snapshot_placement_image")
        image = image_by_id[image_id]
        require(source_x <= image["width"] and source_y <= image["height"], "snapshot_placement_source")
        require(source_width <= image["width"] - source_x and source_height <= image["height"] - source_y, "snapshot_placement_source")
        referenced.add(image_id)
        placements.append({
            "image_id": image_id,
            "generation": placement_generation,
            "row": row,
            "column": column,
            "source_x": source_x,
            "source_y": source_y,
            "source_width": source_width,
            "source_height": source_height,
            "cell_x": cell_x,
            "cell_y": cell_y,
            "pixel_width": pixel_width,
            "pixel_height": pixel_height,
            "z": z,
        })
        offset += GRAPHICS_PLACEMENT_BYTES
    require(referenced == set(image_by_id), "snapshot_image_unreferenced")
    return {
        "generation": generation,
        "content_generation": content_generation,
        "cell_pixel_width": cell_pixel_width,
        "cell_pixel_height": cell_pixel_height,
        "images": images,
        "placements": placements,
    }


def decode_image_request(payload: bytes) -> dict:
    require(len(payload) == 12, "image_request_size")
    image_id = u32(payload[0:4])
    generation = u64(payload[4:12])
    require(image_id != 0 and generation != 0, "image_request_identity")
    return {"image_id": image_id, "generation": generation}


def decode_image_begin(payload: bytes) -> dict:
    require(len(payload) == 24, "image_begin_size")
    image_id = u32(payload[0:4])
    generation = u64(payload[4:12])
    width = u32(payload[12:16])
    height = u32(payload[16:20])
    byte_count = u32(payload[20:24])
    require(image_id != 0 and generation != 0, "image_begin_identity")
    require(0 < width <= GRAPHICS_MAXIMUM_DIMENSION and 0 < height <= GRAPHICS_MAXIMUM_DIMENSION, "image_begin_extent")
    require(byte_count == width * height * 4 and byte_count <= GRAPHICS_MAXIMUM_IMAGE_BYTES, "image_begin_bytes")
    return {"image_id": image_id, "generation": generation, "width": width, "height": height, "byte_count": byte_count}


def decode_image_end(payload: bytes) -> dict:
    require(len(payload) == 12, "image_end_size")
    image_id = u32(payload[0:4])
    generation = u64(payload[4:12])
    require(image_id != 0 and generation != 0, "image_end_identity")
    return {"image_id": image_id, "generation": generation}


def decode_text_extract(payload: bytes) -> dict:
    require(len(payload) == 16, "text_extract_size")
    require(payload[14] <= 1 and payload[15] == 0, "text_extract_flags")
    columns = u16(payload[12:14])
    require(columns > 0, "text_extract_columns")
    return {
        "start": {"row": i32(payload[0:4]), "column": u16(payload[4:6])},
        "end": {"row": i32(payload[6:10]), "column": u16(payload[10:12])},
        "columns": columns,
        "alternate_screen": bool(payload[14]),
    }


def decode_text_extract_data(payload: bytes) -> dict:
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError:
        reject("text_extract_utf8")
    return {"text": text}


def decode_fixed_payload(kind: int, payload: bytes) -> dict:
    if kind == 1:
        return decode_hello(payload)
    if kind in (2, 4):
        return decode_welcome(payload)
    if kind == 11:
        return decode_attach_instance(payload)
    if kind == 12:
        return decode_attach_ready(payload)
    if kind in CONTROL_KINDS:
        # Control operations have Zig semantic proofs; this corpus witnesses their framing.
        return {"bytes_hex": payload.hex()}
    if kind in (32, 57, 59, 62):
        return decode_observe(payload)
    if kind == 33:
        return decode_snapshot_begin(payload)
    if kind == 35:
        return decode_snapshot_end(payload)
    if kind == 36:
        return decode_input(payload)
    if kind == 37:
        return decode_assign_leader(payload)
    if kind == 38:
        return decode_resize(payload)
    if kind == 39:
        return decode_signal(payload)
    if kind == 40:
        return decode_result(payload)
    if kind == 41:
        return decode_interaction_state(payload)
    if kind == 42:
        return decode_interaction_state_snapshot(payload)
    if 43 <= kind <= 49:
        return {"bytes_hex": payload.hex()}
    if kind == 50:
        return decode_text_extract(payload)
    if kind == 51:
        return decode_text_extract_data(payload)
    if kind == 53:
        return decode_image_request(payload)
    reject("snapshot_data_without_begin")


def decode_stream(data: bytes) -> dict:
    frames = []
    snapshots = []
    image_resources = []
    snapshot = None
    image_resource = None
    pending_delta_request = None
    offset = 0
    while offset < len(data):
        require(len(data) - offset >= HEADER_BYTES, "truncated_header")
        header = data[offset : offset + HEADER_BYTES]
        require(header[0:4] == MAGIC, "header_magic")
        require(header[4] == FRAMING_VERSION, "header_version")
        require(header[6] == 0 and header[7] == 0, "header_reserved")
        kind = header[5]
        require(kind in KINDS, "header_kind")
        payload_len = u32(header[8:12])
        require(payload_len <= (8 * 1024 if kind in CONTROL_KINDS else MAXIMUM_PAYLOAD_BYTES), "payload_limit")
        offset += HEADER_BYTES
        require(len(data) - offset >= payload_len, "truncated_frame")
        payload = data[offset : offset + payload_len]
        offset += payload_len

        name = KINDS[kind]
        if kind == 33:
            require(snapshot is None and image_resource is None, "snapshot_nested")
            decoded = decode_snapshot_begin(payload)
            baseline = None
            if pending_delta_request is not None:
                for prior in reversed(snapshots):
                    if (prior["begin"]["revision"] == pending_delta_request["after_revision"] and
                            prior["begin"]["history_offset"] == pending_delta_request["history_offset"]):
                        baseline = prior
                        break
            snapshot = new_snapshot(decoded, pending_delta_request, baseline)
        elif kind in (34, 58, 60, 63):
            require(snapshot is not None, "snapshot_data_without_begin")
            require(snapshot["graphics"] is None, "snapshot_graphics_order")
            encoding = {34: "compressed", 58: "raw", 60: "delta", 63: "packed"}[kind]
            if encoding == "delta":
                require(snapshot["delta_request"] is not None, "snapshot_delta_request")
            require(snapshot["body_encoding"] is None or snapshot["body_encoding"] == encoding, "snapshot_data_encoding")
            snapshot["body_encoding"] = encoding
            encoded_limit = MAXIMUM_PACKED_TEXT_BYTES if encoding == "packed" else MAXIMUM_TEXT_SNAPSHOT_BYTES
            require(len(snapshot["encoded_body"]) + len(payload) <= encoded_limit, "snapshot_text_limit")
            snapshot["encoded_body"].extend(payload)
            decoded = {"bytes": len(payload)}
        elif kind == 52:
            require(snapshot is not None, "snapshot_graphics_without_begin")
            require(snapshot["graphics"] is None, "snapshot_graphics_duplicate")
            decoded = decode_snapshot_graphics(payload, snapshot["begin"])
            snapshot["graphics"] = decoded
        elif kind == 61:
            require(snapshot is not None and snapshot["graphics"] is not None, "properties_order")
            require(snapshot["properties"] is None, "properties_duplicate")
            decoded = decode_properties(payload)
            snapshot["properties"] = decoded
        elif kind == 35:
            require(snapshot is not None, "snapshot_end_without_begin")
            decoded = decode_snapshot_end(payload)
            snapshots.append(finish_snapshot(snapshot, decoded))
            if snapshot["delta_request"] is not None:
                pending_delta_request = None
            snapshot = None
        elif kind == 54:
            require(snapshot is None and image_resource is None, "image_begin_nested")
            decoded = decode_image_begin(payload)
            image_resource = {"begin": decoded, "bytes": 0}
        elif kind == 55:
            require(image_resource is not None, "image_data_without_begin")
            require(0 < len(payload) <= GRAPHICS_DATA_CHUNK_BYTES, "image_data_size")
            require(image_resource["bytes"] + len(payload) <= image_resource["begin"]["byte_count"], "image_data_bytes")
            image_resource["bytes"] += len(payload)
            decoded = {"bytes": len(payload)}
        elif kind == 56:
            require(image_resource is not None, "image_end_without_begin")
            decoded = decode_image_end(payload)
            begin = image_resource["begin"]
            require(decoded["image_id"] == begin["image_id"] and decoded["generation"] == begin["generation"], "image_end_identity")
            require(image_resource["bytes"] == begin["byte_count"], "image_data_bytes")
            image_resources.append({"begin": begin, "bytes": image_resource["bytes"], "end": decoded})
            image_resource = None
        else:
            require(snapshot is None and image_resource is None, "snapshot_interleaved")
            decoded = decode_fixed_payload(kind, payload)
            if kind == 59:
                pending_delta_request = decoded
        frames.append({"kind": name, "payload": decoded})

    require(snapshot is None, "snapshot_unterminated")
    require(image_resource is None, "image_unterminated")
    return {"frames": frames, "snapshots": snapshots, "image_resources": image_resources}


def assert_subset(expected, actual, path: str = "value") -> None:
    if isinstance(expected, dict):
        require(isinstance(actual, dict), f"expect_type:{path}")
        for key, value in expected.items():
            require(key in actual, f"expect_missing:{path}.{key}")
            assert_subset(value, actual[key], f"{path}.{key}")
        return
    if isinstance(expected, list):
        require(isinstance(actual, list), f"expect_type:{path}")
        require(len(expected) == len(actual), f"expect_length:{path}")
        for index, (left, right) in enumerate(zip(expected, actual)):
            assert_subset(left, right, f"{path}[{index}]")
        return
    require(expected == actual, f"expect_value:{path}")


def validate_case(case: dict) -> None:
    require(isinstance(case.get("id"), str) and case["id"], "case_id")
    try:
        data = bytes.fromhex(case["hex"])
    except (KeyError, TypeError, ValueError):
        reject("case_hex")

    expected_error = case.get("error")
    if expected_error is not None:
        try:
            decode_stream(data)
        except WireError as error:
            require(error.code == expected_error, f"wrong_error:{case['id']}:{error.code}")
            return
        reject(f"expected_error:{case['id']}")

    decoded = decode_stream(data)
    require("expect" in case, f"case_expect:{case['id']}")
    assert_subset(case["expect"], decoded, case["id"])


def validate_document(document: dict) -> int:
    require(document.get("schema") == "howl.server.wire.v2/vectors", "document_schema")
    cases = document.get("cases")
    require(isinstance(cases, list) and cases, "document_cases")
    seen = set()
    for case in cases:
        require(case.get("id") not in seen, "case_duplicate")
        seen.add(case.get("id"))
        validate_case(case)
    return len(cases)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: validate_vectors.py protocol/vectors.json", file=sys.stderr)
        return 2
    path = Path(argv[1])
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
        count = validate_document(document)
    except (OSError, json.JSONDecodeError, WireError) as error:
        code = error.code if isinstance(error, WireError) else str(error)
        print(f"wire vectors: FAIL: {code}", file=sys.stderr)
        return 1
    print(f"wire vectors: PASS ({count} cases)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
