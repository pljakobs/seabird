<?php
/**
 * Seabird-specific Nextcloud overrides.
 * Loaded after the main config.php (zz- prefix = last alphabetically).
 * Values here win over config.php for scalar keys; arrays replace the
 * earlier-defined array entirely.
 *
 * overwritewebroot is required so Nextcloud generates URLs with the
 * /nextcloud prefix when served via the Caddy sub-path proxy.
 */
$CONFIG = [
    'overwritewebroot' => '/nextcloud',

    // Accept requests from any host Seabird is reachable at:
    //   seabird.local  — mDNS on the crew LAN
    //   100.64.0.1     — Tailscale/headscale IP (works over the internet)
    //   localhost / 127.0.0.1 — local / health checks
    'trusted_domains' => [
        'seabird.local',
        'localhost',
        '127.0.0.1',
        '100.64.0.1',
    ],
];
