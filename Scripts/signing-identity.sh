#!/bin/bash
# Resolve the signing identity used by the app and its helpers.
set -euo pipefail
requested="${SIGNING_IDENTITY:-${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-Call Recorder Local Development}}}"
if [[ "$requested" == - ]]; then
    if [[ -n "${AFTERWORD_RELEASE_VERSION:-}" ]]; then
        echo '-'
        exit 0
    fi
    echo 'Afterword requires a persistent signing certificate. Run Scripts/setup-local-signing.sh or set SIGNING_IDENTITY to an existing certificate.' >&2
    exit 1
fi
identities="$(security find-identity -v -p codesigning)"
python3 - "$requested" "$identities" <<'PY'
import re, sys
requested, output = sys.argv[1:]
identities = re.findall(r'^\s*\d+\) ([0-9A-Fa-f]{40}) "(.*)"\s*$', output, re.MULTILINE)
matches = {fingerprint.upper() for fingerprint, name in identities
           if requested == name or requested.upper() == fingerprint.upper()}
if len(matches) != 1:
    print(f'Expected one valid code-signing identity matching {requested!r}; found {len(matches)}. '
          'Run Scripts/setup-local-signing.sh, unlock the login keychain, or select an existing certificate with SIGNING_IDENTITY. '
          'The build will not replace the app with an ad-hoc identity.', file=sys.stderr)
    sys.exit(1)
print(matches.pop())
PY
