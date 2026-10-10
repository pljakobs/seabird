// Seabird custom JS for Homepage.
// Opens the Upstream WiFi scan/connect page (/wifiapi/) in a modal iframe so
// the crew stays on the dashboard instead of navigating away.
(function () {
  "use strict";

  var WIFI_PATH = "/wifiapi/";
  var aisLibrary;
  var BATTERY_CURRENT_LIMIT = 50;
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
  refreshBattery();
  setInterval(refreshBattery, 10000);
  refreshSolar();
  setInterval(refreshSolar, 10000);
  refreshWind();
  setInterval(refreshWind, 5000);
})();
