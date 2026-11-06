#!/usr/bin/env bash
# Interception CA for DCF TLS decryption (lab only).
#
#   [ws]   scripts/dcf-ca.sh gen ./dcf-ca        -> dcf-ca/ca.pem + ca-key.pem  (upload BOTH in CoPilot; it wants .pem)
#   [host] sudo scripts/dcf-ca.sh install ca.pem  -> host trust store as .crt (update-ca-certificates needs .crt)
#   [host] sudo scripts/dcf-ca.sh remove          -> undo
#
# The cert is PEM either way; only the extension differs per consumer: CoPilot takes .pem, the Ubuntu
# trust store ignores anything but .crt. Generate on your workstation. The CA KEY (ca-key.pem) never goes on the host.
set -euo pipefail
NAME=agent-sandbox-dcf-ca
DEST=/usr/local/share/ca-certificates/$NAME.crt   # MUST end in .crt or update-ca-certificates skips it

case "${1:-}" in
  gen)
    OUT="${2:?output dir}"; install -d -m 700 "$OUT"
    openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
      -keyout "$OUT/ca-key.pem" -out "$OUT/ca.pem" -subj "/CN=$NAME" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,keyCertSign,cRLSign"
    chmod 600 "$OUT/ca-key.pem"
    echo "==> $OUT/ca.pem and $OUT/ca-key.pem created (both PEM)"
    openssl x509 -in "$OUT/ca.pem" -noout -subject -fingerprint -sha256
    echo "Upload BOTH in CoPilot: Security > Distributed Cloud Firewall > Settings > Decryption CA Certificate."
    echo "Copy ONLY ca.pem to the host, then: sudo scripts/dcf-ca.sh install ca.pem" ;;
  install)
    CRT="${2:?path to the PEM cert (ca.pem or ca.crt)}"
    openssl x509 -in "$CRT" -noout >/dev/null || { echo "not a PEM certificate"; exit 2; }
    install -m 644 "$CRT" "$DEST"          # lands as .crt regardless of input name
    update-ca-certificates
    echo "==> installed $DEST"
    openssl x509 -in "$DEST" -noout -subject -fingerprint -sha256 ;;
  remove)
    rm -f "$DEST"; update-ca-certificates --fresh; echo "==> removed $NAME" ;;
  *) sed -n 2,9p "$0"; exit 2 ;;
esac
