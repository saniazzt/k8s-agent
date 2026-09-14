#!/usr/bin/env python3
"""PostToolUse hook — redact secret material before it reaches the model.

Two layers:
  1. exact values listed in `.rca/secret-values.txt` (written by scripts/setup.sh,
     gitignored, never passed to the model),
  2. generic patterns: KEY=value for credential-ish keys, and base64 blobs whose
     decoding looks like a credential.

If anything matched, the tool result is replaced (decision: "block" + reason)
with a redacted version, and the model is told not to retry.
"""

import base64
import json
import os
import re
import sys

SECRET_FILE = os.environ.get(
    "RCA_SECRET_LIST",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".rca", "secret-values.txt"),
)

CRED_KEY = re.compile(
    r"(?i)\b([A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|TOKEN|APIKEY|API_KEY|PRIVATE_KEY|ACCESS_KEY)[A-Z0-9_]*)"
    r"(\s*[:=]\s*)"
    r"([^\s\"',;]+|\"[^\"]*\"|'[^']*')"
)
BASE64_BLOB = re.compile(r"[A-Za-z0-9+/]{24,}={0,2}")


def known_secrets() -> list:
    values = []
    try:
        with open(SECRET_FILE, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#"):
                    values.append(line)
    except OSError:
        pass
    # also the base64 form, since Secret data appears encoded
    encoded = []
    for value in list(values):
        encoded.append(base64.b64encode(value.encode()).decode())
    return values + encoded


def looks_like_credential(decoded: str) -> bool:
    return bool(re.search(r"(?i)(password|secret|token|api[_-]?key)", decoded))


def redact(text: str, secrets: list) -> tuple:
    hits = 0

    for value in secrets:
        if value and value in text:
            text = text.replace(value, "***REDACTED***")
            hits += 1

    def _mask_match(match: re.Match) -> str:
        nonlocal hits
        hits += 1
        return f"{match.group(1)}{match.group(2)}***REDACTED***"

    text = CRED_KEY.sub(_mask_match, text)

    def _mask_b64(match: re.Match) -> str:
        nonlocal hits
        blob = match.group(0)
        try:
            decoded = base64.b64decode(blob + "=" * (-len(blob) % 4)).decode("utf-8", "ignore")
        except Exception:
            return blob
        if looks_like_credential(decoded):
            hits += 1
            return "***REDACTED***"
        return blob

    text = BASE64_BLOB.sub(_mask_b64, text)
    return text, hits


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    response = payload.get("tool_response")
    if response is None:
        sys.exit(0)

    text = response if isinstance(response, str) else json.dumps(response, ensure_ascii=False)
    redacted, hits = redact(text, known_secrets())

    if hits == 0:
        sys.exit(0)

    reason = (
        "NOTE: the tool output contained credential material and was redacted by "
        "the rca-agent PostToolUse hook. Do not attempt to read the secret again, "
        "and do not try to reconstruct the value. Continue the RCA without it.\n\n"
        "--- redacted output ---\n" + redacted[:20000]
    )
    print(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(0)


if __name__ == "__main__":
    main()
