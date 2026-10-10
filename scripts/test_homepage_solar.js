const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../config/homepage/custom.js"), "utf8");
const solarSource = source.slice(source.indexOf("  function solarGaugeState("), source.indexOf("  function loadAisLibrary("));
const now = Date.parse("2026-10-10T14:00:00Z");

function sample(timestamp = now) {
  const values = {
    panelPower: 105, panelVoltage: 42, panelCurrent: 2.5, voltage: 13.2,
    current: 6.5, power: 85.8, yieldToday: 4428000, chargingMode: "bulk",
    faults: "None", problem: false
  };
  return Object.fromEntries(Object.entries(values).map(([key, value]) =>
    [key, { value, timestamp: new Date(timestamp).toISOString() }]));
}

function fixture(data, ok = true) {
  const elements = {};
  const classes = new Set();
  const panel = {
    classList: {
      toggle(name, enabled) { enabled ? classes.add(name) : classes.delete(name); },
      add(name) { classes.add(name); },
      remove(name) { classes.delete(name); }
    },
    querySelector(name) {
      return elements[name] || (elements[name] = { textContent: "" });
    }
  };
  const context = {
    Date: class extends Date { static now() { return now; } },
    AbortSignal,
    document: { getElementById() { return { querySelector() { return panel; } }; } },
    fetch: async (url) => {
      assert.equal(url, "/signalk/v1/api/vessels/self/electrical/solar/epever");
      return { ok, json: async () => data };
    }
  };
  vm.createContext(context);
  vm.runInContext(solarSource, context);
  return { context, elements, classes };
}

test("solar values remain SI and freshness threshold is exactly two minutes", () => {
  const { context } = fixture(sample());
  assert.equal(context.solarGaugeState(sample(now - 120000), now).panelPower.stale, false);
  assert.equal(context.solarGaugeState(sample(now - 120001), now).panelPower.stale, true);
  assert.equal(context.solarGaugeState(sample(), now).yieldToday.value, 4428000);
});

test("missing, invalid and negative readings are not shown as zero", () => {
  const { context } = fixture(sample());
  const data = sample();
  delete data.panelPower;
  data.panelCurrent.value = -1;
  data.voltage.value = "13.2";
  const state = context.solarGaugeState(data, now);
  for (const field of ["panelPower", "panelCurrent", "voltage"]) {
    assert.equal(state[field].value, null);
    assert.equal(state[field].stale, true);
  }
  data.panelPower = { value: 0, timestamp: new Date(now).toISOString() };
  assert.equal(context.solarGaugeState(data, now).panelPower.value, 0);
});

test("solar tile displays PV, charging output, and joules converted to kWh", async () => {
  const { context, elements, classes } = fixture(sample());
  await context.refreshSolar();
  assert.equal(elements[".seabird-solar-power"].textContent, "105.0 W");
  assert.equal(elements[".seabird-solar-yield"].textContent, "Today: 1.23 kWh");
  assert.equal(elements[".seabird-solar-charge"].textContent, "Charge: 6.50 A / 85.8 W / 13.20 V");
  assert.equal(elements[".seabird-solar-status"].textContent, "bulk");
  assert.equal(classes.has("seabird-solar-stale"), false);
});

test("stale values are explicitly labelled", async () => {
  const { context, elements, classes } = fixture(sample(now - 120001));
  await context.refreshSolar();
  assert.equal(classes.has("seabird-solar-stale"), true);
  assert.match(elements[".seabird-solar-power"].textContent, /\(stale\)/);
  assert.match(elements[".seabird-solar-status"].textContent, /Stale/);
});

test("controller faults are displayed as text, never HTML", async () => {
  const data = sample();
  data.problem.value = true;
  data.faults.value = "<b>PV input overvoltage</b>";
  const { context, elements, classes } = fixture(data);
  await context.refreshSolar();
  assert.equal(classes.has("seabird-solar-fault"), true);
  assert.match(elements[".seabird-solar-status"].textContent, /<b>PV input overvoltage<\/b>/);
});

test("HTTP failure marks the panel stale and reports unavailable data", async () => {
  const { context, elements, classes } = fixture({}, false);
  await context.refreshSolar();
  assert.equal(classes.has("seabird-solar-stale"), true);
  assert.equal(elements[".seabird-solar-status"].textContent, "Solar data unavailable");
});
