#!/usr/bin/env bash
# language-audit.sh
#
# Verifica che NESSUNA stringa user-facing nel codice Swift di GIGI sia in
# italiano. La regola dura di CLAUDE.md §"Lingua" impone English-only per
# tutto ciò che l'utente vede o ascolta:
#   - Text(...)        SwiftUI label
#   - Button(...)      SwiftUI label
#   - Label(...)       SwiftUI label
#   - Alert title/msg  system alerts
#   - speech.speak(...) TTS output
#   - showBanner(...)  in-app banner
#   - Push notification body
#   - Local notification body
#   - Accessibility hint / label
#
# Italiano è ammesso solo in: comment, log structured, doc, ADR, commit,
# issue/PR body, CLAUDE.md.
#
# Usage:
#   bash docs/runbooks/language-audit.sh [path_dir|file]
#   bash docs/runbooks/language-audit.sh 02_GIGI_APP/GIGI/
#   bash docs/runbooks/language-audit.sh 02_GIGI_APP/GIGI/Gigi*Macro*.swift
#
# Exit 0 = clean (zero match). Exit 1 = found italian → block merge.

set -uo pipefail

# Ensure UTF-8 locale so grep treats multi-byte chars correctly.
# Without this, emoji bytes can overlap with accented-char bytes
# (e.g. 🏠 ends in 0xA0, same byte as 'à') causing false positives.
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

TARGET="${1:-02_GIGI_APP/GIGI/}"

# Italian trigger words/patterns commonly leaking into user-facing strings.
# Each pattern is wrapped to match only inside Swift string literals containing
# user-facing API surfaces. Extend cautiously — false positives are noisy.
#
# IMPORTANT: pattern includes accented chars (à è é ì ò ù) which are unique to
# Italian/French/Spanish — bias toward Italian per project context.

PATTERNS=(
  # Common Italian verbs in imperative / present (high-precision, low FP risk)
  'eseguire|esegui|aggiungi|aggiungere|chiama|chiamare|imposta|impostare'
  'apri|aprire|chiudi|chiudere|cerca|cercare|trova|trovare'
  'invia|inviare|spedisci|spedire|salva|salvare|elimina|eliminare'
  'registra|registrare|scrivi|scrivere|leggi|leggere|controlla|controllare'
  'accendi|accendere|spegni|spegnere|attiva|attivare|disattiva|disattivare'
  # Italian connectors
  'però|inoltre|tuttavia|allora|adesso|subito|presto'
  # Italian polite forms
  'per favore|grazie|prego|scusa|scusate|certo|certamente'
  # Italian common nouns (limit to clearly Italian-only words; "lista" omitted
  # because it's used in English UI too as informal)
  'momento|momenti|esempio|esempi|risultato|risultati|elenco'
  'errore|errori|avviso|avvisi|notifica|notifiche'
  # Italian articles + prepositions (only inside string literals, high precision)
  'della|delle|dello|degli|dalla|dalle|dallo|dagli'
  'nella|nelle|nello|negli|sulla|sulle|sullo|sugli'
  # Italian pronoun forms common in spoken phrases
  'qualche|qualcuno|qualcosa|niente|nessuno|nessuna'
  # NOTE: accented-char pattern '[àèéìòù]' RIMOSSO — false positive con
  # emoji UTF-8 byte overlap. La precisione viene dalle parole esplicite.
)

USER_FACING_SURFACES=(
  'Text\('
  'Button\('
  'Label\('
  'Alert\('
  'TextField\('
  'speech\.speak\('
  'showBanner\('
  'localNotification\.body'
  'notification\.body'
  '\.accessibilityLabel\('
  '\.accessibilityHint\('
)

EXIT_CODE=0
TOTAL_MATCHES=0

echo "=== language-audit.sh — scan $TARGET ==="
echo ""

for surface in "${USER_FACING_SURFACES[@]}"; do
  for pattern in "${PATTERNS[@]}"; do
    # Match: <surface>("...<pattern>...")
    # Compose the regex: <surface>"[^"]*<pattern>[^"]*"
    composed="${surface}\"[^\"]*(${pattern})[^\"]*\""
    matches=$(grep -rIEn --include='*.swift' "$composed" "$TARGET" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
      echo "❌ Found Italian in user-facing $surface with pattern /$pattern/:"
      echo "$matches" | sed 's/^/   /'
      echo ""
      EXIT_CODE=1
      TOTAL_MATCHES=$((TOTAL_MATCHES + $(echo "$matches" | wc -l)))
    fi
  done
done

if [[ $EXIT_CODE -eq 0 ]]; then
  echo "✅ language-audit clean — zero Italian leaks in user-facing strings"
  echo ""
  echo "Scanned $(find "$TARGET" -name '*.swift' 2>/dev/null | wc -l) Swift file(s)"
  exit 0
else
  echo "❌ language-audit failed — found $TOTAL_MATCHES italian leak(s)"
  echo ""
  echo "Fix: convert all matched strings to English (regola CLAUDE.md §\"Lingua\")."
  echo "Italian is allowed only in comments, logs, docs, ADR, commit messages."
  exit 1
fi
