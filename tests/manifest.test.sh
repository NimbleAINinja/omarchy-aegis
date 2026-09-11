#!/usr/bin/env bash
set -euo pipefail
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

jq -e '
  .schemaVersion == 1
  and .id == "io.github.nimbleaininja.aegis"
  and .name == "Aegis"
  and (.kinds | index("bar-widget"))
  and .entryPoints.barWidget == "Panel.qml"
  and .barWidget.category == "Network"
  and .barWidget.defaultSection == "right"
  and .barWidget.allowMultiple == false
  and .barWidget.defaults.barMode == "icon"
  and .barWidget.defaults.refreshIntervalSec == 30
  and ([.barWidget.schema[] | .key] == ["barMode", "refreshIntervalSec", "autoConnect", "killSwitch", "killOnDisconnect", "killApps", "locateHome", "pingDots"])
  and .barWidget.defaults.autoConnect == true
  and .barWidget.defaults.killSwitch == false
  and .barWidget.defaults.killOnDisconnect == false
  and .barWidget.defaults.killApps == ""
  and .barWidget.defaults.locateHome == true
  and .barWidget.defaults.pingDots == true
  and (.barWidget.schema[0].options == ["icon", "iso", "rate"])
' "$dir/manifest.json" >/dev/null

for f in Panel.qml Service.qml WorldMap.qml SettingsView.qml KillSwitchView.qml Grid.js Link.js Model.js agvpn.py LICENSE README.md \
         assets/land-grid.json assets/NOTICE.md assets/locations.json; do
  [[ -f "$dir/$f" ]] || { echo "$f missing" >&2; exit 1; }
done
python3 -m py_compile "$dir/agvpn.py"

# locations.json: 81 rows, numeric coordinates, unique iso|city keys
jq -e '
  length == 81
  and all(.[]; (.iso | test("^[A-Z]{2}$")) and (.country | length > 0) and (.city | length > 0)
    and (.lat | type == "number") and (.lon | type == "number") and (.virtual | type == "boolean")
    and .lat >= -90 and .lat <= 90 and .lon >= -180 and .lon <= 180)
  and (([.[] | .iso + "|" + .city] | unique | length) == 81)
' "$dir/assets/locations.json" >/dev/null

# land grid decodes to the same shape omachron ships
jq -e '.cols == 360 and .rows == 180 and (.rle | length) == 180' "$dir/assets/land-grid.json" >/dev/null

if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  omarchy-plugin-validate "$dir" >/dev/null
  echo "manifest: ok (omarchy plugin validate passed)"
else
  echo "manifest: ok (omarchy not on PATH, validate skipped)"
fi
