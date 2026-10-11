// Seabird custom JS for Homepage.
// Opens the Upstream WiFi scan/connect page (/wifiapi/) in a modal iframe so
// the crew stays on the dashboard instead of navigating away.
(function () {
  "use strict";

  var WIFI_PATH = "/wifiapi/";
  var aisLibrary;
  var BATTERY_CURRENT_LIMIT = 50;
  var HISTORY_MS = 600000;
  var WIND_HISTORY_MS = 600000;
  var windLibrary;
  var windInstrument;

  function networkSignalLevel(percentage) {
    if (!Number.isFinite(percentage) || percentage <= 0) return 0;
    return Math.min(4, Math.ceil(percentage / 25));
  }

  function renderNetworkSignals() {
    var tile = document.getElementById("seabird-network");
    if (!tile) return;
    tile.querySelectorAll(".seabird-signal-bars").forEach(function (indicator) {
      if (!indicator.parentElement.classList.contains("service-block")) indicator.remove();
    });
    tile.querySelectorAll(".service-block").forEach(function (block) {
      var value = block.firstElementChild;
      var label = block.lastElementChild.textContent.trim().toLowerCase();
      var status = value.textContent;
      var cellular = label === "cellular";
      var wifi = label === "upstream wifi";
      var indicator = block.querySelector(".seabird-signal-bars");
      if ((!cellular && !wifi) || (wifi && !status.includes("\ud83d\udfe2"))) {
        if (indicator) indicator.remove();
        return;
      }
      var match = status.match(/(?:^|\s)(\d{1,3})%$/);
      var percentage = match && Number(match[1]) <= 100 ? Number(match[1]) : null;
      var level = networkSignalLevel(percentage);
      if (!indicator) {
        indicator = document.createElement("span");
        indicator.className = "seabird-signal-bars";
        indicator.setAttribute("role", "img");
        for (var bar = 1; bar <= 4; bar++) {
          var segment = document.createElement("i");
          segment.style.height = (bar * 4) + "px";
          indicator.appendChild(segment);
        }
        value.after(indicator);
      }
      var description = percentage === null ? "Signal strength unavailable" : "Signal strength: " + percentage + "%";
      indicator.setAttribute("aria-label", description);
      indicator.title = description;
      indicator.dataset.level = String(level);
      Array.from(indicator.children).forEach(function (segment, index) {
        segment.classList.toggle("active", index < level);
      });
    });
  }

  function windGaugeState(data, now) {
    var speed = data.speedApparent;
    var angle = data.angleApparent;
    var validAngle = angle && Number.isFinite(angle.value);
    var degrees = validAngle ? ((angle.value * 180 / Math.PI) % 360 + 360) % 360 : null;
    var signedAngle = degrees === null ? null : degrees > 180 ? degrees - 360 : degrees;
    var times = [Date.parse(speed && speed.timestamp), Date.parse(angle && angle.timestamp)];
    return { speed: speed && Number.isFinite(speed.value) && speed.value >= 0 ? speed.value * 1.9438444924 : null,
      angle: degrees, signedAngle: signedAngle, noGo: signedAngle !== null && Math.abs(signedAngle) <= 35,
      stale: times.some(function (time) { return !Number.isFinite(time) || now - time > 60000; }) };
  }

  function loadWindLibrary() {
    if (!windLibrary) {
      windLibrary = new Promise(function (resolve, reject) {
        var script = document.createElement("script");
        script.src = "/homepage-bg/canvas-gauges.min.js";
        script.onload = function () { resolve(window.RadialGauge); };
        script.onerror = function () {
          windLibrary = null;
          script.remove();
          reject(new Error("Wind instrument unavailable"));
        };
        document.head.appendChild(script);
      });
    }
    return windLibrary;
  }

  async function refreshWind() {
    var tile = document.getElementById("seabird-wind");
    if (!tile) return;
    var panel = tile.querySelector(".seabird-wind-panel");
    if (!panel) {
      panel = document.createElement("div");
      panel.className = "seabird-wind-panel";
      panel.innerHTML = '<div class="seabird-wind-dial"><canvas role="img" aria-label="Apparent wind angle"></canvas>' +
        '<div class="seabird-wind-readout"><strong>--</strong><span>kn apparent</span></div></div>' +
        '<div class="seabird-wind-angle">--</div><div class="seabird-wind-status">Loading</div>';
      tile.appendChild(panel);
    }
    try {
      var results = await Promise.all([loadWindLibrary(), fetch("/signalk/v1/api/vessels/self/environment/wind", {
        signal: AbortSignal.timeout(4000)
      }).then(function (response) {
        if (!response.ok) throw new Error("Wind data unavailable");
        return response.json();
      })]);
      var canvas = panel.querySelector("canvas");
      if (!windInstrument || windInstrument.options.renderTo !== canvas) {
        if (windInstrument) windInstrument.destroy();
        windInstrument = new results[0]({ renderTo: canvas, width: 300, height: 300,
          minValue: 0, maxValue: 360, startAngle: 180, ticksAngle: 360,
          majorTicks: ["0", "30", "60", "90", "120", "150", "180", "150", "120", "90", "60", "30", "0"],
          minorTicks: 3, strokeTicks: true, numbersMargin: 7, borders: false, borderShadowWidth: 0,
          colorPlate: "#181c20", colorMajorTicks: "#e5e7eb", colorMinorTicks: "#9ca3af", colorNumbers: "#e5e7eb",
          colorNeedle: "#f8fafc", colorNeedleEnd: "#f8fafc", needleType: "arrow", needleWidth: 3,
          needleStart: 40, needleEnd: 90, needleCircleSize: 0, valueBox: false,
          highlights: [{from: 0, to: 35, color: "#64748b"}, {from: 35, to: 180, color: "#22c55e"},
            {from: 180, to: 325, color: "#ef4444"}, {from: 325, to: 360, color: "#64748b"}],
          animation: false, fontNumbersSize: 17 }).draw();
      }
      var state = windGaugeState(results[1], Date.now());
      if (state.signedAngle !== null && !state.stale) {
        appendHistory(rollingHistory.wind, { time: Date.now(), value: state.signedAngle }, WIND_HISTORY_MS);
      }
      var windHistory = ensureChartCanvas(panel, "seabird-wind-history");
      drawWindAngleHistory(windHistory, rollingHistory.wind);
      panel.classList.toggle("seabird-wind-stale", state.stale || state.angle === null);
      canvas.style.visibility = state.angle === null ? "hidden" : "visible";
      if (state.angle !== null) windInstrument.update({ value: state.angle });
      panel.querySelector(".seabird-wind-readout strong").textContent = state.speed === null ? "--" : state.speed.toFixed(1);
      var direction = state.signedAngle === null ? "Angle unavailable" :
        (state.signedAngle < 0 ? "Port " : state.signedAngle > 0 ? "Starboard " : "Ahead ") +
        Math.round(Math.abs(state.signedAngle)) + "\u00b0";
      panel.querySelector(".seabird-wind-angle").textContent = direction;
      panel.querySelector(".seabird-wind-status").textContent = state.stale ? "Stale data" :
        state.speed === null ? "Speed unavailable" : state.noGo ? "No-go sector (\u00b135\u00b0)" : "No-go: \u00b135\u00b0";
      canvas.setAttribute("aria-label", "Apparent wind " + direction + (state.noGo ? ", no-go sector" : ""));
    } catch (error) {
      panel.classList.add("seabird-wind-stale");
      panel.querySelector(".seabird-wind-status").textContent = error.message;
    }
  }

  var rollingHistory = {
    waterDepth: [],
    waterTemperature: [],
    batterySoc: [],
    batteryCurrent: [],
    wind: []
  };

  function appendHistory(list, sample, maxAgeMs) {
    if (!sample || !Number.isFinite(sample.value)) return list;
    var timestamp = Number.isFinite(sample.time) ? sample.time : Date.now();
    list.push({ time: timestamp, value: sample.value });
    var cutoff = Date.now() - maxAgeMs;
    while (list.length > 1 && list[0].time < cutoff) {
      list.shift();
    }
    return list;
  }

  function ensureChartCanvas(container, className) {
    var canvas = container.querySelector("canvas." + className);
    if (!canvas) {
      canvas = document.createElement("canvas");
      canvas.className = className;
      container.appendChild(canvas);
    }
    return canvas;
  }

  // Auto-ranges to the data, but never collapses below `minSpan` so a flat
  // trace stays a flat line instead of exploding into noise. Clamps are applied
  // after padding so a padded axis cannot run past a physical limit (such as
  // negative depth).
  function chartRange(values, options) {
    var min = Math.min.apply(Math, values);
    var max = Math.max.apply(Math, values);
    if (Number.isFinite(options.floor)) min = Math.min(min, options.floor);
    if (Number.isFinite(options.ceiling)) max = Math.max(max, options.ceiling);
    var span = Number.isFinite(options.minSpan) ? options.minSpan : 1;
    if (max - min < span) {
      var middle = (max + min) / 2;
      min = middle - span / 2;
      max = middle + span / 2;
    }
    var pad = (max - min) * 0.08;
    min -= pad;
    max += pad;
    if (Number.isFinite(options.clampMin)) min = Math.max(min, options.clampMin);
    if (Number.isFinite(options.clampMax)) max = Math.min(max, options.clampMax);
    return { min: min, max: max };
  }

  function drawLineChart(canvas, points, options) {
    if (!canvas) return;
    var context = canvas.getContext("2d");
    var ratio = window.devicePixelRatio || 1;
    var width = canvas.clientWidth;
    var height = canvas.clientHeight;
    if (!width || !height) return;
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    context.clearRect(0, 0, width, height);
    context.font = "9px sans-serif";

    // An empty trace is labelled rather than left as a blank box, so a sensor
    // that is not publishing is distinguishable from a chart that failed.
    var now = Date.now();
    var start = now - (options.windowMs || HISTORY_MS);
    var visible = (points || []).filter(function (point) { return point.time >= start; });
    if (visible.length < 2) {
      context.fillStyle = "rgba(148, 163, 184, 0.75)";
      context.textAlign = "center";
      context.textBaseline = "middle";
      context.fillText((options.label ? options.label + " \u2014 " : "") +
        (visible.length ? "collecting\u2026" : "no data"), width / 2, height / 2);
      return;
    }

    var range = chartRange(visible.map(function (point) { return point.value; }), options);
    var min = range.min;
    var span = range.max - range.min || 1;
    var padLeft = 34;
    var padRight = 6;
    var padTop = 6;
    var padBottom = 12;
    var plotWidth = width - padLeft - padRight;
    var plotHeight = height - padTop - padBottom;

    function plotX(time) {
      return padLeft + Math.max(0, Math.min(1, (time - start) / (now - start))) * plotWidth;
    }
    function plotY(value) {
      return padTop + (1 - Math.max(0, Math.min(1, (value - min) / span))) * plotHeight;
    }

    context.strokeStyle = "rgba(148, 163, 184, 0.25)";
    context.fillStyle = "rgba(148, 163, 184, 0.9)";
    context.lineWidth = 1;
    context.font = "9px sans-serif";
    context.textAlign = "right";
    context.textBaseline = "middle";
    for (var row = 0; row <= 2; row++) {
      var value = min + (span / 2) * row;
      var y = Math.round(plotY(value)) + 0.5;
      context.beginPath();
      context.moveTo(padLeft, y);
      context.lineTo(width - padRight, y);
      context.stroke();
      context.fillText(value.toFixed(options.precision || 0) + (options.unit || ""), padLeft - 4, y);
    }

    context.beginPath();
    visible.forEach(function (point, index) {
      var x = plotX(point.time);
      var y = plotY(point.value);
      if (index === 0) context.moveTo(x, y); else context.lineTo(x, y);
    });
    // Close down to the baseline for the fill, then re-stroke only the trace so
    // the baseline edges are not outlined.
    context.save();
    context.lineTo(plotX(visible[visible.length - 1].time), padTop + plotHeight);
    context.lineTo(plotX(visible[0].time), padTop + plotHeight);
    context.closePath();
    context.fillStyle = options.fillColor || "rgba(56, 189, 248, 0.12)";
    context.fill();
    context.restore();

    context.beginPath();
    visible.forEach(function (point, index) {
      var x = plotX(point.time);
      var y = plotY(point.value);
      if (index === 0) context.moveTo(x, y); else context.lineTo(x, y);
    });
    context.strokeStyle = options.lineColor || "#38bdf8";
    context.lineWidth = 1.75;
    context.lineJoin = "round";
    context.stroke();

    if (options.label) {
      context.fillStyle = "rgba(226, 232, 240, 0.85)";
      context.textAlign = "left";
      context.textBaseline = "top";
      context.fillText(options.label, padLeft + 4, padTop + 1);
    }
  }

  // Apparent wind angle against time, scrolling top (now) to bottom (-10 min).
  // X axis is signed angle: port to the left of centre, starboard to the right,
  // both labelled 0-180 degrees in magnitude.
  function drawWindAngleHistory(canvas, points) {
    if (!canvas) return;
    var context = canvas.getContext("2d");
    var ratio = window.devicePixelRatio || 1;
    var width = canvas.clientWidth;
    var height = canvas.clientHeight;
    if (!width || !height) return;
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    context.clearRect(0, 0, width, height);

    var padX = 8;
    var padTop = 13;
    var padBottom = 13;
    var plotWidth = width - padX * 2;
    var plotHeight = height - padTop - padBottom;
    var now = Date.now();
    var start = now - WIND_HISTORY_MS;

    function plotX(angle) {
      return padX + ((Math.max(-180, Math.min(180, angle)) + 180) / 360) * plotWidth;
    }
    function plotY(time) {
      return padTop + Math.max(0, Math.min(1, (now - time) / WIND_HISTORY_MS)) * plotHeight;
    }

    context.fillStyle = "rgba(15, 23, 42, 0.85)";
    context.fillRect(0, 0, width, height);

    // No-go sector either side of head-to-wind, matching the dial highlight.
    context.fillStyle = "rgba(100, 116, 139, 0.28)";
    context.fillRect(plotX(-35), padTop, plotX(35) - plotX(-35), plotHeight);

    context.font = "9px sans-serif";
    context.textBaseline = "middle";
    for (var tick = -180; tick <= 180; tick += 45) {
      var x = Math.round(plotX(tick)) + 0.5;
      context.beginPath();
      context.moveTo(x, padTop);
      context.lineTo(x, padTop + plotHeight);
      context.strokeStyle = tick === 0 ? "rgba(226, 232, 240, 0.55)" : "rgba(148, 163, 184, 0.22)";
      context.lineWidth = 1;
      context.stroke();
      context.fillStyle = "rgba(148, 163, 184, 0.9)";
      context.textAlign = tick === -180 ? "left" : tick === 180 ? "right" : "center";
      context.fillText(String(Math.abs(tick)), x, height - padBottom / 2);
    }

    context.fillStyle = "rgba(226, 232, 240, 0.85)";
    context.textAlign = "left";
    context.fillText("\u25c0 Port", padX, padTop / 2);
    context.textAlign = "right";
    context.fillText("Starboard \u25b6", width - padX, padTop / 2);
    context.textAlign = "center";
    context.fillText("now", width / 2, padTop / 2);
    context.fillStyle = "rgba(148, 163, 184, 0.9)";
    context.fillText("\u221210 min", width / 2, height - padBottom / 2);

    var visible = points.filter(function (point) { return point.time >= start; });
    if (visible.length < 2) {
      context.fillStyle = "rgba(148, 163, 184, 0.75)";
      context.textAlign = "center";
      context.textBaseline = "middle";
      context.fillText(visible.length ? "collecting\u2026" : "no wind data", width / 2, height / 2);
      return;
    }

    // Break the trace where the wind crosses dead astern so it does not draw a
    // false horizontal sweep across the whole plot.
    context.strokeStyle = "#fbbf24";
    context.lineWidth = 1.75;
    context.lineJoin = "round";
    context.beginPath();
    var pen = false;
    for (var index = 0; index < visible.length; index++) {
      var point = visible[index];
      var previous = visible[index - 1];
      if (pen && previous && Math.abs(point.value - previous.value) > 180) {
        context.stroke();
        context.beginPath();
        pen = false;
      }
      var px = plotX(point.value);
      var py = plotY(point.time);
      if (!pen) {
        context.moveTo(px, py);
        pen = true;
      } else {
        context.lineTo(px, py);
      }
    }
    context.stroke();

    // Mark the newest sample so the current angle is obvious at a glance.
    var latest = visible[visible.length - 1];
    context.beginPath();
    context.arc(plotX(latest.value), plotY(latest.time), 2.5, 0, Math.PI * 2);
    context.fillStyle = "#fbbf24";
    context.fill();
  }

  function batteryGaugeState(data, now) {
    function reading(field) {
      var valid = field && Number.isFinite(field.value);
      var time = Date.parse(field && field.timestamp);
      return { value: valid ? field.value : null,
        stale: !Number.isFinite(time) || now - time > 600000,
        timestamp: field && field.timestamp };
    }
    var soc = reading(data.capacity && data.capacity.stateOfCharge);
    if (soc.value !== null && (soc.value < 0 || soc.value > 1)) soc.value = null;
    var current = reading(data.current);
    return { soc: soc, current: current, voltage: reading(data.voltage),
      angle: current.value === null ? 0 : Math.max(-1, Math.min(1, current.value / BATTERY_CURRENT_LIMIT)) * 80 };
  }

  async function refreshBattery() {
    var tile = document.getElementById("seabird-battery");
    if (!tile) return;
    var panel = tile.querySelector(".seabird-battery-panel");
    if (!panel) {
      panel = document.createElement("div");
      panel.className = "seabird-battery-panel";
      panel.innerHTML = '<div class="seabird-battery-instruments">' +
        '<div class="seabird-soc"><div class="seabird-battery-body" role="meter" aria-label="State of charge" aria-valuemin="0" aria-valuemax="100">' +
        '<div class="seabird-battery-fill"></div></div><strong class="seabird-soc-value">--</strong><span>State of Charge</span></div>' +
        '<div class="seabird-current"><svg viewBox="0 0 240 135" role="img" aria-label="Battery current">' +
        '<path d="M 25 110 A 95 95 0 0 1 120 15" class="seabird-discharge-arc"/>' +
        '<path d="M 120 15 A 95 95 0 0 1 215 110" class="seabird-charge-arc"/>' +
        '<path d="M 25 110 H 35 M 120 15 V 25 M 205 110 H 215" class="seabird-gauge-ticks"/>' +
        '<text x="27" y="130" text-anchor="middle">-50</text><text x="120" y="43" text-anchor="middle">0</text>' +
        '<text x="213" y="130" text-anchor="middle">+50</text>' +
        '<g class="seabird-current-needle"><path d="M 117 110 L 120 32 L 123 110 Z"/><circle cx="120" cy="110" r="6"/></g></svg>' +
        '<strong class="seabird-current-value">--</strong><div class="seabird-current-labels"><span>Discharge</span><span>Charge</span></div></div></div>' +
        '<div class="seabird-battery-summary"><span class="seabird-battery-voltage">-- V</span><span class="seabird-battery-state">Loading</span></div>';
      tile.appendChild(panel);
    }
    try {
      var response = await fetch("/signalk/v1/api/vessels/self/electrical/batteries/hausbatterie", {
        signal: AbortSignal.timeout(8000)
      });
      if (!response.ok) throw new Error("Battery data unavailable");
      var state = batteryGaugeState(await response.json(), Date.now());
      if (state.soc.value !== null && !state.soc.stale) {
        appendHistory(rollingHistory.batterySoc, { time: Date.now(), value: state.soc.value * 100 }, HISTORY_MS);
      }
      if (state.current.value !== null && !state.current.stale) {
        appendHistory(rollingHistory.batteryCurrent, { time: Date.now(), value: state.current.value }, HISTORY_MS);
      }
      var batteryHistory = panel.querySelector(".seabird-battery-history");
      if (!batteryHistory) {
        batteryHistory = document.createElement("div");
        batteryHistory.className = "seabird-battery-history";
        panel.appendChild(batteryHistory);
      }
      drawLineChart(ensureChartCanvas(batteryHistory, "seabird-battery-soc-chart"), rollingHistory.batterySoc, {
        label: "SoC %", unit: "", precision: 0, lineColor: "#22c55e",
        fillColor: "rgba(34, 197, 94, 0.14)", clampMin: 0, clampMax: 100, minSpan: 10
      });
      drawLineChart(ensureChartCanvas(batteryHistory, "seabird-battery-current-chart"), rollingHistory.batteryCurrent, {
        label: "Current A", unit: "", precision: 1, lineColor: "#f59e0b",
        fillColor: "rgba(245, 158, 11, 0.14)", floor: 0, ceiling: 0, minSpan: 5
      });
      var soc = panel.querySelector(".seabird-soc");
      var meter = panel.querySelector("[role=meter]");
      var percentage = state.soc.value === null ? null : Math.round(state.soc.value * 100);
      soc.classList.toggle("seabird-reading-stale", state.soc.stale || percentage === null);
      panel.querySelector(".seabird-battery-fill").style.width = (percentage || 0) + "%";
      panel.querySelector(".seabird-battery-fill").style.backgroundColor = percentage <= 20 ? "#ef4444" : percentage <= 50 ? "#eab308" : "#22c55e";
      panel.querySelector(".seabird-soc-value").textContent = percentage === null ? "--" : percentage + "%";
      meter.setAttribute("aria-valuetext", percentage === null ? "Unavailable" : percentage + "%" + (state.soc.stale ? ", stale" : ""));
      if (percentage === null) meter.removeAttribute("aria-valuenow");
      else meter.setAttribute("aria-valuenow", String(percentage));
      var current = panel.querySelector(".seabird-current");
      current.classList.toggle("seabird-reading-stale", state.current.stale || state.current.value === null);
      panel.querySelector(".seabird-current-needle").style.transform = "rotate(" + state.angle + "deg)";
      panel.querySelector(".seabird-current-needle").style.visibility = state.current.value === null ? "hidden" : "visible";
      var currentText = state.current.value === null ? "--" : (state.current.value > 0 ? "+" : "") + state.current.value.toFixed(1) + " A";
      panel.querySelector(".seabird-current-value").textContent = currentText;
      panel.querySelector("svg").setAttribute("aria-label", "Battery current " + currentText + (state.current.stale ? ", stale" : ""));
      panel.querySelector(".seabird-battery-voltage").textContent = state.voltage.value === null ? "-- V" : state.voltage.value.toFixed(2) + " V" + (state.voltage.stale ? " (stale)" : "");
      var status = state.current.value === null ? "Unavailable" : state.current.value > 0 ? "Charging" : state.current.value < 0 ? "Discharging" : "Idle";
      if (state.current.value !== null && Math.abs(state.current.value) > BATTERY_CURRENT_LIMIT) status += " (beyond scale)";
      if (state.current.stale || state.soc.stale) status += " / Stale data";
      panel.querySelector(".seabird-battery-state").textContent = status;
      panel.title = "SOC: " + (state.soc.timestamp || "unknown") + "; current: " + (state.current.timestamp || "unknown");
    } catch (error) {
      panel.querySelectorAll(".seabird-soc, .seabird-current").forEach(function (gauge) {
        gauge.classList.add("seabird-reading-stale");
      });
      panel.querySelector(".seabird-battery-state").textContent = error.message;
    }
  }

  function solarGaugeState(data, now) {
    var names = ["panelPower", "panelVoltage", "panelCurrent", "voltage", "current", "power",
      "yieldToday", "chargingMode", "faults", "problem"];
    var result = {};
    names.forEach(function (name) {
      var field = data[name];
      var time = Date.parse(field && field.timestamp);
      var value = field && field.value;
      var valid = name === "chargingMode" || name === "faults" ? typeof value === "string" :
        name === "problem" ? typeof value === "boolean" : Number.isFinite(value) && value >= 0;
      result[name] = { value: valid ? value : null,
        stale: !valid || !Number.isFinite(time) || now - time > 120000 };
    });
    return result;
  }

  async function refreshSolar() {
    var tile = document.getElementById("seabird-solar");
    if (!tile) return;
    var panel = tile.querySelector(".seabird-solar-panel");
    if (!panel) {
      panel = document.createElement("div");
      panel.className = "seabird-solar-panel";
      panel.setAttribute("aria-label", "Epever solar controller");
      panel.innerHTML = '<strong class="seabird-solar-power">-- W</strong>' +
        '<div>Solar input</div><div class="seabird-solar-pv">-- V / -- A</div>' +
        '<div class="seabird-solar-charge">Charge: --</div><div class="seabird-solar-yield">Today: --</div>' +
        '<div class="seabird-solar-status" role="status">Loading</div>';
      tile.appendChild(panel);
    }
    try {
      var response = await fetch("/signalk/v1/api/vessels/self/electrical/solar/epever", {
        signal: AbortSignal.timeout(8000)
      });
      if (!response.ok) throw new Error("Solar data unavailable");
      var state = solarGaugeState(await response.json(), Date.now());
      function display(name, precision, suffix, divisor) {
        var reading = state[name];
        return reading.value === null ? "--" + suffix :
          (reading.value / (divisor || 1)).toFixed(precision) + suffix + (reading.stale ? " (stale)" : "");
      }
      var stale = Object.keys(state).some(function (name) { return state[name].stale; });
      panel.classList.toggle("seabird-solar-stale", stale);
      panel.classList.toggle("seabird-solar-fault", !state.problem.stale && state.problem.value === true);
      panel.querySelector(".seabird-solar-power").textContent = display("panelPower", 1, " W");
      panel.querySelector(".seabird-solar-pv").textContent = display("panelVoltage", 2, " V") + " / " + display("panelCurrent", 2, " A");
      panel.querySelector(".seabird-solar-charge").textContent = "Charge: " + display("current", 2, " A") +
        " / " + display("power", 1, " W") + " / " + display("voltage", 2, " V");
      panel.querySelector(".seabird-solar-yield").textContent = "Today: " + display("yieldToday", 2, " kWh", 3600000);
      panel.querySelector(".seabird-solar-status").textContent =
        (stale ? "Stale / incomplete data" : state.chargingMode.value === "unknown" ? "Not charging" : state.chargingMode.value) +
        (state.problem.value === true ? " / " + (state.faults.value || "Controller fault") : "");
    } catch (error) {
      panel.classList.add("seabird-solar-stale");
      panel.classList.remove("seabird-solar-fault");
      panel.querySelector(".seabird-solar-status").textContent = error.message;
    }
  }

  function loadAisLibrary() {
    if (!aisLibrary) {
      aisLibrary = new Promise(function (resolve, reject) {
        var script = document.createElement("script");
        script.src = "/homepage-bg/geographiclib-geodesic.min.js";
        script.onload = function () { resolve(window.geodesic.Geodesic.WGS84); };
        script.onerror = function () {
          aisLibrary = null;
          script.remove();
          reject(new Error("Distance library unavailable"));
        };
        document.head.appendChild(script);
      });
    }
    return aisLibrary;
  }

  function validAisPosition(position) {
    return position && Number.isFinite(position.latitude) && Number.isFinite(position.longitude) &&
      Math.abs(position.latitude) <= 90 && Math.abs(position.longitude) <= 180;
  }

  function nearestAisTargets(vessels, self, geodesic) {
    var selfId = self.replace(/^vessels\./, "");
    var ownPosition = vessels[selfId] && vessels[selfId].navigation && vessels[selfId].navigation.position;
    if (!ownPosition || !validAisPosition(ownPosition.value)) {
      throw new Error("Own vessel position unavailable");
    }
    var targets = Object.entries(vessels).filter(function (entry) {
      return entry[0] !== selfId && (entry[1].mmsi || entry[0].includes(":mmsi:"));
    }).map(function (entry) {
      var vessel = entry[1];
      var position = vessel.navigation && vessel.navigation.position;
      if (!position || !validAisPosition(position.value)) return null;
      var distance = geodesic.Inverse(ownPosition.value.latitude, ownPosition.value.longitude,
        position.value.latitude, position.value.longitude).s12 / 1852;
      if (!Number.isFinite(distance)) return null;
      return { name: vessel.name || vessel.mmsi || entry[0].split(":").pop(), distance: distance,
        timestamp: position.timestamp, speed: vessel.navigation.speedOverGround,
        course: vessel.navigation.courseOverGroundTrue };
    }).filter(Boolean).sort(function (left, right) { return left.distance - right.distance; });
    return { targets: targets.slice(0, 15), timestamp: ownPosition.timestamp };
  }

  function staleAisPosition(timestamp) {
    var time = Date.parse(timestamp);
    return !Number.isFinite(time) || Date.now() - time > 300000;
  }

  function formatAisMotion(reading, type) {
    if (!reading || !Number.isFinite(reading.value) || reading.value < 0) return "--";
    var text;
    if (type === "speed") {
      text = (reading.value * 1.9438444924).toFixed(1) + " kn";
    } else {
      if (reading.value > 2 * Math.PI) return "--";
      text = String(Math.round(reading.value * 180 / Math.PI) % 360).padStart(3, "0") + "\u00b0";
    }
    return text + (staleAisPosition(reading.timestamp) ? " (stale)" : "");
  }

  async function refreshAisTargets() {
    var tile = document.getElementById("seabird-ais");
    if (!tile) return;
    var list = tile.querySelector(".seabird-ais-list");
    if (!list) {
      list = document.createElement("ul");
      list.className = "seabird-ais-list";
      list.setAttribute("aria-label", "Nearest AIS targets");
      tile.appendChild(list);
    }
    try {
      var results = await Promise.all([loadAisLibrary(),
        fetch("/signalk/v1/api/self", { signal: AbortSignal.timeout(8000) }).then(function (response) {
          if (!response.ok) throw new Error("Signal K unavailable");
          return response.json();
        }),
        fetch("/signalk/v1/api/vessels", { signal: AbortSignal.timeout(8000) }).then(function (response) {
          if (!response.ok) throw new Error("Signal K unavailable");
          return response.json();
        })]);
      var nearest = nearestAisTargets(results[2], results[1], results[0]);
      var rows = nearest.targets.map(function (target) {
        var row = document.createElement("li");
        row.className = "seabird-ais-target";
        var name = document.createElement("span");
        var distance = document.createElement("span");
        var speed = document.createElement("span");
        var course = document.createElement("span");
        name.textContent = target.name;
        distance.textContent = target.distance.toFixed(2) + " nm";
        speed.textContent = formatAisMotion(target.speed, "speed");
        course.textContent = formatAisMotion(target.course, "course");
        speed.title = "Speed over ground; reported " + (target.speed && target.speed.timestamp || "unknown");
        course.title = "True course over ground; reported " + (target.course && target.course.timestamp || "unknown");
        if (staleAisPosition(target.timestamp) || staleAisPosition(nearest.timestamp)) {
          distance.textContent += " (stale)";
        }
        row.title = "Target position: " + (target.timestamp || "unknown") +
          "; own position: " + (nearest.timestamp || "unknown");
        row.append(name, distance, speed, course);
        return row;
      });
      if (!rows.length) {
        var empty = document.createElement("li");
        empty.textContent = "No AIS targets with positions";
        rows.push(empty);
      } else {
        var header = document.createElement("li");
        header.className = "seabird-ais-header";
        ["Vessel", "Range", "SOG", "COG"].forEach(function (label) {
          var column = document.createElement("span");
          column.textContent = label;
          header.appendChild(column);
        });
        rows.unshift(header);
      }
      list.replaceChildren.apply(list, rows);
    } catch (error) {
      var message = document.createElement("li");
      message.textContent = error.message;
      list.replaceChildren(message);
    }
  }

  function waterReadingState(data, now) {
    var environment = data && data.environment ? data.environment : {};
    var depth = environment.depth && environment.depth.belowTransducer;
    var temperature = environment.water && environment.water.temperature;
    function reading(field, convert) {
      var valid = field && Number.isFinite(field.value);
      var time = Date.parse(field && field.timestamp);
      return {
        value: valid ? (convert ? convert(field.value) : field.value) : null,
        stale: !valid || !Number.isFinite(time) || now - time > 120000
      };
    }
    return {
      depth: reading(depth),
      temperature: reading(temperature, function (kelvin) { return kelvin - 273.15; })
    };
  }

  async function refreshWater() {
    var tile = document.getElementById("seabird-water");
    if (!tile) return;
    var panel = tile.querySelector(".seabird-water-panel");
    if (!panel) {
      panel = document.createElement("div");
      panel.className = "seabird-water-panel";
      panel.setAttribute("aria-label", "Water depth and temperature history");
      tile.appendChild(panel);
    }
    try {
      var response = await fetch("/signalk/v1/api/vessels/self", {
        signal: AbortSignal.timeout(8000)
      });
      if (!response.ok) throw new Error("Water data unavailable");
      var state = waterReadingState(await response.json(), Date.now());
      if (state.depth.value !== null && !state.depth.stale) {
        appendHistory(rollingHistory.waterDepth, { time: Date.now(), value: state.depth.value }, HISTORY_MS);
      }
      if (state.temperature.value !== null && !state.temperature.stale) {
        appendHistory(rollingHistory.waterTemperature, { time: Date.now(), value: state.temperature.value }, HISTORY_MS);
      }
      panel.classList.toggle("seabird-reading-stale", state.depth.stale && state.temperature.stale);
      drawLineChart(ensureChartCanvas(panel, "seabird-water-depth-chart"), rollingHistory.waterDepth, {
        label: "Depth m", unit: "", precision: 1, lineColor: "#38bdf8",
        fillColor: "rgba(56, 189, 248, 0.14)", clampMin: 0, minSpan: 2
      });
      drawLineChart(ensureChartCanvas(panel, "seabird-water-temp-chart"), rollingHistory.waterTemperature, {
        label: "Temp \u00b0C", unit: "", precision: 1, lineColor: "#f472b6",
        fillColor: "rgba(244, 114, 182, 0.14)", minSpan: 2
      });
    } catch (error) {
      panel.classList.add("seabird-reading-stale");
    }
  }

  function formatWaterTemperature() {
    var water = document.getElementById("seabird-water");
    if (!water) return;
    var walker = document.createTreeWalker(water, NodeFilter.SHOW_TEXT);
    var node;
    while ((node = walker.nextNode())) {
      var match = node.nodeValue.match(/^(-?\d+(?:\.\d+)?) K$/);
      if (match) {
        node.nodeValue = (Number(match[1]) - 273.15).toFixed(1) + " \u00b0C";
      } else if (node.nodeValue === "null K") {
        node.nodeValue = "Unavailable";
      }
    }
  }

  function isWifiLink(el) {
    var a = el.closest ? el.closest("a[href]") : null;
    if (!a) return null;
    var href = a.getAttribute("href") || "";
    var clean = href.split("?")[0].replace(/\/+$/, "");
    return clean.endsWith("/wifiapi") ? a : null;
  }

  function buildModal() {
    var overlay = document.getElementById("seabird-wifi-overlay");
    if (overlay) return overlay;

    overlay = document.createElement("div");
    overlay.id = "seabird-wifi-overlay";

    var modal = document.createElement("div");
    modal.id = "seabird-wifi-modal";

    var close = document.createElement("button");
    close.id = "seabird-wifi-close";
    close.setAttribute("aria-label", "Close");
    close.textContent = "\u00d7";

    var frame = document.createElement("iframe");
    frame.id = "seabird-wifi-frame";
    frame.title = "Connect to WiFi";

    modal.appendChild(close);
    modal.appendChild(frame);
    overlay.appendChild(modal);
    document.body.appendChild(overlay);

    function hide() {
      overlay.classList.remove("open");
      frame.src = "about:blank";
    }
    close.addEventListener("click", hide);
    overlay.addEventListener("click", function (e) {
      if (e.target === overlay) hide();
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") hide();
    });
    return overlay;
  }

  function openModal() {
    var overlay = buildModal();
    var frame = document.getElementById("seabird-wifi-frame");
    // Cache-bust so a reopened modal re-scans rather than showing a stale page.
    frame.src = WIFI_PATH + "?t=" + Date.now();
    overlay.classList.add("open");
  }

  // Capture phase so we intercept before Homepage's client-side router.
  document.addEventListener(
    "click",
    function (e) {
      var link = isWifiLink(e.target);
      if (!link) return;
      e.preventDefault();
      e.stopPropagation();
      openModal();
    },
    true
  );

  formatWaterTemperature();
  renderNetworkSignals();
  var waterObserver = new MutationObserver(formatWaterTemperature);
  waterObserver.observe(document.body, { childList: true, characterData: true, subtree: true });
  var networkObserver = new MutationObserver(renderNetworkSignals);
  networkObserver.observe(document.body, { childList: true, characterData: true, subtree: true });
  refreshAisTargets();
  setInterval(refreshAisTargets, 10000);
  refreshWater();
  setInterval(refreshWater, 10000);
  refreshBattery();
  setInterval(refreshBattery, 10000);
  refreshSolar();
  setInterval(refreshSolar, 10000);
  refreshWind();
  setInterval(refreshWind, 5000);
})();
