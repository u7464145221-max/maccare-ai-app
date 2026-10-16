#!/bin/bash
# Wyciąga klucze lokalizacji z kodu aplikacji kompilatorem Swift (-emit-localized-strings – działa z samymi Command Line Tools, bez Xcode/genstrings).
# Wynik: Sources/MacCareApp/Localization/keys.txt (posortowane klucze z formatami %lld/%@) – źródło prawdy dla testu kompletności tłumaczeń.
# Dołącza keys-dynamic.txt: etykiety z `rawValue` (protokół LocalizedRawTitle), których kompilator nie widzi jako literałów.
# Użycie: Scripts/l10n_extract.sh   (pełna kompilacja w osobnym katalogu .build-l10n – kilka minut CPU; uruchamiaj po zmianach tekstów)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
# Błąd kompilacji NIE może przejść po cichu (wtedy keys.txt zostałby stary, a test kompletności – fałszywie zielony): pokazujemy błędy i kończymy kodem ≠ 0.
if ! swift build --scratch-path .build-l10n --target MacCareApp -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" > "$OUT/build.log" 2>&1; then
  grep -E "error:" "$OUT/build.log" | sort -u | head -20 >&2; echo "STOP: kompilacja do ekstrakcji kluczy nie powiodła się – keys.txt bez zmian" >&2; exit 1
fi
python3 - "$OUT" Sources/MacCareApp/Localization/keys.txt Sources/MacCareApp/Localization/keys-dynamic.txt <<'PY'
import json, sys, pathlib
keys = set()
for f in pathlib.Path(sys.argv[1]).rglob("*.stringsdata"):
    for entry in json.loads(f.read_text()).get("tables", {}).get("Localizable", []):
        keys.add(entry["key"])
keys |= {k for k in pathlib.Path(sys.argv[3]).read_text(encoding="utf-8").split("\n") if k}
bad = sorted(k for k in keys if "\n" in k)
if bad: sys.exit("klucze z nową linią (keys.txt ma jeden klucz w wierszu – przenieś \\n poza String(localized:)): " + repr(bad[:5]))
keys.discard("")
pathlib.Path(sys.argv[2]).write_text("\n".join(sorted(keys)) + "\n", encoding="utf-8")
print(f"kluczy: {len(keys)} → {sys.argv[2]}")
PY
rm -rf "$OUT"
