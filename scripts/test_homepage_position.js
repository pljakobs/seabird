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

const positionSource = slice("  function setUrlParam(", "  async function refreshPosition(");

const EMBED =
  "https://embed.windy.com/embed2.html?lat=56.500&lon=12.250&detailLat=56.500" +
  "&detailLon=12.250&zoom=7&overlay=wind&metricWind=kt";

// Minimal stand-in for the Homepage tile: an element wrapping the widget iframe.
function fakeDocument(initialSrc = EMBED) {
  const frame = {
    src: initialSrc,
    setCount: 0,
    getAttribute(name) {
      return name === "src" ? this.src : null;
    },
    setAttribute(name, value) {
      if (name !== "src") return;
      this.src = value;
      this.setCount += 1;
    }
  };
  const tile = { querySelector: (sel) => (sel === "iframe" ? frame : null) };
  return {
    frame,
    document: { getElementById: (id) => (id === "seabird-windy" ? tile : null) }
  };
}

function context(extra = {}) {
  const sandbox = { Math, Number, RegExp, ...extra };
  vm.createContext(sandbox);
  vm.runInContext("var windyPosition;" + positionSource, sandbox);
  return sandbox;
}

test("setUrlParam replaces lat without corrupting detailLat", () => {
  const { setUrlParam } = context();
  const out = setUrlParam(EMBED, "lat", "57.123");
  assert.ok(out.includes("?lat=57.123&"), "lat should be replaced");
  assert.ok(out.includes("detailLat=56.500"), "detailLat must not be touched by the lat pattern");
});

test("setUrlParam replaces lon without corrupting detailLon", () => {
  const { setUrlParam } = context();
  const out = setUrlParam(EMBED, "lon", "11.000");
  assert.ok(out.includes("&lon=11.000&"), "lon should be replaced");
  assert.ok(out.includes("detailLon=12.250"), "detailLon must not be touched by the lon pattern");
});

test("setUrlParam leaves a url without the key unchanged", () => {
  const { setUrlParam } = context();
  assert.equal(setUrlParam("https://example.com/?a=1", "lat", "5"), "https://example.com/?a=1");
});

test("vesselPosition reads a Signal K fix", () => {
  const { vesselPosition } = context();
  const pos = vesselPosition({ navigation: { position: { value: { latitude: 55.1, longitude: 12.9 } } } });
  assert.equal(pos.lat, 55.1);
  assert.equal(pos.lon, 12.9);
});

test("vesselPosition returns null when navigation is absent", () => {
  const { vesselPosition } = context();
  // This is the live state today: Signal K exposes only mmsi/name/design/electrical.
  assert.equal(vesselPosition({ mmsi: "1", electrical: {} }), null);
});

test("vesselPosition rejects a non-finite fix instead of centring the map on NaN", () => {
  const { vesselPosition } = context();
  assert.equal(vesselPosition({ navigation: { position: { value: { latitude: null, longitude: 12 } } } }), null);
});

test("updateWindyPosition recentres the embed on the vessel", () => {
  const dom = fakeDocument();
  const { updateWindyPosition } = context({ document: dom.document });
  updateWindyPosition({ lat: 57.25, lon: 10.5 });
  assert.ok(dom.frame.src.includes("?lat=57.250&"));
  assert.ok(dom.frame.src.includes("&detailLat=57.250&"));
  assert.ok(dom.frame.src.includes("&lon=10.500&"));
  assert.ok(dom.frame.src.includes("&detailLon=10.500&"));
});

test("updateWindyPosition ignores sub-kilometre drift so the iframe is not reloaded", () => {
  const dom = fakeDocument();
  const { updateWindyPosition } = context({ document: dom.document });
  updateWindyPosition({ lat: 57.25, lon: 10.5 });
  assert.equal(dom.frame.setCount, 1);
  updateWindyPosition({ lat: 57.2501, lon: 10.5001 });
  assert.equal(dom.frame.setCount, 1, "a tiny GPS jitter must not reload the map");
  updateWindyPosition({ lat: 57.5, lon: 10.5 });
  assert.equal(dom.frame.setCount, 2, "a real move must recentre the map");
});

test("updateWindyPosition is a no-op when the Windy tile is absent", () => {
  const { updateWindyPosition } = context({ document: { getElementById: () => null } });
  assert.doesNotThrow(() => updateWindyPosition({ lat: 1, lon: 2 }));
});
