// Seabird custom JS for Homepage.
// Opens the Upstream WiFi scan/connect page (/wifiapi/) in a modal iframe so
// the crew stays on the dashboard instead of navigating away.
(function () {
  "use strict";

  var WIFI_PATH = "/wifiapi/";
  var aisLibrary;

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
  var waterObserver = new MutationObserver(formatWaterTemperature);
  waterObserver.observe(document.body, { childList: true, characterData: true, subtree: true });
  refreshAisTargets();
  setInterval(refreshAisTargets, 10000);
})();
