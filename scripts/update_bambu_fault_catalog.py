"""Refresh the public Chinese HMS catalog used by Bambu Studio.

Run from any directory: python scripts/update_bambu_fault_catalog.py
No printer/account credentials are used. Empty official descriptions are kept
as internal codes, not replaced with invented troubleshooting instructions.
"""
import hashlib
import json
import pathlib
import urllib.request
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[1]
TARGET = ROOT / "电脑软件/assets/knowledge/printer_faults_zh_CN.json"
# The device prefixes bundled by the official HMS.cpp. Other prefixes are
# fetched by the app using the connected printer's first three SN characters.
PREFIXES = ["default", "094", "239", "093", "20P", "22E", "31B", "26A"]


def main():
    entries = {}
    sources = []
    for prefix in PREFIXES:
        url = "https://e.bambulab.com/query.php?lang=zh-cn&v=0"
        if prefix != "default":
            url += "&d=" + prefix
        request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0", "Accept": "application/json"})
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
        payload = json.loads(raw)
        if payload.get("result") != 0:
            raise ValueError(f"Official catalog rejected {prefix}")
        counts = {}
        for section, kind, length in [("device_hms", "hms", 16), ("device_error", "print_error", 8)]:
            rows = payload["data"][section]["zh-cn"]
            if len(rows) < 100:
                raise ValueError(f"Incomplete catalog: {prefix}/{section}")
            counts[section] = len(rows)
            for row in rows:
                code = row["ecode"].upper()
                if len(code) != length or any(c not in "0123456789ABCDEF" for c in code):
                    raise ValueError(f"Invalid official code: {code}")
                message = row["intro"]
                key = (kind, code, message)
                entry = entries.setdefault(key, {
                    "code": code, "kind": kind, "summary": message,
                    "deviceTypes": [], "source": "bambu-official",
                })
                entry["deviceTypes"].append(prefix)
        sources.append({"deviceType": prefix, "url": url,
                        "version": str(payload["ver"]), "counts": counts,
                        "sha256": hashlib.sha256(raw).hexdigest()})
    output = {"schemaVersion": "2.0.0", "language": "zh-cn",
              "retrievedAt": datetime.now(timezone.utc).isoformat(),
              "sourceVersion": max(s["version"] for s in sources),
              "protocolReference": "https://github.com/bambulab/BambuStudio/blob/master/src/slic3r/GUI/DeviceCore/DevHMS.cpp",
              "sources": sources,
              "faults": sorted(entries.values(), key=lambda e: (e["kind"], e["code"], e["deviceTypes"]))}
    TARGET.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"file": str(TARGET), "entries": len(entries), "sources": sources}, ensure_ascii=False))


if __name__ == "__main__":
    main()
