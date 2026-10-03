// Seabird custom JS for Homepage.
// Opens the Upstream WiFi scan/connect page (/wifiapi/) in a modal iframe so
// the crew stays on the dashboard instead of navigating away.
(function () {
  "use strict";

  var WIFI_PATH = "/wifiapi/";

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
})();
