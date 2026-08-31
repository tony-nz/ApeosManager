#!/bin/bash
# Logs into an Apeos device and dumps authenticated API shapes.
# Password is read from the tty and never echoed or stored.
set -u
HOST="${1:?usage: probe-auth.sh <printer-host>}"
read -p  "Admin user ID [11111]: " U; U="${U:-11111}"
read -sp "Password: " P; echo
JAR=$(mktemp); OUT="./apidump-auth"; mkdir -p "$OUT"

b64() { printf '%s' "$1" | base64; }
RES=$(curl -sk --max-time 15 -c "$JAR" -X POST "https://$HOST/LOGIN.cmd" \
      --data-urlencode "NAME=$(b64 "$U")" --data-urlencode "PSW=$(b64 "$P")")
echo "login response: $RES"
case "$RES" in *'"result":"0"'*) echo "  -> OK";; *) echo "  -> FAILED"; rm -f "$JAR"; exit 1;; esac

for ep in permissions/api/internal-accounting permissions/api/all-users-management \
          permissions/api/authorization-groups permissions/api/authorization-group \
          permissions/api/unit-price permissions/api/account-service-access \
          permissions/api/auth-service-access permissions/api/accounting-billing-device \
          home/api/device-configuration system/api/remote-ui-setting; do
  f="$OUT/$(echo "$ep" | tr '/' '_').json"
  code=$(curl -sk --max-time 15 -b "$JAR" -o "$f" -w '%{http_code}' "https://$HOST/$ep")
  printf "  %-46s %s  %s bytes\n" "$ep" "$code" "$(wc -c < "$f" | tr -d ' ')"
done
rm -f "$JAR"
echo "Saved to $OUT/ — no credentials written to disk."
