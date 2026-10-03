# AvNav Weather Implementation

Keep weather downloads, replace raster MBTiles generation with bounded vector
data, and support offline weather-assisted passage planning in AvNav.

- [x] Inspect the legacy installer and weather generation path.
- [x] Implement bounded GRIB downloads and a compact forecast cache (no tiles).
- [x] Implement shared forecast-time selection, point forecasts and GeoJSON.
- [x] Implement route sampling by departure time and estimated speed.
- [x] Add AvNav weather widget, overlay controls and passage table.
- [x] Update installer, service and timer wiring; disable the raster generator.
- [x] Test sampling, unavailable data, time handling and route calculations.
- [x] Deploy on `root@seabird.local`; verify live wind/wave downloads and API.
- [x] Synchronize live Caddy routes with the repo; validate chart and weather endpoints.
- [x] Fit the forecast controller to its content and isolate map input; test desktop/mobile controls and deploy.
- [ ] Verify the widget and vector overlay visually in AvNav and the passage UI.
- [ ] Resolve DMI current-data availability and verify a live current forecast.

## Deployment Status

- Services must run on seabird.local, not the development machine.
- Local environments are for isolated tests only; no local service installation.
- Dependencies are installed on seabird; its clock and DWD DNS are working.
- Weather API and six-hour fetch timer are active; the first wind/wave fetch succeeded.
- Caddy's `/chart/*` route serves AvNav charts; `/wxapi/*` serves the new forecast API.
    Both routes are now persisted in the repo and validated on the live host.
- Current forecasts are unavailable: the first fetch failed to resolve the DMI hostname.

## Constraints

- Retain one complete downloaded forecast; replace it atomically on success.
- Show model run, forecast validity, download age and missing fields explicitly.
- Never substitute observed wind for forecast wind or extrapolate past coverage.
- Initial route ETAs use a fixed speed over ground, not automatic weather routing.
- Do not alter navigation charts, FNC updates or unrelated host configuration.
- Wind, waves and currents may have different model runs and coverage.