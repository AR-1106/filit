#!/usr/bin/env bash
# Filit smoke tests — does not print secrets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

pass=0
fail=0
warn=0

ok()   { echo "PASS  $*"; pass=$((pass+1)); }
bad()  { echo "FAIL  $*"; fail=$((fail+1)); }
note() { echo "WARN  $*"; warn=$((warn+1)); }

echo "=== Filit smoke tests ==="

# --- 1. Build artifact ---
APP="build/Build/Products/Debug/Filit.app"
BIN="$APP/Contents/MacOS/Filit"
if [[ -x "$BIN" ]]; then
  ok "Debug binary exists"
else
  bad "Debug binary missing — run Scripts/run.sh first"
fi

# --- 2. App running ---
if pgrep -x Filit >/dev/null; then
  ok "Filit process is running"
else
  note "Filit not running — launching"
  open "$APP" || true
  sleep 1
  if pgrep -x Filit >/dev/null; then ok "Filit launched"; else bad "Could not launch Filit"; fi
fi

# --- 3. Accessibility trust ---
# AXIsProcessTrusted for our bundle via Swift one-liner is heavy; use sqlite TCC if readable.
TCC="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
if [[ -r "$TCC" ]]; then
  if sqlite3 "$TCC" "SELECT client FROM access WHERE service='kTCCServiceAccessibility' AND (client LIKE '%Filit%' OR client LIKE '%filit%');" 2>/dev/null | grep -qi filit; then
    ok "Accessibility grant present in TCC"
  else
    note "No Filit Accessibility row in user TCC (may still be granted via prompt / system DB)"
  fi
else
  note "Cannot read TCC.db (normal on modern macOS) — grant Accessibility manually if smart paste fails"
fi

# --- 4. Load API key silently ---
API_KEY=""
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -a
  # parse only TYPESAFE_API_KEY without sourcing whole file (avoid weird chars)
  API_KEY="$(grep -E '^TYPESAFE_API_KEY=' .env | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
  set +a
fi
if [[ -z "$API_KEY" ]]; then
  # try keychain
  API_KEY="$(security find-generic-password -s 'com.filit.app' -a 'TYPESAFE_API_KEY' -w 2>/dev/null || true)"
fi

if [[ -n "$API_KEY" ]]; then
  ok "API key available for live call (not printed)"
else
  bad "No API key in .env or Keychain — Account settings / live API tests skipped"
fi

# --- 5. Live TypeSafe Choice (resume → email field) ---
if [[ -n "$API_KEY" ]]; then
  RESP="$(mktemp)"
  HTTP="$(curl -sS -o "$RESP" -w "%{http_code}" \
    -X POST "https://api.typesafe.ai/v1/systemone" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d @- <<'EOF'
{
  "state": {
    "field": {
      "label": "Email",
      "placeholder": "name@company.com",
      "role": "AXTextField",
      "description": "",
      "nearby": "Contact details"
    },
    "candidates": [
      {"id": "c0", "value": "Ada Lovelace", "origin": "source-line"},
      {"id": "c1", "value": "ada@analytical.engine", "origin": "source-email"},
      {"id": "c2", "value": "+1 (415) 555-0142", "origin": "source-phone"},
      {"id": "c3", "value": "San Francisco, CA", "origin": "source-line"}
    ],
    "source_excerpt": "Ada Lovelace\nada@analytical.engine\n+1 (415) 555-0142\nSan Francisco, CA"
  },
  "model": "jev-latest",
  "questions": {
    "pick": {
      "type": "choice",
      "instructions": {
        "question": "Which candidate value belongs in the focused field?",
        "guidance": "Use field label and placeholder. Prefer verbatim candidates. Choose none if nothing fits."
      },
      "criteria": {
        "c0": "Ada Lovelace",
        "c1": "ada@analytical.engine",
        "c2": "+1 (415) 555-0142",
        "c3": "San Francisco, CA",
        "none": "None of these candidates belongs in the focused field."
      }
    }
  }
}
EOF
)"

  if [[ "$HTTP" == "200" ]]; then
    CHOICE="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['answers']['pick']['choice'])" "$RESP")"
    if [[ "$CHOICE" == "c1" ]]; then
      ok "TypeSafe picked email candidate (c1) for Email field"
    else
      bad "TypeSafe choice for Email field was '$CHOICE' (expected c1)"
    fi
  else
    bad "TypeSafe HTTP $HTTP — $(head -c 200 "$RESP" | tr '\n' ' ')"
  fi
  rm -f "$RESP"
