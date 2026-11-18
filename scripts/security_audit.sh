#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Static security audit of the repository and (optionally) a built APK.
#
#   ./scripts/security_audit.sh                 # repository only
#   ./scripts/security_audit.sh path/to/app.apk # + APK checks (needs unzip;
#                                               #   aapt2 via ANDROID_HOME optional)
#
# Fails (exit 1) on:
#   * Supabase secret / service_role keys anywhere in tracked files or the APK
#   * committed env files (other than *.example.json), keystores, key.properties
#   * Android manifest allowing backup or cleartext HTTP in release
#   * SECURITY DEFINER functions created outside schema "private"
#   * a release APK that is debuggable
# -----------------------------------------------------------------------------
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0
# A real Supabase secret key: sb_secret_ + ≥16 chars containing digits and
# upper-case letters. Plain identifiers that merely start with "sb_secret_"
# (e.g. the constant used to *reject* such keys) are not reported.
is_key() { grep -E 'sb_secret_[A-Za-z0-9_-]{16,}' | grep -oE 'sb_secret_[A-Za-z0-9_-]{16,}' | grep -E '[0-9]' | grep -E '[A-Z]' | head -3; }
ok()  { echo "ok   - $*"; }
bad() { echo "FAIL - $*"; fail=1; }

FILES="$(git ls-files)"

# 1. Secrets in tracked files ---------------------------------------------------
hits="$(git grep -hIE 'sb_secret_' -- . ':!scripts/security_audit.sh' ':!test/**' ':!docs/**' | is_key)"
if [ -n "$hits" ]; then bad "Supabase secret key (sb_secret_…) found in tracked files: $(echo "$hits" | cut -c1-14)…"
else ok "no sb_secret_ keys in tracked files"; fi

jwt_hits=0
while IFS= read -r tok; do
  payload="$(echo "$tok" | cut -d. -f2 | tr '_-' '/+')"
  while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload="${payload}="; done
  if echo "$payload" | base64 -d 2>/dev/null | grep -q '"service_role"'; then jwt_hits=$((jwt_hits + 1)); fi
done < <(git grep -hIoE 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' -- . ':!test/**' || true)
if [ "$jwt_hits" -gt 0 ]; then bad "$jwt_hits service_role JWT(s) found in tracked files"; else ok "no service_role JWTs in tracked files"; fi

# 2. Files that must never be committed ----------------------------------------
if echo "$FILES" | grep -E '^env/.*\.json$' | grep -vE '\.example\.json$' | grep -q .; then
  bad "real env files committed: $(echo "$FILES" | grep -E '^env/.*\.json$' | grep -vE '\.example\.json$' | tr '\n' ' ')"
else ok "no real env/*.json committed"; fi
if echo "$FILES" | grep -qE '\.(jks|keystore)$|(^|/)key\.properties$'; then bad "keystore or key.properties committed"; else ok "no keystore / key.properties committed"; fi

# 3. Android manifest / network policy -----------------------------------------
M=android/app/src/main/AndroidManifest.xml
grep -q 'android:allowBackup="false"' "$M" && ok "allowBackup=false" || bad "allowBackup is not false"
grep -q 'android:usesCleartextTraffic="false"' "$M" && ok "usesCleartextTraffic=false" || bad "cleartext traffic not disabled"
grep -q 'android:networkSecurityConfig="@xml/network_security_config"' "$M" && ok "network security config referenced" \
  || bad "network security config missing"
NSC=android/app/src/main/res/xml/network_security_config.xml
if [ -f "$NSC" ] && ! grep -q 'cleartextTrafficPermitted="true"' "$NSC"; then ok "release network config: HTTPS only"; else bad "release network config allows cleartext"; fi

# 4. SECURITY DEFINER only in schema private -------------------------------------
defs="$(grep -nE 'create (or replace )?function +[a-z_]+\.' supabase/migrations/*.sql | grep -vE 'function +(private|tests)\.' | cut -d: -f1,2)"
outside=0
while IFS=: read -r f line; do
  [ -z "$f" ] && continue
  # look at the next 15 lines of that function header for SECURITY DEFINER
  if sed -n "${line},$((line + 15))p" "$f" | grep -qiE '^\s*security definer'; then
    bad "SECURITY DEFINER outside private: $f:$line"; outside=1
  fi
done <<< "$defs"
[ $outside -eq 0 ] && ok "SECURITY DEFINER functions only in schema private"

# 5. APK checks ---------------------------------------------------------------------
APK="${1:-}"
if [ -n "$APK" ]; then
  [ -f "$APK" ] || { bad "APK not found: $APK"; exit 1; }
  TMP="$(mktemp -d)"
  unzip -q -o "$APK" -d "$TMP"
  hits="$(grep -raoE 'sb_secret_[A-Za-z0-9_-]{16,}' "$TMP" 2>/dev/null | is_key)"
  if [ -n "$hits" ]; then bad "APK contains an sb_secret_ key"; else ok "APK: no sb_secret_ key"; fi
  apk_jwt=0
  while IFS= read -r tok; do
    payload="$(echo "$tok" | cut -d. -f2 | tr '_-' '/+')"
    while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload="${payload}="; done
    if echo "$payload" | base64 -d 2>/dev/null | grep -q '"service_role"'; then apk_jwt=$((apk_jwt + 1)); fi
  done < <(grep -rhaoE 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' "$TMP" 2>/dev/null || true)
  [ "$apk_jwt" -eq 0 ] && ok "APK: no service_role JWT" || bad "APK contains $apk_jwt service_role JWT(s)"
  AAPT2="$(ls -d "${ANDROID_HOME:-/nonexistent}"/build-tools/*/aapt2 2>/dev/null | tail -1)"
  if [ -n "$AAPT2" ]; then
    BADGING="$("$AAPT2" dump badging "$APK" 2>/dev/null)"
    echo "     $(echo "$BADGING" | grep -E "^package:" | head -1)"
    echo "     $(echo "$BADGING" | grep -E "^(minSdkVersion|targetSdkVersion)" | tr '\n' ' ')"
    echo "     permissions: $(echo "$BADGING" | grep -oE "uses-permission: name='[^']+'" | sed "s/uses-permission: name=//" | tr '\n' ' ')"
    if [[ "$APK" == *release* ]] && echo "$BADGING" | grep -q "application-debuggable"; then bad "release APK is debuggable"
    else ok "APK debuggable flag as expected for this build type"; fi
  fi
  rm -rf "$TMP"
fi

exit $fail
