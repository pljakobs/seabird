const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../config/homepage/custom.js"), "utf8");

function slice(from, to) {
  const start = source.indexOf(from);
  const end = source.indexOf(to);
  assert.ok(start !== -1 && end > start, `could not slice ${from}`);
  return source.slice(start, end);
}

const now = Date.parse("2026-10-11T08:00:00Z");
const historySource = slice("  function appendHistory(", "  function drawLineChart(");
const waterSource = slice("  function waterReadingState(", "  async function refreshWater(");
const windSource = slice("  function windGaugeState(", "  function loadWindLibrary(");

function context(extra = {}) {
  const sandbox = {
    Date: class extends Date {
      static now() { return now; }
    },
    Math,
    Number,
    window: { devicePixelRatio: 1 },
    ...extra
  };
  vm.createContext(sandbox);
  vm.runInContext(historySource + waterSource + windSource, sandbox);
  return sandbox;
}

test("rolling history drops samples older than the window but keeps the window full", () => {
  const { appendHistory } = context();
  const list = [];
  appendHistory(list, { time: now - 700000, value: 1 }, 600000);
  appendHistory(list, { time: now - 300000, value: 2 }, 600000);
  appendHistory(list, { time: now, value: 3 }, 600000);
  assert.deepEqual(Array.from(list, (point) => point.value), [2, 3]);
});

test("rolling history rejects non-finite samples instead of plotting them as zero", () => {
  const { appendHistory } = context();
  const list = [];
  for (const value of [null, undefined, NaN, "4"]) {
    appendHistory(list, { time: now, value }, 600000);
  }
  assert.equal(list.length, 0);
  appendHistory(list, { time: now, value: 0 }, 600000);
  assert.equal(list.length, 1);
  assert.equal(list[0].value, 0, "zero is a real reading and must be kept");
  assert.equal(list[0].time, now);
});

test("rolling history never empties itself completely while a sample exists", () => {
  const { appendHistory } = context();
  const list = [];
  appendHistory(list, { time: now - 5000000, value: 7 }, 600000);
  assert.equal(list.length, 1, "last known value is retained so the tile is not blank");
});

test("chart range keeps a flat trace flat rather than amplifying noise", () => {
  const { chartRange } = context();
  const range = chartRange([12.0, 12.0, 12.0], { minSpan: 2 });
  assert.ok(range.max - range.min >= 2, "flat data is given a minimum span");
  assert.ok(range.min < 12 && range.max > 12, "the flat value sits inside the range");
});

test("chart range clamps depth to the seabed and anchors current around zero", () => {
  const { chartRange } = context();
  const depth = chartRange([0.4, 1.2], { clampMin: 0, minSpan: 2 });
  assert.ok(depth.min >= -0.001, `depth must not go below zero, got ${depth.min}`);
  const current = chartRange([8, 12], { floor: 0, ceiling: 0, minSpan: 5 });
  assert.ok(current.min <= 0 && current.max >= 12, "charge current range always includes zero");
});

test("water readings convert kelvin to celsius and flag stale sensors", () => {
  const { waterReadingState } = context();
  const fresh = new Date(now - 1000).toISOString();
  const state = waterReadingState({
    environment: {
      depth: { belowTransducer: { value: 3.4, timestamp: fresh } },
      water: { temperature: { value: 288.15, timestamp: fresh } }
    }
  }, now);
  assert.equal(state.depth.value, 3.4);
  assert.equal(state.depth.stale, false);
  assert.ok(Math.abs(state.temperature.value - 15) < 1e-9, "288.15 K is 15 C");
  assert.equal(state.temperature.stale, false);

  const old = waterReadingState({
    environment: {
      depth: { belowTransducer: { value: 3.4, timestamp: new Date(now - 120001).toISOString() } },
      water: {}
    }
  }, now);
  assert.equal(old.depth.stale, true);
  assert.equal(old.temperature.value, null, "a missing sensor is null, never zero");
  assert.equal(old.temperature.stale, true);
});

test("water readings survive a vessel document with no environment branch", () => {
  const { waterReadingState } = context();
  const state = waterReadingState({}, now);
  assert.equal(state.depth.value, null);
  assert.equal(state.temperature.value, null);
});

test("wind angle is signed so port plots left of centre and starboard right", () => {
  const { windGaugeState } = context();
  const stamp = new Date(now - 1000).toISOString();
  function at(radians) {
    return windGaugeState({
      speedApparent: { value: 5, timestamp: stamp },
      angleApparent: { value: radians, timestamp: stamp }
    }, now).signedAngle;
  }
  assert.ok(at(Math.PI / 2) > 0, "90 deg is starboard");
  assert.ok(at(-Math.PI / 2) < 0, "minus 90 deg is port");
  assert.ok(Math.abs(at(Math.PI / 2) - 90) < 1e-9);
  assert.ok(Math.abs(at(3 * Math.PI / 2) + 90) < 1e-9, "270 deg wraps to port 90");
  assert.ok(Math.abs(at(-Math.PI / 2) + 90) < 1e-9);
  for (const angle of [at(Math.PI / 2), at(-Math.PI / 2), at(3 * Math.PI / 2)]) {
    assert.ok(angle >= -180 && angle <= 180, "signed angle stays within the plot axis");
  }
});

test("stale wind is not appended to the rolling trace", () => {
  const { windGaugeState, appendHistory } = context();
  const stale = windGaugeState({
    speedApparent: { value: 5, timestamp: new Date(now - 60001).toISOString() },
    angleApparent: { value: 1, timestamp: new Date(now - 60001).toISOString() }
  }, now);
  assert.equal(stale.stale, true);
  const list = [];
  if (stale.signedAngle !== null && !stale.stale) {
    appendHistory(list, { time: now, value: stale.signedAngle }, 600000);
  }
  assert.equal(list.length, 0, "stale samples must not pollute the 10 minute trace");
});
