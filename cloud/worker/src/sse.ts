/**
 * Minimal Server-Sent Events plumbing: split a byte stream into events (keeping
 * each event's raw text so untouched events pass through byte for byte) and run
 * a per-event rewrite.
 */

const MAX_BUFFERED_BYTES = 4 * 1024 * 1024;

/** Splits text into raw SSE events. Line ends are \n, \r\n or \r; a blank line ends an event. */
export class SseEventSplitter {
  private buf = "";

  push(text: string, final = false): string[] {
    this.buf += text;
    if (this.buf.length > MAX_BUFFERED_BYTES) throw new Error("SSE event too large");
    const events: string[] = [];
    const buf = this.buf;
    const len = buf.length;
    let start = 0;
    let pos = 0;
    while (pos < len) {
      let i = pos;
      while (i < len && buf[i] !== "\n" && buf[i] !== "\r") i++;
      if (i === len) break; // incomplete line
      let next = i + 1;
      if (buf[i] === "\r") {
        if (next === len && !final) break; // might be the first half of \r\n
        if (buf[next] === "\n") next++;
      }
      if (i === pos) {
        events.push(buf.slice(start, next)); // blank line: event complete
        start = next;
      }
      pos = next;
    }
    this.buf = buf.slice(start);
    if (final && this.buf.length > 0) {
      events.push(this.buf);
      this.buf = "";
    }
    return events;
  }
}

/** The `data` payload of a raw event, or null when it has no data lines. */
export function parseEvent(raw: string): { lines: string[]; dataIndexes: number[]; data: string } | null {
  const lines = raw.split(/\r\n|\n|\r/).filter((l) => l !== "");
  const dataIndexes: number[] = [];
  const parts: string[] = [];
  lines.forEach((line, idx) => {
    if (line === "data" || line.startsWith("data:")) {
      dataIndexes.push(idx);
      let value = line.slice(5);
      if (value.startsWith(" ")) value = value.slice(1);
      parts.push(value);
    }
  });
  if (dataIndexes.length === 0) return null;
  return { lines, dataIndexes, data: parts.join("\n") };
}

/** Rebuild an event with its data lines replaced by one line carrying `json`. */
export function rebuildEvent(parsed: { lines: string[]; dataIndexes: number[] }, json: string): string {
  const first = parsed.dataIndexes[0];
  const drop = new Set(parsed.dataIndexes);
  const out: string[] = [];
  parsed.lines.forEach((line, idx) => {
    if (idx === first) out.push(`data: ${json}`);
    else if (!drop.has(idx)) out.push(line);
  });
  return out.join("\n") + "\n\n";
}

/**
 * Stream transform that hands each complete event to `rewrite`. `rewrite`
 * returns the text to emit (the raw event when unchanged) or "" to drop it.
 */
export function sseTransform(rewrite: (rawEvent: string) => string): TransformStream<Uint8Array, Uint8Array> {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  const splitter = new SseEventSplitter();
  const emit = (events: string[], controller: TransformStreamDefaultController<Uint8Array>) => {
    for (const ev of events) {
      const out = rewrite(ev);
      if (out) controller.enqueue(encoder.encode(out));
    }
  };
  return new TransformStream<Uint8Array, Uint8Array>({
    transform(chunk, controller) {
      emit(splitter.push(decoder.decode(chunk, { stream: true })), controller);
    },
    flush(controller) {
      emit(splitter.push(decoder.decode(), true), controller);
    },
  });
}
