// Browser-side serializer for Howl control mutations. It preserves exact
// operation order while coalescing only adjacent committed text that is still
// waiting behind an in-flight request. No terminal semantics live here.
export class ControlQueue {
  constructor({maximumPending = 256, maximumTextBytes = 4096, onError = () => {}, onEvent = () => {}} = {}) {
    this.maximumPending = maximumPending;
    this.maximumTextBytes = maximumTextBytes;
    this.onError = onError;
    this.onEvent = onEvent;
    this.tail = Promise.resolve();
    this.pending = 0;
    this.textTail = null;
    this.sequence = 0;
  }

  operation(run, kind = 'operation') {
    this.textTail = null;
    return this.#schedule(run, kind);
  }

  text(value, byteLength, run) {
    if (!value || byteLength <= 0 || byteLength > this.maximumTextBytes) {
      return this.#rejected(new Error('invalid committed-text queue item'));
    }
    const tail = this.textTail;
    if (tail && tail.bytes + byteLength <= this.maximumTextBytes) {
      tail.value += value;
      tail.bytes += byteLength;
      this.onEvent('text_coalesced', {pending:this.pending, bytes:tail.bytes});
      return tail.promise;
    }
    const item = {value, bytes:byteLength, promise:null};
    this.textTail = item;
    item.promise = this.#schedule(async () => {
      if (this.textTail === item) this.textTail = null;
      this.onEvent('text_start', {pending:this.pending, bytes:item.bytes});
      await run(item.value);
    }, 'text');
    return item.promise;
  }

  #schedule(run, kind) {
    if (this.pending >= this.maximumPending) {
      return this.#rejected(new Error(`control queue exceeds ${this.maximumPending} pending operations`));
    }
    const id = ++this.sequence;
    this.pending += 1;
    this.onEvent('queued', {id, kind, pending:this.pending});
    const task = this.tail.then(async () => {
      this.onEvent('start', {id, kind, pending:this.pending});
      return await run();
    });
    const settled = task.finally(() => {
      this.pending -= 1;
      this.onEvent('settled', {id, kind, pending:this.pending});
    });
    this.tail = settled.catch(error => { this.onError(error); });
    return settled;
  }

  #rejected(error) {
    this.onEvent('rejected', {pending:this.pending});
    this.onError(error);
    const rejected = Promise.reject(error);
    rejected.catch(() => {});
    return rejected;
  }
}
