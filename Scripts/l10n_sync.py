#!/usr/bin/env python3
"""Synchronizuje en.lproj/Localizable.strings z kluczami z kodu (Sources/MacCareApp/Localization/keys.txt, patrz Scripts/l10n_extract.sh).
Zachowuje istniejące tłumaczenia, dopisuje nowe z opcjonalnego pliku JSON {"klucz PL": "tłumaczenie EN"}, usuwa nieużywane i raportuje braki.
Użycie: python3 Scripts/l10n_sync.py [nowe_tlumaczenia.json]      Kod wyjścia 1, gdy brakuje tłumaczeń albo formaty (%@, %lld, %%) się nie zgadzają."""
import json, re, sys
from pathlib import Path
root = Path(__file__).resolve().parent.parent
loc = root / "Sources/MacCareApp/Localization"
strings = loc / "en.lproj/Localizable.strings"
pair = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')
def unesc(s): return s.replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')
def esc(s): return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
existing = {}
for line in strings.read_text(encoding="utf-8").splitlines() if strings.exists() else []:
    m = pair.match(line)
    if m: existing[unesc(m.group(1))] = unesc(m.group(2))
if len(sys.argv) > 1: existing.update(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")))
keys = [k for k in (loc / "keys.txt").read_text(encoding="utf-8").split("\n") if k]
spec = re.compile(r'%(?:lld|ld|d|@|lf|f|%)')
missing = [k for k in keys if k not in existing]
badfmt = [k for k in keys if k in existing and spec.findall(k) != spec.findall(existing[k])]
unused = sorted(set(existing) - set(keys))
out = ["/* MacCare AI – angielski. Klucze = polski tekst źródłowy (wyciągnięty kompilatorem: Scripts/l10n_extract.sh; synchronizacja: Scripts/l10n_sync.py). */"]
out += [f'"{esc(k)}" = "{esc(existing[k])}";' for k in keys if k in existing]
strings.write_text("\n".join(out) + "\n", encoding="utf-8")
print(f"kluczy: {len(keys)} · przetłumaczone: {len(keys) - len(missing)} · brak: {len(missing)} · niezgodne formaty: {len(badfmt)} · usunięte nieużywane: {len(unused)}")
for k in missing: print("BRAK:", k)
for k in badfmt: print("FORMAT:", k)
sys.exit(1 if missing or badfmt else 0)
