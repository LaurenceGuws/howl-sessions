export class TerminalSelectionViewport {
  constructor({historyOffset, historyCount, historyRowBase, rows, columns, alternateScreen, selectionRows = []}) {
    Object.assign(this, {historyOffset, historyCount, historyRowBase, rows, columns, alternateScreen, selectionRows});
  }

  selectionRow(viewportRow) {
    if (viewportRow < 0 || viewportRow >= this.selectionRows.length) return null;
    const packed = this.selectionRows[viewportRow];
    if (!Number.isInteger(packed) || packed < 0 || packed > 0xffff) return null;
    return {contentEndExclusive:packed & 0x7fff, wrapped:(packed & 0x8000) !== 0};
  }

  pointAt(viewportRow, column) {
    if (![this.historyOffset, this.historyCount, this.historyRowBase, this.rows, this.columns].every(Number.isInteger) ||
        viewportRow < 0 || viewportRow >= this.rows || column < 0 || column >= this.columns ||
        this.historyOffset < 0 || this.historyOffset > this.historyCount) return null;
    const row = this.alternateScreen
      ? viewportRow
      : this.historyRowBase + this.historyCount - this.historyOffset + viewportRow;
    return row < -0x80000000 || row > 0x7fffffff ? null : {row, column};
  }

  validity(range) {
    if (!range || range.columns !== this.columns || range.alternateScreen !== this.alternateScreen)
      return 'context_changed';
    const first = this.alternateScreen ? 0 : this.historyRowBase;
    const last = this.alternateScreen ? this.rows - 1 : this.historyRowBase + this.historyCount + this.rows - 1;
    const retained = point => point.column >= 0 && point.column < this.columns && point.row >= first && point.row <= last;
    return retained(range.anchor) && retained(range.focus) ? 'valid' : 'evicted';
  }
}

export class TerminalSelectionRange {
  constructor({anchor, focus, columns, alternateScreen}) {
    this.anchor = anchor; this.focus = focus; this.columns = columns; this.alternateScreen = alternateScreen;
  }

  get ordered() {
    return beforeOrEqual(this.anchor, this.focus)
      ? {start:this.anchor, end:this.focus}
      : {start:this.focus, end:this.anchor};
  }

  spanFor(viewport, viewportRow) {
    if (viewport.validity(this) !== 'valid') return null;
    const rowPoint = viewport.pointAt(viewportRow, 0);
    if (!rowPoint) return null;
    const {start, end} = this.ordered;
    if (rowPoint.row < start.row || rowPoint.row > end.row) return null;
    const startColumn = rowPoint.row === start.row ? start.column : 0;
    const endColumn = rowPoint.row === end.row ? end.column : this.columns - 1;
    const shape = viewport.selectionRow(viewportRow);
    if (!shape) return {row:viewportRow, startColumn, endColumn};
    const contentEnd = Math.max(0, Math.min(this.columns, shape.contentEndExclusive));
    const finalRow = rowPoint.row === end.row;
    if (finalRow || shape.wrapped) {
      if (contentEnd === 0) return null;
      const visualEnd = Math.min(endColumn, contentEnd - 1);
      return visualEnd < startColumn ? null : {row:viewportRow, startColumn, endColumn:visualEnd};
    }
    const newlineColumn = Math.min(contentEnd, this.columns - 1);
    const visualStart = startColumn < contentEnd ? startColumn : newlineColumn;
    return {row:viewportRow, startColumn:visualStart, endColumn:newlineColumn};
  }
}

function beforeOrEqual(left, right) {
  return left.row < right.row || left.row === right.row && left.column <= right.column;
}

export class DesktopSelectionController {
  constructor() { this.clear(); }
  get range() { return this._range; }
  get pointer() { return this._pointer; }
  get active() { return this._pointer != null; }

  start({pointer, point, columns, alternateScreen}) {
    this._pointer = pointer;
    this._anchor = point;
    this._moved = false;
    return this._range = new TerminalSelectionRange({anchor:point, focus:point, columns, alternateScreen});
  }

  update(pointer, point) {
    if (this._pointer !== pointer || !this._anchor || !this._range) return null;
    if (samePoint(this._range.focus, point)) return this._range;
    this._moved ||= !samePoint(this._anchor, point);
    return this._range = new TerminalSelectionRange({
      anchor:this._anchor,
      focus:point,
      columns:this._range.columns,
      alternateScreen:this._range.alternateScreen,
    });
  }

  finish(pointer) {
    if (this._pointer !== pointer) return {range:this._range, keep:this._range != null};
    const result = {range:this._range, keep:this._moved};
    this._pointer = null;
    this._anchor = null;
    this._moved = false;
    if (!result.keep) this._range = null;
    return result;
  }

  clear() {
    this._pointer = null;
    this._anchor = null;
    this._range = null;
    this._moved = false;
  }
}

export class TerminalSelectionOverlay {
  constructor({element, terminal}) { this.element = element; this.terminal = terminal; }
  clear() { this.element.replaceChildren(); }
  render(range, viewport) {
    this.clear();
    if (!range || !viewport || viewport.validity(range) !== 'valid') return;
    const rect = this.terminal.getBoundingClientRect();
    const left = rect.left + this.terminal.clientLeft;
    const top = rect.top + this.terminal.clientTop;
    const cellWidth = this.terminal.clientWidth / viewport.columns;
    const rowHeight = this.terminal.clientHeight / viewport.rows;
    const dpr = globalThis.devicePixelRatio ?? 1;
    const fragment = document.createDocumentFragment();
    for (let row = 0; row < viewport.rows; row += 1) {
      const span = range.spanFor(viewport, row);
      if (!span) continue;
      const rect = snappedSelectionRect({
        left, top, cellWidth, rowHeight, row,
        startColumn:span.startColumn, endColumn:span.endColumn, dpr,
      });
      const node = document.createElement('div');
      node.className = 'selection-span';
      node.style.left = `${rect.left}px`;
      node.style.top = `${rect.top}px`;
      node.style.width = `${rect.width}px`;
      node.style.height = `${rect.height}px`;
      fragment.append(node);
    }
    this.element.append(fragment);
  }
}

export function snappedSelectionRect({left, top, cellWidth, rowHeight, row, startColumn, endColumn, dpr = 1}) {
  const scale = Number.isFinite(dpr) && dpr > 0 ? dpr : 1;
  const snap = value => Math.round(value * scale) / scale;
  const x0 = snap(left + startColumn * cellWidth);
  const x1 = snap(left + (endColumn + 1) * cellWidth);
  const y0 = snap(top + row * rowHeight);
  const y1 = snap(top + (row + 1) * rowHeight);
  return {left:x0, top:y0, width:Math.max(0, x1 - x0), height:Math.max(0, y1 - y0)};
}

function samePoint(left, right) { return left.row === right.row && left.column === right.column; }

export function routeDesktopPrimaryPointer({historyActive, forceSelection, mouseTrackingEnabled}) {
  if (historyActive || forceSelection) return 'local_selection';
  if (mouseTrackingEnabled == null) return 'interaction_state';
  return mouseTrackingEnabled ? 'terminal_mouse' : 'local_selection';
}

export function routeDesktopWheel({historyActive, mouseTrackingEnabled, alternateScreen, alternateScroll}) {
  if (historyActive) return 'history';
  if (mouseTrackingEnabled == null || alternateScroll == null) return 'interaction_state';
  if (mouseTrackingEnabled) return 'terminal_mouse';
  if (!alternateScreen) return 'history';
  return alternateScroll ? 'alternate_scroll' : 'ignore';
}
