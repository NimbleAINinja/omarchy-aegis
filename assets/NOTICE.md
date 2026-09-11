# Map data

`land-grid.json` is a 1° land/water raster (360 columns × 180 rows, sampled at
cell centres, run-length encoded per row) derived from Natural Earth's 1:110m
Admin 0 Countries dataset, with Antarctica left out. Natural Earth data is in
the public domain. Source: https://www.naturalearthdata.com/

The raster and `Grid.js` are taken unchanged from the Omachron World Clock
plugin (https://github.com/NimbleAINinja/omarchy-omachron, MIT), which builds it with
`tools/build-land-grid.mjs`; no vector data is shipped with this plugin.

`locations.json` lists the AdGuard VPN exit cities with hand-entered
approximate coordinates (city centres, ±0.1°). Virtual locations are marked;
their coordinates are the advertised city, not the physical server.
