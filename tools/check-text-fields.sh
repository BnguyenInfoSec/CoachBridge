#!/bin/bash
# Every text input in the apps, compared against the reviewed list in tools/text-fields.txt.
#
# Why: typed text flows into LLM prompts, the calendar, the Watch, URLs and HTTP headers. A new
# or changed field must be routed through PromptSafety and covered by InjectionTests before it
# ships (CLAUDE.md, "Text fields"). This script is how a change to a field gets noticed.
#
#   tools/check-text-fields.sh            check; exit 1 if the list and the code differ
#   tools/check-text-fields.sh --update   rewrite the list after the review is done
set -eu
cd "$(dirname "$0")/.."
MANIFEST=tools/text-fields.txt

current() {
    # file|trimmed source line, for every TextField / SecureField / TextEditor. Line numbers are
    # left out so unrelated edits don't trip it; a change to the field's own line does.
    grep -rn -e 'TextField(' -e 'SecureField(' -e 'TextEditor(' CoachBridge Watch PhoneWidgets 2>/dev/null \
        | sed -E 's/^([^:]+):[0-9]+:[[:space:]]*/\1|/' | LC_ALL=C sort
}

if [ "${1:-}" = "--update" ]; then
    {
        echo "# Reviewed text inputs. Regenerate with tools/check-text-fields.sh --update, only after"
        echo "# the field is routed through PromptSafety (if it reaches a prompt, URL or header) and"
        echo "# covered by CoachBridgeTests/InjectionTests.swift. See CLAUDE.md, \"Text fields\"."
        current
    } > "$MANIFEST"
    echo "Updated $MANIFEST ($(current | wc -l | tr -d ' ') fields)."
    exit 0
fi

if ! diff -u <(grep -v '^#' "$MANIFEST") <(current) > /tmp/cb-text-fields.diff 2>/dev/null; then
    echo "Text fields changed since the last injection review:"
    cat /tmp/cb-text-fields.diff | grep -E '^[+-][^+-]' || true
    cat <<'MSG'

Before committing (CLAUDE.md, "Text fields"):
  1. If the field's text can reach a prompt, a URL or an HTTP header, route it through
     PromptSafety (inline / block / webURL / isPlausibleSecret).
  2. Add it to InjectionTests.fields (or the non-prompt tests) and run:
       xcodebuild -scheme CoachBridge -destination 'platform=iOS Simulator,name=iPhone 17' \
         test -only-testing:CoachBridgeTests/InjectionTests
  3. Then record the review: tools/check-text-fields.sh --update
MSG
    exit 1
fi
echo "Text fields match the reviewed list ($(current | wc -l | tr -d ' ') fields)."
