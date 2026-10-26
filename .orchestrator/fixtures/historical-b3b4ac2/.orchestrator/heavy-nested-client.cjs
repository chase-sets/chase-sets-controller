"use strict";

// Worker-thread transport for one nested heavy-admission exchange (issue #7941).
//
// heavy-slot.cjs blocks its main thread in Atomics.wait while this worker opens
// exactly one fresh named-pipe connection to the wrapper-owned nested owner,
// writes the single request line, reads the single reply line, and publishes
// the raw reply bytes through the shared buffer. The worker carries no
// authority: it never reuses or accepts an inherited connection, never parses
// or trusts the reply, and the main thread verifies the signed reply itself.

const net = require("node:net");
const { workerData } = require("node:worker_threads");

const STATUS_REPLY = 1;
const STATUS_ERROR = 2;
const HEADER_BYTES = 8;

const { shared, pipeName, requestLine, maxReplyBytes, deadlineMs } = workerData;
const status = new Int32Array(shared, 0, 2);
const output = new Uint8Array(shared, HEADER_BYTES);
let published = false;

function publish(code, bytes) {
  if (published) return;
  published = true;
  const length = Math.min(bytes.length, output.length);
  output.set(bytes.subarray(0, length));
  Atomics.store(status, 1, length);
  Atomics.store(status, 0, code);
  Atomics.notify(status, 0);
}

function fail(message) {
  publish(STATUS_ERROR, Buffer.from(String(message), "utf8"));
}

const chunks = [];
let received = 0;
const socket = net.connect({ path: pipeName });
socket.setTimeout(deadlineMs);
socket.on("connect", () => {
  socket.write(requestLine);
});
socket.on("data", (chunk) => {
  chunks.push(chunk);
  received += chunk.length;
  if (received > maxReplyBytes) {
    fail("nested continuation reply exceeded 16 KiB");
    socket.destroy();
    return;
  }
  const newline = chunk.indexOf(0x0a);
  if (newline >= 0) {
    const reply = Buffer.concat(chunks);
    const end = reply.length - (chunk.length - newline) + 1;
    if (end !== reply.length) {
      fail("nested continuation carried bytes after its reply");
      socket.destroy();
      return;
    }
    publish(STATUS_REPLY, reply.subarray(0, end));
    socket.end();
    socket.destroy();
  }
});
socket.on("timeout", () => {
  fail("nested continuation exchange timed out");
  socket.destroy();
});
socket.on("error", (error) => {
  fail(`nested continuation transport failed (${error.code ?? error.message})`);
});
socket.on("close", () => {
  fail("nested continuation ended before its reply");
});