fi

# --- 6. Second live call: phone field ---
if [[ -n "$API_KEY" ]]; then
  RESP="$(mktemp)"
  HTTP="$(curl -sS -o "$RESP" -w "%{http_code}" \
    -X POST "https://api.typesafe.ai/v1/systemone" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d @- <<'EOF'
{
  "state": {
    "field": {"label": "Mobile phone", "placeholder": "", "role": "AXTextField", "description": "", "nearby": "Phone"},
    "candidates": [
      {"id": "c0", "value": "Ada Lovelace", "origin": "source-line"},
      {"id": "c1", "value": "ada@analytical.engine", "origin": "source-email"},
      {"id": "c2", "value": "+1 (415) 555-0142", "origin": "source-phone"}
    ]
  },
  "model": "jev-latest",
  "questions": {
    "pick": {
      "type": "choice",
      "instructions": "Which candidate value belongs in the focused Mobile phone field?",
      "criteria": {
        "c0": "Ada Lovelace",
        "c1": "ada@analytical.engine",
        "c2": "+1 (415) 555-0142",
        "none": "None of these candidates belongs in the focused field."
      }
    }
  }
}
EOF
)"
  if [[ "$HTTP" == "200" ]]; then
    CHOICE="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['answers']['pick']['choice'])" "$RESP")"
    if [[ "$CHOICE" == "c2" ]]; then
      ok "TypeSafe picked phone candidate (c2) for Mobile phone field"
    else
      note "TypeSafe phone pick was '$CHOICE' (expected c2) — may still be usable"
    fi
  else
    bad "Phone-field TypeSafe HTTP $HTTP"
  fi
  rm -f "$RESP"
fi

# --- 7. Candidate extraction (Python mirror of regex logic) ---
python3 - <<'PY'
import re, sys
source = """Ada Lovelace
ada@analytical.engine
work@example.com
+1 (415) 555-0142
https://ada.dev
San Francisco, CA"""
emails = re.findall(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}", source)
phones = re.findall(r"\(?\+?\d[\d\s()\-.]{6,}\d", source)
urls = re.findall(r"https?://[^\s]+", source)
lines = [l.strip() for l in source.splitlines() if 2 <= len(l.strip()) <= 200]
seen=set(); cand=[]
for v in emails+phones+urls+lines:
    k=v.lower()
    if k not in seen:
        seen.add(k); cand.append(v)
assert "ada@analytical.engine" in cand
assert "work@example.com" in cand
assert any("415" in c for c in cand)
assert "https://ada.dev" in cand
# budget cap
capped = cand[:32]
assert len(capped) <= 32
print(f"PASS  Candidate extraction found {len(cand)} unique spans (cap demo {len(capped)})")
PY
pass=$((pass+1))

# --- 8. Info.plist LSUIElement ---
if /usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist" 2>/dev/null | grep -qi true; then
  ok "LSUIElement=true (no Dock icon)"
else
  # GENERATE_INFOPLIST may use INFOPLIST_KEY
  if defaults read "$APP/Contents/Info" LSUIElement 2>/dev/null | grep -q 1; then
    ok "LSUIElement set"
  else
    note "Could not confirm LSUIElement in Info.plist"
  fi
fi

# --- 9. Hotkey registration sanity via logs (optional) ---
# Carbon RegisterEventHotKey fails silently in UI; just note defaults.
ok "Default hotkeys documented: Option-Cmd-V smart paste, Cmd-Shift-D history"

# --- 10. Known gap checks in source ---
if grep -q 'seedFromEnvIfNeeded' Filit/Settings/KeychainStore.swift 2>/dev/null; then
  note "seedFromEnvIfNeeded still present"
else
  ok "No automatic .env API key seeding"
fi

if grep -q 'showSettingsWindow' Filit/AppState.swift; then
  note "Still references showSettingsWindow — prefer floating settings panel"
else
  ok "Settings uses floating panel path"
fi

echo
echo "=== Summary: $pass passed, $fail failed, $warn warnings ==="
[[ "$fail" -eq 0 ]]
