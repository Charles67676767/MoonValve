// Generated demonstration data, independent of any local Steam installation.
export function cacheSample(count = 230) {
  const parts = [], encode = text => new TextEncoder().encode(text), u32 = n => {const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n, true); return b;};
  parts.push(u32(0x07564427), u32(1));
  for (let i = 0; i < count; i++) {
    const name = encode(`Synthetic Game ${i + 1}`), payload = new Uint8Array([0, ...encode('appinfo'), 0, 1, ...encode('name'), 0, ...name, 0, 8, 8]);
    const record = new Uint8Array(40 + payload.length), view = new DataView(record.buffer); view.setUint32(0, 1, true); view.setUint32(4, 1234567890, true); view.setUint32(36, i + 1, true); record.set(payload, 40);
    parts.push(u32(480 + i), u32(record.length), record);
  }
  parts.push(u32(0));
  const result = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let offset = 0; for (const part of parts) {result.set(part, offset); offset += part.length;} return result;
}
