#!/bin/sh
# sing-box node installer. Interactive: run it in a terminal and answer the questions
# (mode: reality, ss, hy2, or both = Reality + HY2).
# Credentials for selected nodes rotate unless a supported password environment
# override is set. Unselected inbounds are preserved. TLS pairs may be reused.
# SSH files are preserved by default. SSH_KEY_REGENERATE=1 backs up old key files
# and appends a fresh public key; SSH_KEY_DELETE=1 / sshkey --delete are opt-in.
# Never changes sshd password authentication; HY2 local mode owns one isolated NAT table.
# HY2 Let's Encrypt certificates use acme.sh (pure shell, a few MB of RAM) with Cloudflare DNS-01.
# The local protocol self-check is off by default; run with SELF_CHECK=1 to enable it.
# For safe unit tests: INSTALLER_SOURCE_ONLY=1 source ./install_reality.sh in bash.

# Source-only loading must happen under bash, before bootstrap or any mutation.
if [ "${INSTALLER_SOURCE_ONLY:-0}" = 1 ] && [ -z "${BASH_VERSION:-}" ]; then
  printf '%s\n' 'Source-only testing requires bash; bootstrap was skipped.' >&2
  return 1 2>/dev/null || exit 1
fi

_info2() { printf '[*] %s\n' "$*"; }
_ok2() { printf '[OK] %s\n' "$*"; }
_err2() { printf '[!] %s\n' "$*" >&2; }
_warn2() { _err2 "$@"; }
_cmd() { command -v "$1" >/dev/null 2>&1; }

# POSIX sh -> bash bootstrap (including downloaded/piped execution).
if [ -z "${BASH_VERSION:-}" ]; then
  [ "$(id -u)" = 0 ] || { _err2 'Run as root'; exit 1; }
  if ! _cmd bash || ! _cmd curl; then
    if _cmd apk; then apk add --no-cache bash curl ca-certificates || exit 1
    elif _cmd apt-get; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y bash curl ca-certificates || exit 1
    elif _cmd dnf; then dnf install -y bash curl ca-certificates || exit 1
    elif _cmd yum; then yum install -y bash curl ca-certificates || exit 1
    elif _cmd zypper; then zypper --non-interactive install bash curl ca-certificates || exit 1
    elif _cmd pacman; then pacman -Sy --noconfirm bash curl ca-certificates || exit 1
    else _err2 'Install bash and curl first.'; exit 1
    fi
  fi
  if [ -f "$0" ]; then exec bash "$0" "$@"; fi
  _bootstrap=$(mktemp /tmp/install-reality.XXXXXX) || exit 1
  curl -fL --connect-timeout 10 -m 60 "${SCRIPT_URL:-https://raw.githubusercontent.com/hytuytujyt/vps-network-tools/main/install_reality.sh}" -o "$_bootstrap" || { rm -f "$_bootstrap"; exit 1; }
  exec bash "$_bootstrap" "$@"
fi

fail() { _err2 "$*"; return 1; }

normalize_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || { fail "Invalid port: $p (expected 1..65535)"; return 1; }
  # Strip arbitrary leading zeroes before arithmetic, avoiding octal/overflow.
  while [[ ${#p} -gt 1 && "$p" == 0* ]]; do p="${p#0}"; done
  [[ ${#p} -le 5 ]] || { fail "Port outside 1..65535: $p"; return 1; }
  p=$((10#$p))
  (( p >= 1 && p <= 65535 )) || { fail "Port outside 1..65535: $p"; return 1; }
  printf '%s\n' "$p"
}

normalize_hy2_ports() {
  local spec="$1" token start end result='[]' count=0 only=0
  [[ "$spec" =~ ^[0-9,:-]+$ && "$spec" != ,* && "$spec" != *, && "$spec" != *,,* ]] || { fail 'Invalid HY2_SERVER_PORTS list'; return 1; }
  local -a tokens
  IFS=, read -r -a tokens <<< "$spec"
  for token in "${tokens[@]}"; do
    if [[ "$token" =~ ^([0-9]+)([-:])([0-9]+)$ ]]; then
      start=$(normalize_port "${BASH_REMATCH[1]}") || return 1
      end=$(normalize_port "${BASH_REMATCH[3]}") || return 1
    else
      start=$(normalize_port "$token") || return 1
      end="$start"
    fi
    (( start <= end )) || { fail "Reversed HY2 port range: $token"; return 1; }
    only="$start"
    result=$(jq -cn --argjson a "$result" --arg p "$start:$end" '$a + [$p]') || return 1
  done
  # Sort and merge overlapping/adjacent intervals without expanding individual ports.
  local merged
  merged=$(jq -c '[.[]|split(":")|map(tonumber)] | sort_by(.[0],.[1]) | reduce .[] as $x ([]; if length>0 and $x[0]<=.[-1][1]+1 then .[-1][1]=([.[-1][1],$x[1]]|max) else .+[$x] end) | if length>64 then error("HY2 supports at most 64 disjoint intervals") else . end' <<< "$result") || return 1
  HY2_INTERVALS_JSON=$merged
  result=$(jq -c 'map("\(.[0]):\(.[1])")' <<< "$merged") || return 1
  count=$(jq '[.[]|.[1]-.[0]+1]|add' <<< "$merged")
  only=$(jq '.[0][0]' <<< "$merged")
  HY2_PORTS_JSON="$result"
  HY2_PORT_COUNT="$count"
  HY2_SINGLE_PORT="$only"
}

validate_host() {
  # Unbracketed IPv6, IPv4, or DNS name; bracket only at URI rendering time.
  [[ "$1" =~ ^[a-zA-Z0-9_.:-]+$ && "$1" != -* ]] || { fail "Invalid $2: use an unbracketed IP or hostname without whitespace"; return 1; }
}

init_settings() {
  MODE="${MODE:-reality}"
  HY2_CERT_MODE="${HY2_CERT_MODE:-self}"
  ACME_EMAIL="${ACME_EMAIL:-}"
  case "$MODE" in
    reality|ss|hy2|both) ;;
    relay) fail 'MODE=relay was renamed: use MODE=reality'; return 1 ;;
    landing) fail 'MODE=landing was renamed: use MODE=ss'; return 1 ;;
    *) fail "Unknown MODE=$MODE; use reality, ss, hy2, or both"; return 1 ;;
  esac
  : "${SERVER_IP:?SERVER_IP is required in every mode}"
  validate_host "$SERVER_IP" SERVER_IP || return 1
  CONFIG_DIR="${CONFIG_DIR:-/etc/sing-box}"
  CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config.json}"
  LISTEN_ADDR="${LISTEN_ADDR:-0.0.0.0}"
  validate_host "$LISTEN_ADDR" LISTEN_ADDR || return 1
  NODE_NAME="${NODE_NAME:-$MODE-$(hostname)}"
  REALITY_DEST="${REALITY_DEST:-}"
  REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-}"
  REALITY_DEST_CANDIDATES="${REALITY_DEST_CANDIDATES:-addons.mozilla.org:443 www.libreoffice.org:443 www.videolan.org:443 www.debian.org:443 www.postgresql.org:443}"
  if [[ "$MODE" != hy2 ]]; then
    ACTUAL_LISTEN_PORT=$(normalize_port "${ACTUAL_LISTEN_PORT:-}") || return 1
    LISTEN_PORT=$(normalize_port "${LISTEN_PORT:-}") || return 1
  fi
  if [[ "$MODE" == hy2 || "$MODE" == both ]]; then
    HY2_LISTEN_PORT=$(normalize_port "${HY2_LISTEN_PORT:-${ACTUAL_LISTEN_PORT:-}}") || return 1
    HY2_SERVER_PORTS="${HY2_SERVER_PORTS:-$HY2_LISTEN_PORT}"
    normalize_hy2_ports "$HY2_SERVER_PORTS" || return 1
    HY2_PORT_HOPPING_MODE=${HY2_PORT_HOPPING_MODE:-external}
    case "$HY2_PORT_HOPPING_MODE" in local|external) ;; *) fail 'HY2_PORT_HOPPING_MODE must be local or external'; return 1 ;; esac
    HY2_OBFS="${HY2_OBFS:-gecko}"
    case "$HY2_OBFS" in gecko|none|salamander) ;; *) fail 'HY2_OBFS must be gecko, none, or salamander'; return 1 ;; esac
    HY2_SNI="${HY2_SNI:-hy2.local}"
    [[ "$HY2_SNI" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || { fail 'HY2_SNI must be a DNS name without whitespace'; return 1; }
    # Fixed page served to unauthenticated HTTP/3 requests; no upstream relay, so nothing is fetched on a prober's behalf.
    HY2_MASQUERADE_HTML="${HY2_MASQUERADE_HTML:-<!doctype html><html><head><meta charset=utf-8><title>Welcome</title></head><body><h1>Welcome</h1></body></html>}"
    [[ -n "$HY2_MASQUERADE_HTML" ]] || { fail 'HY2_MASQUERADE_HTML must not be empty'; return 1; }
    case "$HY2_CERT_MODE" in self|le) ;; *) fail 'HY2_CERT_MODE must be self or le'; return 1 ;; esac
    if [[ "$HY2_CERT_MODE" == le ]]; then
      [[ "$HY2_SNI" =~ ^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ && "$HY2_SNI" != *.local ]] || { fail 'HY2_CERT_MODE=le needs a real domain as HY2_SNI'; return 1; }
      [[ "$ACME_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { fail 'HY2_CERT_MODE=le needs ACME_EMAIL'; return 1; }
    fi
    HY2_HOP_INTERVAL="${HY2_HOP_INTERVAL:-30s}"
    # Exact duration validity and >0 are checked below by sing-box.
    [[ "$HY2_HOP_INTERVAL" =~ ^[0-9a-z.µμ]+$ && "$HY2_HOP_INTERVAL" =~ [1-9] ]] || { fail 'HY2_HOP_INTERVAL must be a positive duration, e.g. 30s'; return 1; }
  fi
  BIN="${BIN:-$(command -v sing-box || true)}"
  # Generated client profiles use 1.12+ DNS/route syntax.
  MIN_CORE_VERSION="${MIN_CORE_VERSION:-1.12.0}"
  [[ "$MIN_CORE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { fail 'MIN_CORE_VERSION must look like 1.12.0'; return 1; }
  SSH_DIR="${SSH_DIR:-/root/.ssh}"
}

install_packages() {
  if _cmd apk; then apk add --no-cache "$@"
  elif _cmd apt-get; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  elif _cmd dnf; then dnf install -y "$@"
  elif _cmd yum; then yum install -y "$@"
  elif _cmd zypper; then zypper --non-interactive install "$@"
  elif _cmd pacman; then pacman -Sy --noconfirm "$@"
  else fail "Install required packages manually: $*"; fi
}

robust_download() {
  local url="$1" out="$2" attempt
  for attempt in 1 2 3 4 5; do
    if curl -fL -C - --retry 3 --retry-delay 2 --connect-timeout 20 -o "$out" "$url"; then return 0; fi
    _warn2 "Download interrupted; retry $attempt/5"
    sleep 2
  done
  return 1
}

core_version_ge() {
  # True when version $1 >= $2 (numeric X.Y.Z comparison; suffixes ignored).
  awk -v a="$1" -v b="$2" 'BEGIN{
    split(a,x,"."); split(b,y,".");
    for (i=1;i<=3;i++) { if ((x[i]+0) > (y[i]+0)) exit 0; if ((x[i]+0) < (y[i]+0)) exit 1 }
    exit 0 }'
}

latest_core_version() {
  local v url prefix='https://github.com/SagerNet/sing-box/releases/tag/v'
  # Unauthenticated API on a shared/NAT address is easily rate limited.
  v=$(curl -fsSL --connect-timeout 10 -m 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null |
        jq -er '.tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) | ltrimstr("v")' 2>/dev/null) &&
    { printf '%s\n' "$v"; return 0; }
  # Follow the public release page and accept only a stable tag from this repository.
  url=$(curl -fsSLI --proto '=https' --proto-redir '=https' --connect-timeout 10 -m 20 -o /dev/null -w '%{url_effective}' \
    https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null) || return 1
  [[ "$url" == "$prefix"* ]] || return 1
  v=${url#"$prefix"}
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "$v"
}

required_core_version() {
  if [[ "$MODE" == hy2 || "$MODE" == both ]] && [[ "$HY2_OBFS" == gecko ]] && ! core_version_ge "$MIN_CORE_VERSION" 1.14.0; then
    printf '%s\n' '1.14.0'
  else
    printf '%s\n' "$MIN_CORE_VERSION"
  fi
}

read_core_version() {
  local output
  output=$("$1" version) || return 1
  awk '/^sing-box version/ {print $3; found=1; exit} END {if (!found) exit 1}' <<< "$output"
}

stage_singbox() {
  local need arch version tarball binfile have
  need=$(required_core_version) || return 1
  if [[ -n "${BIN:-}" ]]; then
    have=$(read_core_version "$BIN" 2>/dev/null) || have=''
    if [[ "$have" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] && core_version_ge "$have" "$need"; then
      _ok2 "Using installed core $have for configuration checks (minimum $need)."
      return 0
    fi
    _info2 "Installed core ${have:-unknown} does not meet minimum $need for this selection; staging a current build."
  fi
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
    i?86) arch=386 ;; armv7l|armv6l|armhf) arch=armv7 ;;
    riscv64|s390x) arch=$(uname -m) ;; *) fail 'Unsupported architecture'; return 1 ;;
  esac
  version=$(latest_core_version) || { fail 'Cannot determine the latest sing-box release (network failure or GitHub API rate limit); retry later'; return 1; }
  core_version_ge "$version" "$need" || { fail "Latest release $version is below the required core version $need"; return 1; }
  mkdir -p /var/tmp || return 1
  CORE_STAGE_DIR=$(mktemp -d /var/tmp/singbox-install.XXXXXX) || return 1
  tarball="sing-box-$version-linux-$arch-musl.tar.gz"
  if ! robust_download "https://github.com/SagerNet/sing-box/releases/download/v$version/$tarball" "$CORE_STAGE_DIR/$tarball"; then
    tarball="sing-box-$version-linux-$arch.tar.gz"
    robust_download "https://github.com/SagerNet/sing-box/releases/download/v$version/$tarball" "$CORE_STAGE_DIR/$tarball" || return 1
  fi
  gzip -t "$CORE_STAGE_DIR/$tarball" && tar -xzf "$CORE_STAGE_DIR/$tarball" -C "$CORE_STAGE_DIR" || return 1
  # Drop the archive right away: on small machines /var/tmp may be RAM-backed.
  rm -f "$CORE_STAGE_DIR/$tarball"
  binfile=$(find "$CORE_STAGE_DIR" -type f -name sing-box -print -quit) || return 1
  if [[ -z "$binfile" ]] || ! have=$(read_core_version "$binfile") ||
    [[ ! "$have" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || ! core_version_ge "$have" "$need"; then
    fail "Downloaded core is unusable or below the required version $need"; return 1
  fi
  BIN="$binfile"
}

install_staged_singbox() {
  [[ -n "${CORE_STAGE_DIR:-}" ]] || return 0
  local target
  mkdir -p /usr/local/bin || return 1
  target=$(mktemp /usr/local/bin/.sing-box.XXXXXX) || return 1
  # Write beside the target and rename: overwriting a running binary gives ETXTBSY.
  install -m 755 "$BIN" "$target" && cmp -s "$BIN" "$target" &&
    mv -f "$target" /usr/local/bin/sing-box || { rm -f "$target"; return 1; }
  BIN=/usr/local/bin/sing-box
}

reality_dest_probe() {
  local host="${1%:*}" port="${1##*:}" line
  local -a opts=(--tlsv1.3 --tls-max 1.3)
  if curl --http2 -V >/dev/null 2>&1; then opts+=(--http2); fi
  line=$(curl -sI "${opts[@]}" --connect-timeout 4 -m 8 "https://$host:$port/" 2>/dev/null) || return 1
  [[ "$line" == HTTP/* ]]
}

select_reality_dest() {
  local cand host port
  if [[ -z "$REALITY_DEST" && -n "$REALITY_SERVER_NAME" ]]; then REALITY_DEST="$REALITY_SERVER_NAME:443"; fi
  if [[ -z "$REALITY_DEST" ]]; then
    for cand in $REALITY_DEST_CANDIDATES; do
      [[ "$cand" == *:* ]] || cand="$cand:443"
      if reality_dest_probe "$cand"; then REALITY_DEST="$cand"; break; fi
    done
    [[ -n "$REALITY_DEST" ]] || { fail 'No reachable TLS 1.3 Reality target; set REALITY_DEST explicitly'; return 1; }
  else
    [[ "$REALITY_DEST" == *:* ]] || REALITY_DEST="$REALITY_DEST:443"
    reality_dest_probe "$REALITY_DEST" || _warn2 "Target probe failed for explicit REALITY_DEST=$REALITY_DEST; handshake self-check must still pass."
  fi
  host="${REALITY_DEST%:*}"; host="${host#[}"; host="${host%]}"
  validate_host "$host" REALITY_DEST || return 1
  port=$(normalize_port "${REALITY_DEST##*:}") || return 1
  REALITY_DEST_HOST="$host"; REALITY_DEST_PORT="$port"
  REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-$host}"
  validate_host "$REALITY_SERVER_NAME" REALITY_SERVER_NAME || return 1
}

generate_credentials() {
  local keys
  keys=$("$BIN" generate reality-keypair) || return 1
  PRIVATE_KEY=$(printf '%s\n' "$keys" | awk '/^PrivateKey:/{print $2}')
  PUBLIC_KEY=$(printf '%s\n' "$keys" | awk '/^PublicKey:/{print $2}')
  [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]] || { fail 'Cannot parse Reality keypair'; return 1; }
  UUID=$("$BIN" generate uuid) || return 1
  SHORT_ID=$("$BIN" generate rand 8 --hex) || return 1
}

generate_ss_credentials() {
  SS_METHOD="${SS_METHOD:-aes-128-gcm}"
  SS_PASSWORD="${SS_PASSWORD:-$("$BIN" generate rand 16 --base64)}"
  [[ -n "$SS_PASSWORD" ]] || return 1
}

cert_matches_sni() {
  # sing-box emits a self-signed leaf, which can never pass `openssl verify`;
  # match the requested name against SAN (preferred) or the subject CN instead.
  # No `grep -q` at the end of a pipeline: under pipefail an early grep exit can
  # surface as SIGPIPE (141) in an upstream command and turn a match into a failure.
  local cert="$1" sans
  if sans=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null) && [[ -n "$sans" ]]; then
    printf '%s\n' "$sans" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -xF "DNS:$HY2_SNI" >/dev/null
    return $?
  fi
  # OpenSSL < 1.1.1 has no -ext; fall back to an exact commonName match.
  openssl x509 -in "$cert" -noout -subject -nameopt multiline 2>/dev/null |
    sed -n 's/^[[:space:]]*commonName[[:space:]]*=[[:space:]]*//p' | grep -xF "$HY2_SNI" >/dev/null
}

valid_tls_pair() {
  local cert="$1" key="$2"
  [[ -s "$cert" && -s "$key" ]] || return 1
  openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null 2>&1 || return 1
  cert_matches_sni "$cert" || return 1
  cmp -s <(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null) <(openssl pkey -in "$key" -pubout 2>/dev/null) || return 1
  openssl pkey -in "$key" -noout >/dev/null 2>&1
}

install_acme_tools() {
  # acme.sh is a pure shell client (curl + openssl): a few MB of RAM, unlike Python certbot
  # which gets OOM-killed on 128 MB machines. Installed once under $ACMESH_HOME.
  ACMESH_HOME="${ACMESH_HOME:-/root/.acme.sh}"
  ACMESH_BIN="$ACMESH_HOME/acme.sh"
  ACME_RELOAD_HOOK=/usr/local/libexec/vps-network-tools/reload-sing-box.sh
  local dir url
  _cmd openssl || install_packages openssl
  _cmd tar || install_packages tar
  [[ -x "$ACMESH_BIN" ]] && return 0
  dir=$(mktemp -d "$WORK_DIR/acme-src.XXXXXX") || return 1
  # Override ACME_SH_URL to pin a release tarball instead of following master.
  url="${ACME_SH_URL:-https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.tar.gz}"
  robust_download "$url" "$dir/acme.tar.gz" || { fail 'Cannot download acme.sh'; return 1; }
  tar -xzf "$dir/acme.tar.gz" -C "$dir" --strip-components=1 || { fail 'Cannot unpack acme.sh'; return 1; }
  # Our own timer/cron entry handles renewal, so acme.sh must not touch crontab or shell profiles.
  (cd "$dir" && sh ./acme.sh --install --home "$ACMESH_HOME" --nocron --noprofile --accountemail "$ACME_EMAIL") ||
    { fail 'acme.sh installation failed'; return 1; }
  [[ -x "$ACMESH_BIN" ]] || { fail 'acme.sh was not installed'; return 1; }
}

install_cert_reload_hook() {
  # Run by acme.sh after every install/renewal. Restarts sing-box only if it is already running,
  # and never fails, so the very first issuance (service not created yet) is not aborted.
  install -d -m 755 /usr/local/libexec/vps-network-tools || return 1
  cat > "$ACME_RELOAD_HOOK" <<'EOF'
#!/bin/sh
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  systemctl is-active --quiet sing-box && systemctl restart sing-box
elif command -v rc-service >/dev/null 2>&1; then
  rc-service sing-box status >/dev/null 2>&1 && rc-service sing-box restart
fi
exit 0
EOF
  chmod 755 "$ACME_RELOAD_HOOK"
}

ensure_crond() {
  # Alpine's crond is not enabled on every image; log rotation and renewal both need it.
  # Minimal NAT containers can lack the stock crond service or its syslog/hostname dependencies,
  # so fall back to a tiny dependency-free OpenRC service around the busybox crond applet.
  _cmd apk || return 0
  local crond_bin
  if _cmd rc-service && [[ -x /etc/init.d/crond ]]; then
    if rc-service crond status >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1; then
      rc-update add crond default >/dev/null 2>&1 || true
      return 0
    fi
    # The stock service cannot start here; do not leave it failing at every boot.
    rc-update del crond default >/dev/null 2>&1 || true
  fi
  crond_bin=$(command -v crond) || { _warn2 'crond is unavailable; certificate renewal and log rotation will not run automatically.'; return 0; }
  if _cmd rc-service && _cmd rc-update; then
    cat > /etc/init.d/crond-standalone <<EOF
#!/sbin/openrc-run
description="busybox crond without syslog/hostname dependencies"
command="$crond_bin"
command_args="-f -L /dev/null"
command_background="yes"
pidfile="/run/crond-standalone.pid"
depend() { :; }
EOF
    chmod 755 /etc/init.d/crond-standalone
    rc-update add crond-standalone default >/dev/null 2>&1 || true
    rc-service crond-standalone status >/dev/null 2>&1 || rc-service crond-standalone start ||
      _warn2 'Could not start crond; scheduled jobs will not run.'
  else
    pidof crond >/dev/null 2>&1 || "$crond_bin" -b -L /dev/null || true
    _warn2 'No OpenRC available; crond was started for now but will not survive a reboot.'
  fi
}

install_le_renewal() {
  # acme.sh --cron renews only certificates that are due and runs the saved reload hook.
  # systemd hosts get a timer (no cron daemon needed); Alpine/others get a daily cron job.
  if _cmd systemctl && [[ -d /run/systemd/system ]]; then
    cat > /etc/systemd/system/sing-box-acme-renew.service <<EOF || return 1
[Unit]
Description=Renew Let's Encrypt certificate for sing-box
After=network-online.target
[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=$ACMESH_BIN --cron --home $ACMESH_HOME
EOF
    cat > /etc/systemd/system/sing-box-acme-renew.timer <<'EOF' || return 1
[Unit]
Description=Daily sing-box certificate renewal check
[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload && systemctl enable --now sing-box-acme-renew.timer || return 1
  elif _cmd apk; then
    mkdir -p /etc/periodic/daily || return 1
    printf '#!/bin/sh\nHOME=/root %s --cron --home %s >/dev/null 2>&1\n' "$ACMESH_BIN" "$ACMESH_HOME" > /etc/periodic/daily/acme-renew || return 1
    chmod 755 /etc/periodic/daily/acme-renew || return 1
    ensure_crond
  else
    printf '17 3 * * * root HOME=/root %s --cron --home %s >/dev/null 2>&1\n' "$ACMESH_BIN" "$ACMESH_HOME" > /etc/cron.d/sing-box-acme || return 1
  fi
}

prepare_le_tls() {
  # Let's Encrypt through Cloudflare DNS-01 (acme.sh dns_cf): no port 80 needed.
  # The token comes from /root/.secrets/cloudflare.ini, written by the wizard.
  local live="$CONFIG_DIR/le/$HY2_SNI" token rc=0
  install_acme_tools || return 1
  install_cert_reload_hook || return 1
  if ! valid_tls_pair "$live/fullchain.pem" "$live/privkey.pem"; then
    token=$(sed -n 's/^dns_cloudflare_api_token[[:space:]]*=[[:space:]]*//p' /root/.secrets/cloudflare.ini 2>/dev/null | head -n 1)
    [[ -n "$token" ]] || { fail 'Cloudflare token missing in /root/.secrets/cloudflare.ini'; return 1; }
    # Token goes through the environment, never argv. acme.sh defaults to ZeroSSL, so name the CA.
    CF_Token="$token" "$ACMESH_BIN" --home "$ACMESH_HOME" --issue --server letsencrypt --dns dns_cf \
      -d "$HY2_SNI" --keylength ec-256 --dnssleep 30 --accountemail "$ACME_EMAIL" || rc=$?
    unset token
    # Exit status 2 means a still-valid certificate exists and issuing was skipped.
    [[ "$rc" == 0 || "$rc" == 2 ]] || { fail "Let's Encrypt issuance failed for $HY2_SNI; check the acme.sh output above"; return 1; }
    install -d -m 700 "$CONFIG_DIR/le" "$live" || return 1
    "$ACMESH_BIN" --home "$ACMESH_HOME" --install-cert -d "$HY2_SNI" --ecc \
      --fullchain-file "$live/fullchain.pem" --key-file "$live/privkey.pem" --reloadcmd "$ACME_RELOAD_HOOK" ||
      { fail 'acme.sh could not install the certificate'; return 1; }
    chmod 600 "$live/privkey.pem" || true
  fi
  valid_tls_pair "$live/fullchain.pem" "$live/privkey.pem" || { fail "Let's Encrypt certificate for $HY2_SNI is not usable"; return 1; }
  install_le_renewal || _warn2 'Automatic renewal could not be fully configured; run acme.sh --cron manually.'
  HY2_CERT="$live/fullchain.pem"; HY2_KEY="$live/privkey.pem"
  _ok2 "Using Let's Encrypt certificate for $HY2_SNI."
}

prepare_hy2_tls() {
  if [[ "$HY2_CERT_MODE" == le ]]; then prepare_le_tls; return; fi
  # Separate installer-owned directories; never overwrite unrelated certificates.
  local id base fresh pem
  id=$(printf '%s' "$HY2_SNI" | cksum | awk '{print $1}')
  base="$CONFIG_DIR/hy2-tls/$id"
  mkdir -p "$CONFIG_DIR/hy2-tls"
  chmod 700 "$CONFIG_DIR/hy2-tls"
  if valid_tls_pair "$base/cert.pem" "$base/key.pem"; then
    HY2_CERT="$base/cert.pem"; HY2_KEY="$base/key.pem"
    chmod 700 "$base"; chmod 600 "$HY2_CERT" "$HY2_KEY"
    _info2 'Reusing TLS pair after expiry, hostname, chain and key-match checks.'
    return 0
  fi
  fresh=$(mktemp -d "$CONFIG_DIR/hy2-tls/$id.new.XXXXXX") || return 1
  chmod 700 "$fresh"
  pem=$("$BIN" generate tls-keypair "$HY2_SNI" -m 36) || { rm -rf "$fresh"; return 1; }
  # Accept optional labels/CRLF but only complete, single PEM blocks.
  printf '%s\n' "$pem" | tr -d '\r' | awk '
    /^-----BEGIN CERTIFICATE-----$/ {n++; copying=1}
    copying {print}
    /^-----END CERTIFICATE-----$/ {copying=0; ends++}
    END {if (n!=1 || ends!=1 || copying) exit 1}
  ' > "$fresh/cert.pem" || { rm -rf "$fresh"; return 1; }
  printf '%s\n' "$pem" | tr -d '\r' | awk '
    /^-----BEGIN (RSA |EC )?PRIVATE KEY-----$/ {n++; copying=1}
    copying {print}
    /^-----END (RSA |EC )?PRIVATE KEY-----$/ {copying=0; ends++}
    END {if (n!=1 || ends!=1 || copying) exit 1}
  ' > "$fresh/key.pem" || { rm -rf "$fresh"; return 1; }
  chmod 600 "$fresh/cert.pem" "$fresh/key.pem"
  valid_tls_pair "$fresh/cert.pem" "$fresh/key.pem" || { rm -rf "$fresh"; fail 'Generated TLS pair failed OpenSSL checks'; return 1; }
  # Keep exactly one previous pair for inspection; each regeneration replaces it.
  rm -rf "$base.prev"
  if [[ -e "$base" ]]; then mv "$base" "$base.prev"; fi
  mv "$fresh" "$base"
  HY2_CERT="$base/cert.pem"; HY2_KEY="$base/key.pem"
}

generate_hy2_credentials() {
  HY2_PASSWORD="${HY2_PASSWORD:-$("$BIN" generate rand 32 --hex)}"
  HY2_OBFS_PASSWORD="${HY2_OBFS_PASSWORD:-$("$BIN" generate rand 32 --hex)}"
  [[ -n "$HY2_PASSWORD" && -n "$HY2_OBFS_PASSWORD" ]] || return 1
  prepare_hy2_tls
}

build_nodes() {
  local rin rout sin sout hin hout
  NEW_INBOUNDS='[]'; CLIENT_OUTBOUNDS='[]'
  if [[ "$MODE" == reality || "$MODE" == both ]]; then
    rin=$(jq -cn --arg addr "$LISTEN_ADDR" --argjson port "$ACTUAL_LISTEN_PORT" --arg uuid "$UUID" --arg sni "$REALITY_SERVER_NAME" --arg dest "$REALITY_DEST_HOST" --argjson dp "$REALITY_DEST_PORT" --arg key "$PRIVATE_KEY" --arg sid "$SHORT_ID" '
      {type:"vless",tag:"hytvless",listen:$addr,listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$dest,server_port:$dp},private_key:$key,short_id:[$sid]}}}') || return 1
    rout=$(jq -cn --arg ip "$SERVER_IP" --argjson port "$LISTEN_PORT" --arg uuid "$UUID" --arg sni "$REALITY_SERVER_NAME" --arg key "$PUBLIC_KEY" --arg sid "$SHORT_ID" '
      {type:"vless",tag:"reality-out",server:$ip,server_port:$port,uuid:$uuid,flow:"xtls-rprx-vision",tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},reality:{enabled:true,public_key:$key,short_id:$sid}}}') || return 1
    NEW_INBOUNDS=$(jq -cn --argjson n "$rin" '[$n]')
    CLIENT_OUTBOUNDS=$(jq -cn --argjson n "$rout" '[$n]')
  fi
  if [[ "$MODE" == ss ]]; then
    sin=$(jq -cn --arg addr "$LISTEN_ADDR" --argjson p "$ACTUAL_LISTEN_PORT" --arg m "$SS_METHOD" --arg pw "$SS_PASSWORD" '{type:"shadowsocks",tag:"hytss",listen:$addr,listen_port:$p,method:$m,password:$pw}') || return 1
    sout=$(jq -cn --arg ip "$SERVER_IP" --argjson p "$LISTEN_PORT" --arg m "$SS_METHOD" --arg pw "$SS_PASSWORD" '{type:"shadowsocks",tag:"ss-out",server:$ip,server_port:$p,method:$m,password:$pw}') || return 1
    NEW_INBOUNDS=$(jq -cn --argjson n "$sin" '[$n]')
    CLIENT_OUTBOUNDS=$(jq -cn --argjson n "$sout" '[$n]')
  fi
  if [[ "$MODE" == hy2 || "$MODE" == both ]]; then
    hin=$(jq -cn --arg addr "$LISTEN_ADDR" --argjson p "$HY2_LISTEN_PORT" --arg pw "$HY2_PASSWORD" --arg obfs "$HY2_OBFS" --arg opw "$HY2_OBFS_PASSWORD" --arg sni "$HY2_SNI" --arg cert "$HY2_CERT" --arg key "$HY2_KEY" --arg masq "$HY2_MASQUERADE_HTML" '
      {type:"hysteria2",tag:"hythy2",listen:$addr,listen_port:$p,users:[{name:"mobile",password:$pw}],ignore_client_bandwidth:true,masquerade:{type:"string",status_code:200,headers:{"content-type":"text/html; charset=utf-8"},content:$masq},tls:{enabled:true,server_name:$sni,alpn:["h3"],certificate_path:$cert,key_path:$key}}
      + (if $obfs=="none" then {} else {obfs:{type:$obfs,password:$opw}} end)') || return 1
    hout=$(jq -cn --arg ip "$SERVER_IP" --argjson ports "$HY2_PORTS_JSON" --argjson count "$HY2_PORT_COUNT" --argjson single "$HY2_SINGLE_PORT" --arg hop "$HY2_HOP_INTERVAL" --arg pw "$HY2_PASSWORD" --arg obfs "$HY2_OBFS" --arg opw "$HY2_OBFS_PASSWORD" --arg sni "$HY2_SNI" --rawfile cert "$HY2_CERT" '
      {type:"hysteria2",tag:"hy2-out",server:$ip,password:$pw,tls:{enabled:true,server_name:$sni,alpn:["h3"],certificate:[$cert]}}
      + (if $count==1 then {server_port:$single} else {server_ports:$ports,hop_interval:$hop} end)
      + (if $obfs=="none" then {} else {obfs:{type:$obfs,password:$opw}} end)') || return 1
    # With a public CA certificate the client trusts system roots, so no pinned certificate is emitted.
    if [[ "$HY2_CERT_MODE" == le ]]; then hout=$(jq -c 'del(.tls.certificate)' <<< "$hout") || return 1; fi
    NEW_INBOUNDS=$(jq -cn --argjson a "$NEW_INBOUNDS" --argjson n "$hin" '$a+[$n]')
    CLIENT_OUTBOUNDS=$(jq -cn --argjson a "$CLIENT_OUTBOUNDS" --argjson n "$hout" '$a+[$n]')
  fi
}

probe_hy2_support() {
  [[ "$MODE" == hy2 || "$MODE" == both ]] || return 0
  local probe="$WORK_DIR/hy2-feature.json"
  # This parses both inbound and client fields with the installed executable.
  # A check failure (including missing with_quic) never triggers core replacement.
  jq -n --argjson ins "$NEW_INBOUNDS" --argjson outs "$CLIENT_OUTBOUNDS" '{inbounds:[$ins[]|select(.type=="hysteria2")],outbounds:[$outs[]|select(.type=="hysteria2")]}' > "$probe" || return 1
  if ! "$BIN" check -c "$probe"; then
    fail "HY2 $HY2_OBFS preflight failed; see the core's diagnostics above. HY2 requires a QUIC-enabled core, and Gecko requires a supporting 1.14+ build. The live core and server config have not been replaced."
    return 1
  fi
  # Probe the duration even for a single advertised port, where no hop is emitted.
  jq --arg hop "$HY2_HOP_INTERVAL" '.outbounds[0] |= (del(.server_port) + {server_ports:["443:444"],hop_interval:$hop})' "$probe" > "$WORK_DIR/hop-check.json" || return 1
  "$BIN" check -c "$WORK_DIR/hop-check.json" || { fail 'HY2_HOP_INTERVAL rejected by sing-box'; return 1; }
  # Core currently accepts some nonpositive durations at parse time; Go duration
  # syntax is validated above, then this numeric check enforces a positive value.
  [[ "$HY2_HOP_INTERVAL" != -* && "$HY2_HOP_INTERVAL" =~ [1-9] ]] || return 1
}

validate_existing_config() {
  [[ ! -e "$CONFIG_FILE" ]] && return 0
  jq -e -s 'length==1 and (.[0] | type=="object" and ((has("inbounds")|not) or (.inbounds|type=="array")) and ((.inbounds // []) | all(.[]; type=="object")))' "$CONFIG_FILE" >/dev/null || {
    fail "Malformed existing config; refusing to overwrite $CONFIG_FILE"; return 1;
  }
}

merge_candidate() {
  # $1 = all selected inbounds; only their exact tags are replaced.
  local nodes="$1" target="$2"
  jq -e 'type=="array" and length>0 and all(.[]; type=="object" and (.tag|type=="string" and length>0)) and (map(.tag)|length==(unique|length))' <<< "$nodes" >/dev/null || return 1
  validate_existing_config || return 1
  if [[ -e "$CONFIG_FILE" ]]; then
    jq --argjson nodes "$nodes" '
      .inbounds = ((.inbounds // [] | map(select(.tag as $tag | any($nodes[]; .tag == $tag) | not))) + $nodes)
    ' "$CONFIG_FILE" > "$target" || return 1
  else
    jq -n --argjson nodes "$nodes" '{log:{level:"warn",output:"/var/log/sing-box.log",timestamp:true},inbounds:$nodes,outbounds:[{type:"direct",tag:"direct"}]}' > "$target" || return 1
  fi
  chmod 600 "$target"
  "$BIN" check -c "$target"
}

commit_candidate() {
  local candidate="$1" old
  CONFIG_BACKUP=''; CONFIG_WAS_PRESENT=0
  if [[ -e "$CONFIG_FILE" ]]; then
    CONFIG_WAS_PRESENT=1
    CONFIG_BACKUP=$(mktemp "$CONFIG_FILE.bak.XXXXXX") || return 1
    cp -p "$CONFIG_FILE" "$CONFIG_BACKUP" || return 1
    chmod 600 "$CONFIG_BACKUP"
    # cp -p keeps the old mtime; refresh it so "newest" really means "latest backup".
    touch "$CONFIG_BACKUP"
    # Backups hold every node credential: keep only the 3 newest.
    ls -1t "$CONFIG_FILE".bak.* 2>/dev/null | tail -n +4 |
      while IFS= read -r old; do rm -f -- "$old"; done || true
  fi
  mv -f "$candidate" "$CONFIG_FILE" || return 1
  CONFIG_COMMITTED=1
}

restart_service() {
  if _cmd systemctl && [[ -d /run/systemd/system ]]; then
    systemctl restart sing-box && sleep 2 && systemctl is-active --quiet sing-box
  elif _cmd rc-service; then
    rc-service sing-box restart && rc-service sing-box status
  else fail 'Neither systemd nor OpenRC is available'; fi
}

start_service() {
  local bin_path="$BIN"
  if [[ "${HY2_RC_DEP:-}" == hy2-hop ]]; then
    # Keep the OpenRC dependency whenever local HY2 forwarding is in use.
    local hy2_need='need net hy2-hop;'
    local hy2_pre='start_pre() { /usr/local/sbin/hy2-hop restore; }'
  else local hy2_need='need net;' hy2_pre=''; fi
  if _cmd systemctl && [[ -d /run/systemd/system ]]; then
    mkdir -p /etc/systemd/system || return 1
    # Keep a one-time copy of a unit we did not create instead of eating it.
    if [[ -f /etc/systemd/system/sing-box.service && ! -e /etc/systemd/system/sing-box.service.pre-installer ]]; then
      cp -p /etc/systemd/system/sing-box.service /etc/systemd/system/sing-box.service.pre-installer || return 1
      _info2 'Existing sing-box unit backed up to sing-box.service.pre-installer'
    fi
    cat > /etc/systemd/system/sing-box.service <<EOF || return 1
[Unit]
Description=sing-box service
After=network.target
[Service]
ExecStart=$bin_path run -c $CONFIG_FILE
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable sing-box || return 1
  else
    if _cmd apk && ! _cmd rc-service; then apk add --no-cache openrc || return 1; fi
    _cmd rc-service || { fail 'OpenRC unavailable'; return 1; }
    mkdir -p /etc/init.d || return 1
    cat > /etc/init.d/sing-box <<EOF || return 1
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy service"
command="$bin_path"
command_args="run -c $CONFIG_FILE"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
depend() { $hy2_need }
$hy2_pre
EOF
    chmod 755 /etc/init.d/sing-box && rc-update add sing-box default || return 1
  fi
  restart_service
}

rollback_config() {
  [[ "${CONFIG_COMMITTED:-0}" == 1 ]] || return 0
  if [[ "$CONFIG_WAS_PRESENT" == 1 ]]; then
    local restore
    restore=$(mktemp "$CONFIG_DIR/.rollback.XXXXXX") || return 1
    cp -p "$CONFIG_BACKUP" "$restore" && mv -f "$restore" "$CONFIG_FILE" || return 1
    _warn2 "Restored previous config from $CONFIG_BACKUP"
    restart_service || _warn2 'Previous config restored but service recovery failed; inspect service logs.'
  else
    rm -f "$CONFIG_FILE"
    if _cmd systemctl && [[ -d /run/systemd/system ]]; then systemctl stop sing-box || true
    elif _cmd rc-service; then rc-service sing-box stop || true; fi
  fi
  CONFIG_COMMITTED=0
}

check_and_open_firewall() {
  local rules='' rule port proto
  case "$MODE" in
    reality|both) rules="$ACTUAL_LISTEN_PORT/tcp" ;;
    ss) rules="$ACTUAL_LISTEN_PORT/tcp $ACTUAL_LISTEN_PORT/udp" ;;
  esac
  if [[ "$MODE" == hy2 || "$MODE" == both ]]; then rules="$rules $HY2_LISTEN_PORT/udp"; fi
  for rule in $rules; do
    port="${rule%/*}"; proto="${rule#*/}"
    if _cmd ufw; then
      local status
      status=$(ufw status) || return 1
      if [[ "$status" == *'Status: active'* ]]; then ufw allow "$port/$proto" || return 1; fi
    fi
    if _cmd firewall-cmd; then
      if firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$port/$proto" && firewall-cmd --add-port="$port/$proto" || return 1
      fi
    fi
  done
  _info2 'Opened selected INTERNAL listener ports only. Provider security groups and NAT must be configured separately.'
}

setup_logrotate() {
  if ! _cmd logrotate; then install_packages logrotate || { _warn2 'logrotate installation failed'; return 1; }; fi
  mkdir -p /etc/logrotate.d
  cat > /etc/logrotate.d/sing-box <<'EOF'
/var/log/sing-box.log {
    daily
    rotate 3
    compress
    maxsize 10M
    missingok
    notifempty
    copytruncate
}
EOF
  if _cmd apk; then
    mkdir -p /etc/periodic/daily
    cat > /etc/periodic/daily/logrotate <<'EOF'
#!/bin/sh
/usr/sbin/logrotate /etc/logrotate.conf
EOF
    chmod 755 /etc/periodic/daily/logrotate
    ensure_crond
  fi
}

full_client_config() {
  # $1 = selected outbound array, $2 = destination. Same mobile TUN/DNS/route
  # layout as the known working profile. PROXY defaults to Reality in both.
  jq -n --argjson nodes "$1" '
    ($nodes | map(.tag)) as $tags |
    {log:{level:"warn",timestamp:true},
     dns:{servers:[{type:"https",tag:"remote-dns",server:"1.1.1.1",server_port:443,path:"/dns-query",detour:"PROXY"}],final:"remote-dns",strategy:"ipv4_only"},
     inbounds:[{type:"tun",tag:"tun-in",interface_name:"tun0",address:["172.19.0.1/30"],mtu:1400,auto_route:true,strict_route:true,stack:"system"}],
     outbounds:([{type:"selector",tag:"PROXY",outbounds:$tags,default:$tags[0]}]+$nodes),
     route:{rules:[{protocol:"dns",action:"hijack-dns"},{port:53,action:"hijack-dns"}],final:"PROXY",auto_detect_interface:true}}
  ' > "$2"
}

prepare_outputs() {
  local tag single name
  mkdir -p "$WORK_DIR/outputs"
  printf '%s\n' "$CLIENT_OUTBOUNDS" | jq . > "$WORK_DIR/outputs/client-outbounds.json"
  full_client_config "$CLIENT_OUTBOUNDS" "$WORK_DIR/outputs/client.json" || return 1
  for tag in reality ss hy2; do
    single=$(jq -c --arg tag "$tag-out" '[.[]|select(.tag==$tag)]' <<< "$CLIENT_OUTBOUNDS") || return 1
    if [[ "$single" != '[]' ]]; then full_client_config "$single" "$WORK_DIR/outputs/client-$tag.json" || return 1; fi
  done
  for name in "$WORK_DIR"/outputs/client.json "$WORK_DIR"/outputs/client-reality.json "$WORK_DIR"/outputs/client-ss.json "$WORK_DIR"/outputs/client-hy2.json; do
    [[ -f "$name" ]] || continue
    "$BIN" check -c "$name" || return 1
    chmod 600 "$name"
  done
  # client-outbounds.json is deliberately an array, not a runnable root config.
  jq -n --argjson nodes "$CLIENT_OUTBOUNDS" '{outbounds:$nodes}' > "$WORK_DIR/outbounds-check.json" || return 1
  "$BIN" check -c "$WORK_DIR/outbounds-check.json" || return 1
  chmod 600 "$WORK_DIR/outputs/client-outbounds.json"
  render_node_output > "$WORK_DIR/outputs/node_output.txt" || return 1
  chmod 600 "$WORK_DIR/outputs/node_output.txt"
}

uri_escape() { jq -rn --arg s "$1" '$s|@uri'; }

render_outbound_snippets() {
  jq --indent 2 '.[]' | sed 's/^/    /; s/^    }$/    },/'
}

render_node_output() {
  local host="$SERVER_IP" link name sni
  [[ "$host" != *:* ]] || host="[$host]"
  name=$(uri_escape "$NODE_NAME")
  printf 'Node: %s\nMode: %s\n' "$NODE_NAME" "$MODE"
  printf '%s\n' 'Rerun behavior: selected protocol tags are replaced and other inbounds are preserved. Re-import the new client profile for the selected protocol.'
  if [[ "$MODE" == reality || "$MODE" == both ]]; then
    sni=$(uri_escape "$REALITY_SERVER_NAME")
    link="vless://$UUID@$host:$LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#$name"
    printf '\nReality URI\n%s\n' "$link"
    printf '\nClash / Mihomo YAML\n'
    # JSON quoted scalars are also valid YAML, including unusual node names.
    jq -r --arg name "$NODE_NAME" '.[]|select(.tag=="reality-out")| "- name: \($name|tojson)\n  type: vless\n  server: \(.server|tojson)\n  port: \(.server_port)\n  uuid: \(.uuid|tojson)\n  flow: xtls-rprx-vision\n  tls: true\n  servername: \(.tls.server_name|tojson)\n  client-fingerprint: chrome\n  reality-opts:\n    public-key: \(.tls.reality.public_key|tojson)\n    short-id: \(.tls.reality.short_id|tojson)\n  network: tcp"' <<< "$CLIENT_OUTBOUNDS"
    # Values only, in outbound key order; boolean flags such as enabled are omitted.
    printf '\nReality plain values\n'
    jq -r '.[]|select(.tag=="reality-out")| .. | scalars | select(type!="boolean")' <<< "$CLIENT_OUTBOUNDS"
  fi
  if [[ "$MODE" == ss ]]; then
    link="ss://$(printf '%s:%s' "$SS_METHOD" "$SS_PASSWORD" | base64 | tr -d '\r\n' | tr '+/' '-_' | tr -d '=')@$host:$LISTEN_PORT#$name"
    printf '\nShadowsocks URI\n%s\n' "$link"
  fi
  if [[ "$MODE" == hy2 || "$MODE" == both ]]; then
    printf '\nHY2 (%s): JSON is authoritative; no universal share URI is emitted.\n' "$HY2_OBFS"
    if [[ "$HY2_CERT_MODE" == le ]]; then
      printf "TLS SNI: %s; Let's Encrypt certificate, validated by the client's system roots.\\n" "$HY2_SNI"
    else
      printf 'TLS SNI: %s; inline certificate trust, no insecure bypass.\n' "$HY2_SNI"
    fi
    printf 'Single internal UDP listener: %s. Public UDP ports: %s.\n' "$HY2_LISTEN_PORT" "$HY2_SERVER_PORTS"
    if [[ ${HY2_PORT_HOPPING_MODE:-external} == local ]]; then
      printf 'Local inet UDP redirect enabled for the advertised ranges only, to UDP %s. Open the ENTIRE UDP range in cloud security groups; no cloud settings changed.\n' "$HY2_LISTEN_PORT"
    else
      printf 'External NAT mode: map EVERY public UDP port to this host UDP %s. No local NAT created.\n' "$HY2_LISTEN_PORT"
    fi
  fi
  printf '\nFull mobile profile for this run: %s/client.json\nPer-protocol profiles: client-reality.json / client-ss.json / client-hy2.json (only selected files updated).\nSelected outbound array: client-outbounds.json\n' "$CONFIG_DIR"
  printf '\nSelected client outbound snippets (remove the final comma if this is the last array item)\n'
  render_outbound_snippets <<< "$CLIENT_OUTBOUNDS"
  if [[ "${SELF_CHECK:-0}" == 1 ]]; then
    printf '\nSelf-check verifies local protocol handshake + HTTPS egress, not public NAT or UDP hopping.\n'
  else
    printf '\nProtocol self-check was skipped (default; SELF_CHECK=1 enables it). Test the node from a client; public NAT and UDP hopping are never verified by the installer.\n'
  fi
}

publish_outputs() {
  local file
  # Unselected inbounds keep their credentials, so keep their client profiles too.
  for file in "$WORK_DIR"/outputs/*; do install -m 600 "$file" "$CONFIG_DIR/${file##*/}" || return 1; done
  cat "$CONFIG_DIR/node_output.txt"
}

stage_shownode() {
  cat > "$WORK_DIR/shownode.py" <<'SHOWNODE_PY'
import base64
import collections
import fcntl
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

CONFIG_DIR = pathlib.Path(sys.argv[1])
CONFIG_FILE = pathlib.Path(sys.argv[2])
REGISTRY = CONFIG_DIR / 'shownode-outbounds.json'
TYPES = {'vless': 'reality', 'shadowsocks': 'ss', 'hysteria2': 'hy2'}
MANAGED = {'hytvless', 'hytss', 'hythy2'}
SAFE_KEYS = {
    'vless': ('server_port', 'uuid', 'flow', 'packet_encoding', 'network', 'tls', 'transport', 'multiplex'),
    'shadowsocks': ('server_port', 'method', 'password', 'plugin', 'plugin_opts', 'network', 'udp_over_tcp', 'multiplex'),
    'hysteria2': ('server_port', 'server_ports', 'hop_interval', 'password', 'tls', 'obfs', 'up_mbps', 'down_mbps', 'network'),
}


def warn(message):
    print('shownode: ' + message, file=sys.stderr)


def read_json(path):
    with path.open(encoding='utf-8') as stream:
        return json.load(stream)


def signature(node):
    return hashlib.sha256(json.dumps(node, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def load_registry():
    try:
        value = read_json(REGISTRY)
    except FileNotFoundError:
        return {}
    if not isinstance(value, dict):
        raise ValueError('invalid node registry')
    return value


def write_entries(entries):
    # Replace atomically, with a private file, and serialize concurrent updates.
    with (CONFIG_DIR / '.shownode.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = load_registry()
        data.update(entries)
        fd, tmp = tempfile.mkstemp(prefix='.shownode.', dir=CONFIG_DIR)
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as stream:
                json.dump(data, stream, ensure_ascii=False, indent=2)
                stream.write('\n')
            os.replace(tmp, REGISTRY)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)


def read_outbounds(path):
    doc = read_json(path)
    if isinstance(doc, dict):
        doc = doc.get('outbounds', [doc])
    if not isinstance(doc, list) or not all(isinstance(out, dict) for out in doc):
        raise ValueError('expected an outbound object, array, or config with an outbounds array')
    return doc


def no_private_keys(value):
    if isinstance(value, str):
        return not re.search(r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----', value)
    if isinstance(value, list):
        return all(no_private_keys(item) for item in value)
    if isinstance(value, dict):
        return all(key not in ('private_key', 'private_key_path', 'key', 'key_path') and no_private_keys(item)
                   for key, item in value.items())
    return True


def client_outbound(out, name):
    kind = out.get('type')
    if kind not in TYPES or not isinstance(name, str) or not name.strip():
        raise ValueError('unsupported outbound type or empty name')
    server = out.get('server')
    if not isinstance(server, str) or not server or any(ch.isspace() for ch in server):
        raise ValueError('outbound has no usable server address')
    port = out.get('server_port')
    ports = out.get('server_ports')
    valid_port = type(port) is int and 1 <= port <= 65535
    valid_ports = kind == 'hysteria2' and isinstance(ports, list) and bool(ports)
    if valid_ports:
        for value in ports:
            if not isinstance(value, str) or not re.fullmatch(r'[0-9]{1,5}:[0-9]{1,5}', value):
                valid_ports = False
                break
            first, last = map(int, value.split(':'))
            if not 1 <= first <= last <= 65535:
                valid_ports = False
                break
    if (ports is not None and (not valid_ports or port is not None)) or (ports is None and not valid_port):
        raise ValueError('outbound has invalid or ambiguous public ports')
    result = {'type': kind, 'tag': name, 'server': server}
    # Preserve the original field order, but omit profile-only routing settings.
    result.update((key, value) for key, value in out.items() if key in SAFE_KEYS[kind])
    if not no_private_keys(result):
        raise ValueError('outbound contains private key material')
    return result


def entry(node, out, name):
    return {'inbound_sha256': signature(node), 'outbound': client_outbound(out, name)}


def reality_public_key(encoded):
    # A raw X25519 private key wrapped in the standard PKCS#8 DER container.
    try:
        raw = base64.urlsafe_b64decode(encoded + '=' * (-len(encoded) % 4))
        if len(raw) != 32:
            return None
        output = subprocess.run(
            ['openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'],
            input=bytes.fromhex('302e020100300506032b656e04220420') + raw,
            capture_output=True, timeout=3, check=True,
        ).stdout
        prefix = bytes.fromhex('302a300506032b656e032100')
        if not output.startswith(prefix) or len(output) != len(prefix) + 32:
            return None
        return base64.urlsafe_b64encode(output[len(prefix):]).decode().rstrip('=')
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def legacy_matches(node, out):
    if out.get('type') != node.get('type'):
        return False
    kind = out['type']
    tls, client_tls = node.get('tls') or {}, out.get('tls') or {}
    if kind == 'vless':
        reality, client_reality = tls.get('reality') or {}, client_tls.get('reality') or {}
        public_key = reality_public_key(reality.get('private_key', '')) if reality.get('enabled') else None
        return (public_key is not None and public_key == client_reality.get('public_key')
                and client_reality.get('enabled') is True and tls.get('enabled') is True and client_tls.get('enabled') is True
                and client_reality.get('short_id') in reality.get('short_id', [])
                and tls.get('server_name') == client_tls.get('server_name')
                and not node.get('transport') and not out.get('transport')
                and any(user.get('uuid') == out.get('uuid') and user.get('flow', '') == out.get('flow', '')
                        for user in node.get('users', []) if user.get('uuid')))
    if kind == 'shadowsocks':
        return (bool(node.get('password')) and node.get('password') == out.get('password')
                and node.get('method') == out.get('method') and not node.get('users')
                and not out.get('plugin'))
    if kind == 'hysteria2':
        cert = tls.get('certificate_path')
        if (not cert or tls.get('enabled') is not True or client_tls.get('enabled') is not True
                or client_tls.get('insecure') or tls.get('server_name') != client_tls.get('server_name')
                or tls.get('alpn', []) != client_tls.get('alpn', [])
                or (node.get('obfs') or {}) != (out.get('obfs') or {})):
            return False
        try:
            with pathlib.Path(cert).open(encoding='ascii') as stream:
                pem = stream.read(65537)
        except (OSError, UnicodeError):
            return False
        return (len(pem) <= 65536 and client_tls.get('certificate') == [pem]
                and any(user.get('password') == out.get('password')
                        for user in node.get('users', []) if user.get('password')))
    return False


def hy2_seconds(value):
    # sing-box durations such as 30s, 5m or 1h become the plain seconds Mihomo expects.
    match = re.fullmatch(r'([0-9]+)([smh])', value or '')
    return int(match.group(1)) * {'s': 1, 'm': 60, 'h': 3600}[match.group(2)] if match else None


def hy2_fingerprint(tls):
    # SHA-256 of the DER certificate, the value Mihomo pins in `fingerprint`.
    pem = (tls.get('certificate') or [''])[0]
    body = ''.join(line.strip() for line in pem.splitlines() if line.strip() and not line.startswith('-----'))
    return hashlib.sha256(base64.b64decode(body)).hexdigest() if body else None


def hy2_yaml(out):
    tls = out.get('tls') or {}
    obfs = out.get('obfs') or {}
    lines = [
        f'  - name: {json.dumps(out["tag"], ensure_ascii=False)}',
        '    type: hysteria2',
        f'    server: {json.dumps(out["server"])}',
    ]
    if 'server_ports' in out:
        ports = ','.join(port.replace(':', '-') for port in out['server_ports'])
        lines.append(f'    ports: {json.dumps(ports)}')
        seconds = hy2_seconds(out.get('hop_interval'))
        if seconds:
            lines.append(f'    hop-interval: {seconds}')
    else:
        lines.append(f'    port: {out["server_port"]}')
    lines.append(f'    password: {json.dumps(out["password"])}')
    if tls.get('server_name'):
        lines.append(f'    sni: {json.dumps(tls["server_name"])}')
    if obfs:
        lines.append(f'    obfs: {obfs["type"]}')
        lines.append(f'    obfs-password: {json.dumps(obfs["password"])}')
    if tls.get('alpn'):
        lines.append('    alpn:')
        lines.extend(f'      - {alpn}' for alpn in tls['alpn'])
    fingerprint = hy2_fingerprint(tls)
    if fingerprint:
        lines.append(f'    fingerprint: {fingerprint}')
    return '\n'.join(lines)


def main(args):
    nodes = [node for node in read_json(CONFIG_FILE).get('inbounds', []) if node.get('type') in TYPES]
    counts = collections.Counter(node.get('tag') for node in nodes)
    tagged = {node['tag']: node for node in nodes if node.get('tag') and counts[node['tag']] == 1}
    if len(args) == 3 and args[0] == '--record-install':
        outs = read_outbounds(pathlib.Path(args[1]))
        entries = {}
        for out in outs:
            tag = {'vless': 'hytvless', 'shadowsocks': 'hytss', 'hysteria2': 'hythy2'}[out['type']]
            name = args[2] if len(outs) == 1 else args[2] + '-' + TYPES[out['type']]
            entries[tag] = entry(tagged[tag], out, name)
        write_entries(entries)
        return
    if len(args) in (3, 4) and args[0] == '--import':
        tag = args[1]
        node = tagged.get(tag)
        if not node:
            raise ValueError('provide an existing, unique server inbound tag')
        matches = [out for out in read_outbounds(pathlib.Path(args[2])) if out.get('type') == node['type']
                   and (len(args) == 3 or out.get('tag') == args[3])]
        if len(matches) != 1:
            raise ValueError('provide exactly one compatible outbound or specify its client tag')
        out = matches[0]
        write_entries({tag: entry(node, out, out.get('tag') or tag)})
        warn('bound existing client outbound to ' + tag)
        return
    if args:
        raise ValueError('usage: shownode [--import INBOUND_TAG CLIENT_JSON [OUTBOUND_TAG]]')
    if not nodes:
        warn('no supported VLESS, Shadowsocks or HY2 inbounds found')
        return
    registry = load_registry()
    legacy_tags = {'reality-in', 'ss-in', 'hy2-in'} | MANAGED
    exported = []
    for node in nodes:
        tag = node.get('tag')
        if tag not in tagged:
            warn('missing or duplicate inbound tag; cannot export')
            continue
        record = registry.get(tag)
        if record and record.get('inbound_sha256') == signature(node):
            out = record['outbound']
            exported.append((tag, client_outbound(out, out['tag'])))
            continue
        # Only fall back to a previous installer profile if it uniquely matches
        # this inbound, including its credentials. Never infer Argo endpoints.
        if tag in legacy_tags:
            try:
                outs = read_outbounds(CONFIG_DIR / ('client-' + TYPES[node['type']] + '.json'))
                matches = [out for out in outs if legacy_matches(node, out)
                           and sum(legacy_matches(other, out) for other in nodes) == 1]
                if len(matches) == 1:
                    exported.append((tag, client_outbound(matches[0], tag)))
                    continue
            except (OSError, ValueError, TypeError, AttributeError):
                pass
        warn(f'{tag}: no verified client settings; use shownode --import to bind an existing client JSON file')
    used = set()
    names = collections.Counter(out['tag'] for _, out in exported)
    hy2_nodes = []
    for tag, out in exported:
        name = out['tag']
        if names[name] != 1:
            name = f'{name} ({tag})'
        while name in used:
            name += '_'
        out['tag'] = name
        used.add(name)
        print('\n'.join('    ' + line for line in json.dumps(out, indent=2, ensure_ascii=False).split('\n')) + ',')
        if out['type'] == 'hysteria2':
            hy2_nodes.append(out)
    if hy2_nodes:
        print('\nClash / Mihomo YAML')
        print('\n'.join(hy2_yaml(out) for out in hy2_nodes))


if __name__ == '__main__':
    os.umask(0o077)
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8', errors='backslashreplace')
    try:
        main(sys.argv[3:])
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        # Avoid dumping input documents or tracebacks containing credentials.
        warn(str(exc) if type(exc) is ValueError else 'could not read or update the node metadata')
        sys.exit(1)
SHOWNODE_PY
  {
    printf '#!/bin/bash\n'
    printf 'exec python3 -I /usr/local/libexec/vps-network-tools/shownode.py %q %q "$@"\n' "$CONFIG_DIR" "$CONFIG_FILE"
  } > "$WORK_DIR/shownode"
}

install_shownode() {
  python3 -I "$WORK_DIR/shownode.py" "$CONFIG_DIR" "$CONFIG_FILE" \
    --record-install "$WORK_DIR/outputs/client-outbounds.json" "$NODE_NAME" || return 1
  install -d -m 755 /usr/local/libexec/vps-network-tools /usr/local/bin &&
    install -m 700 "$WORK_DIR/shownode.py" /usr/local/libexec/vps-network-tools/shownode.py &&
    install -m 700 "$WORK_DIR/shownode" /usr/local/bin/shownode
}

save_install_diagnostics() {
  local stage="$1" report log_path file
  [[ -n "${WORK_DIR:-}" ]] || return 1
  report=$(mktemp "$CONFIG_DIR/install-diagnostics.XXXXXX") || { _warn2 'Could not create a diagnostic file'; return 1; }
  {
    printf 'Stage: %s\nMode: %s\nTime: %s\n' "$stage" "$MODE" "$(date -Is)"
    for file in "$WORK_DIR"/service-start.log "$WORK_DIR"/probe-*.log; do
      [[ -f "$file" ]] || continue
      printf '\n--- %s ---\n' "${file##*/}"
      tail -c 16384 "$file"
    done
    if _cmd ss; then
      printf '\n--- listening UDP sockets ---\n'
      ss -H -lunp 2>&1 | tail -c 8192
    fi
    if _cmd journalctl && [[ -d /run/systemd/system ]]; then
      printf '\n--- sing-box journal since startup attempt ---\n'
      timeout 4 journalctl -u sing-box --since "@${SERVICE_START_EPOCH:-0}" --no-pager -n 60 2>&1 | tail -c 16384
    elif _cmd rc-service; then
      printf '\n--- OpenRC sing-box status ---\n'
      timeout 4 rc-service sing-box status 2>&1 | tail -c 4096
    fi
    log_path=$(jq -r '.log.output // empty' "$CONFIG_FILE" 2>/dev/null) || log_path=''
    if [[ "$log_path" == /var/log/* && "$log_path" != *'/../'* && "$log_path" != "$CONFIG_FILE" && ! -L "$log_path" && -f "$log_path" ]]; then
      printf '\n--- server log tail (may include earlier runs) ---\n'
      tail -c 16384 "$log_path"
    fi
    if [[ -r /sys/fs/cgroup/memory.events ]]; then
      printf '\n--- cgroup memory counters (cumulative) ---\n'
      grep -E '^(oom|oom_kill|oom_group_kill) ' /sys/fs/cgroup/memory.events || true
    fi
  } > "$report" 2>&1
  _warn2 "Private diagnostic log: $report"
}

hy2_check_listener() {
  local addr family pid sockets i
  addr=$(python3 -c 'import ipaddress, sys; print(ipaddress.ip_address(sys.argv[1]))' "$LISTEN_ADDR") || return 1
  case "$addr" in *:*) family=-6 ;; *) family=-4 ;; esac
  for ((i=0; i<8; i++)); do
    if _cmd systemctl && [[ -d /run/systemd/system ]]; then
      pid=$(systemctl show --property=MainPID --value sing-box 2>/dev/null) || pid=''
    else
      pid=''
      if [[ -r /run/sing-box.pid ]]; then read -r pid < /run/sing-box.pid || true; fi
    fi
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
      sockets=$(ss "$family" -H -lunp "sport = :$HY2_LISTEN_PORT" 2>&1) || sockets=''
      if awk -v addr="$addr" -v port="$HY2_LISTEN_PORT" -v owner="pid=$pid," '
        index($0, owner) && ($4==addr ":" port || $4=="[" addr "]:" port || ((addr=="0.0.0.0" || addr=="::") && $4=="*:" port)) {found=1}
        END {exit !found}
      ' <<< "$sockets"; then return 0; fi
      # An IPv6 wildcard socket can also handle IPv4 when IPV6_V6ONLY is off.
      if [[ "$addr" == 0.0.0.0 ]]; then
        sockets=$(ss -6 -H -lunpe "sport = :$HY2_LISTEN_PORT" 2>&1) || sockets=''
        if awk -v port="$HY2_LISTEN_PORT" -v owner="pid=$pid," '
          index($0, owner) && /v6only:0([[:space:]]|$)/ && ($4=="*:" port || $4=="[::]:" port) {found=1}
          END {exit !found}
        ' <<< "$sockets"; then return 0; fi
      fi
    fi
    sleep 1
  done
  return 1
}

start_hy2_fixture() (
  # Run directly as the child we will stop, with no extra shell process.
  exec python3 -I - "$1" "$2" <<'PY'
import http.server
import pathlib
import sys

ready, token = sys.argv[1:]

class Probe(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/' + token:
            self.send_error(404)
            return
        body = token.encode('ascii')
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

with http.server.HTTPServer(('127.0.0.1', 0), Probe) as server:
    port_file = pathlib.Path(ready + '.tmp')
    port_file.write_text(str(server.server_port) + '\n', encoding='ascii')
    port_file.replace(ready)
    server.serve_forever()
PY
)

probe_socks_ready() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

self_check_node() (
  # Subshell EXIT trap keeps diagnostic logs but stops both probe processes.
  local node="$1" tag port listener target conf log pid='' fixture_pid='' i code='' ready=0
  local fixture_ready fixture_port token response egress_log
  tag=$(jq -r '.tag' <<< "$node")
  # The self-check pins the installed certificate, so it works even without a CA bundle on the VPS.
  if [[ "$tag" == hy2-out && "$HY2_CERT_MODE" == le ]]; then node=$(jq --rawfile pin "$HY2_CERT" '.tls.certificate=[$pin]' <<< "$node") || exit 1; fi
  port=$((20000 + RANDOM % 30000))
  listener="$ACTUAL_LISTEN_PORT"
  [[ "$tag" != hy2-out ]] || listener="$HY2_LISTEN_PORT"
  target="$LISTEN_ADDR"
  case "$target" in 0.0.0.0) target=127.0.0.1 ;; ::) target=::1 ;; esac
  conf=$(mktemp "$WORK_DIR/selfcheck.XXXXXX") || exit 1
  log="$WORK_DIR/probe-$tag-client.log"
  egress_log="$WORK_DIR/probe-$tag-http.log"
  trap '
    for child in "$pid" "$fixture_pid"; do
      if [[ -n "$child" ]]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
    done
    rm -f "$conf"
  ' EXIT
  jq -n --argjson node "$node" --arg target "$target" --argjson listener "$listener" --argjson port "$port" '
    {log:{level:"warn"},inbounds:[{type:"socks",listen:"127.0.0.1",listen_port:$port}],outbounds:[($node|del(.server_ports,.hop_interval)|.server=$target|.server_port=$listener)],route:{final:$node.tag}}' > "$conf" || exit 1
  if ! "$BIN" check -c "$conf" > "$log" 2>&1; then
    _err2 "$tag: temporary client config check failed; protocol and egress not tested."
    exit 1
  fi
  "$BIN" run -c "$conf" >> "$log" 2>&1 & pid=$!
  for ((i=0; i<12; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    if probe_socks_ready "$port" && kill -0 "$pid" 2>/dev/null; then ready=1; break; fi
    sleep 1
  done
  if [[ "$ready" != 1 ]]; then
    if kill -0 "$pid" 2>/dev/null; then
      printf '%s\n' 'Temporary client was running but its SOCKS socket was not ready.' >> "$log"
    else
      if wait "$pid" 2>/dev/null; then code=0; else code=$?; fi
      pid=''
      printf 'Temporary client exited with status %s\n' "$code" >> "$log"
    fi
    _err2 "$tag: temporary SOCKS client did not start; protocol and egress not tested."
    exit 1
  fi
  if [[ "$tag" == hy2-out ]]; then
    fixture_ready="$conf.fixture-port"
    token=$(openssl rand -hex 16) || exit 1
    start_hy2_fixture "$fixture_ready" "$token" > "$WORK_DIR/probe-hy2-fixture.log" 2>&1 & fixture_pid=$!
    for ((i=0; i<20; i++)); do
      [[ ! -s "$fixture_ready" ]] || break
      kill -0 "$fixture_pid" 2>/dev/null || break
      sleep 0.1
    done
    if ! read -r fixture_port < "$fixture_ready" || [[ ! "$fixture_port" =~ ^[1-9][0-9]{0,4}$ ]]; then
      _err2 'HY2 [2/3] 本机握手未验证：临时回环测试服务未启动。'
      exit 1
    fi
    if ! response=$(curl -q --noproxy '' -fsS --connect-timeout 3 -m 8 -x "socks5h://127.0.0.1:$port" \
      "http://127.0.0.1:$fixture_port/$token" 2>> "$egress_log") || [[ "$response" != "$token" ]]; then
      _err2 'HY2 [2/3] 本机握手 / 认证 / 数据转发测试失败；未测试外网。'
      exit 1
    fi
    _ok2 'HY2 [2/3] 本机握手、认证与数据转发通过。'
  fi
  for target in https://www.google.com/generate_204 https://cloudflare.com/cdn-cgi/trace https://www.baidu.com/favicon.ico; do
    printf '\nHTTPS target: %s\n' "$target" >> "$egress_log"
    code=$(curl -q --noproxy '' -sS --connect-timeout 5 -m 15 -x "socks5h://127.0.0.1:$port" -o /dev/null -w '%{http_code}' "$target" 2>> "$egress_log") || code=''
    printf 'HTTP status: %s\n' "${code:-unavailable}" >> "$egress_log"
    if [[ "$code" == 200 || "$code" == 204 ]]; then
      if [[ "$tag" == hy2-out ]]; then _ok2 'HY2 [3/3] 通过 HY2 访问外网 HTTPS 成功。'
      else _ok2 "$tag handshake + HTTPS egress passed"; fi
      exit 0
    fi
  done
  if [[ "$tag" == hy2-out ]]; then
    _warn2 'HY2 [3/3] 外网 HTTPS 检查未通过；本机测试已通过，不回滚。'
    save_install_diagnostics 'hy2-external-https' || true
    exit 0
  fi
  _err2 "$tag handshake + HTTPS egress check failed."
  exit 1
)

self_check() {
  local node
  while IFS= read -r node; do self_check_node "$node" || return 1; done < <(jq -c '.[]' <<< "$CLIENT_OUTBOUNDS")
}

enable_pubkey_auth() {
  local conf=/etc/ssh/sshd_config bk tmp effective
  [[ -s "$SSH_DIR/authorized_keys" ]] || { _warn2 'No authorized_keys; PubkeyAuthentication left unchanged.'; return 0; }
  effective=$(sshd -T -f "$conf" 2>/dev/null | awk '$1=="pubkeyauthentication" {print $2; exit}') || true
  [[ "$effective" != yes ]] || return 0
  [[ -f "$conf" && ! -L "$conf" ]] || return 1
  bk="$conf.bak-$(date +%Y%m%d%H%M%S)"
  cp -p "$conf" "$bk" || return 1
  tmp=$(mktemp /etc/ssh/.pubkey.XXXXXX) || return 1
  { printf '%s\n' 'PubkeyAuthentication yes'; sed -E '/^[[:space:]]*PubkeyAuthentication[[:space:]]/d' "$conf"; } > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$conf"; rm -f "$tmp"
  if ! sshd -t -f "$conf" || [[ $(sshd -T -f "$conf" | awk '$1=="pubkeyauthentication" {print $2; exit}') != yes ]]; then
    cp -p "$bk" "$conf"; _warn2 'PubkeyAuthentication change failed; sshd_config restored.'; return 1
  fi
  if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then systemctl restart ssh || systemctl restart sshd
  elif command -v rc-service >/dev/null; then rc-service sshd restart || rc-service ssh restart
  elif command -v service >/dev/null; then service ssh restart || service sshd restart
  else _warn2 'Cannot restart sshd; restart it manually to apply PubkeyAuthentication.'; return 1; fi
  _info2 "PubkeyAuthentication enabled; sshd_config backup: $bk"
}

setup_ssh_key() {
  local key="$SSH_DIR/id_ed25519" pub="$SSH_DIR/id_ed25519.pub" auth="$SSH_DIR/authorized_keys" fresh backup derived public_line
  mkdir -p "$SSH_DIR" || return 1
  chmod 700 "$SSH_DIR" || return 1
  if ! _cmd ssh-keygen; then
    _warn2 'ssh-keygen unavailable; preserving all SSH files unchanged.'
    return 0
  fi
  if [[ "${SSH_KEY_REGENERATE:-0}" == 1 ]]; then
    backup=$(mktemp -d "$SSH_DIR/key-backup.XXXXXX") || return 1
    chmod 700 "$backup"
    [[ ! -e "$key" ]] || cp -p "$key" "$backup/id_ed25519" || return 1
    [[ ! -e "$pub" ]] || cp -p "$pub" "$backup/id_ed25519.pub" || return 1
    fresh=$(mktemp -d "$SSH_DIR/new-key.XXXXXX") || return 1
    ssh-keygen -q -t ed25519 -f "$fresh/id_ed25519" -N '' -C "root@$(hostname)" || { rm -rf "$fresh"; return 1; }
    mv -f "$fresh/id_ed25519" "$key" && mv -f "$fresh/id_ed25519.pub" "$pub" || return 1
    rmdir "$fresh"
    _info2 "Old SSH key files backed up in $backup; all authorized_keys entries retained."
  elif [[ -e "$key" && ! -e "$pub" ]]; then
    # Never overwrite/delete a standalone private key, including encrypted keys.
    derived=$(ssh-keygen -y -P '' -f "$key" </dev/null 2>/dev/null) || {
      _warn2 'Cannot derive public key (possibly encrypted); existing private key preserved.'; return 0;
    }
    printf '%s\n' "$derived" > "$pub" || return 1
  elif [[ ! -e "$key" && ! -e "$pub" ]]; then
    ssh-keygen -q -t ed25519 -f "$key" -N '' -C "root@$(hostname)" || return 1
  fi
  if [[ -s "$pub" ]]; then
    public_line=$(cat "$pub")
    if ! grep -qxF "$public_line" "$auth" 2>/dev/null; then
      # Ensure a previous unterminated line cannot absorb the appended key.
      [[ ! -s "$auth" ]] || printf '\n' >> "$auth"
      printf '%s\n' "$public_line" >> "$auth" || return 1
    fi
    chmod 600 "$pub" "$auth" || return 1
  fi
  if [[ -f "$key" ]]; then
    chmod 600 "$key" || return 1
    if [[ "${SSH_KEY_DELETE:-0}" == 1 ]]; then
      cat "$key" && rm -f "$key" || return 1
      _warn2 'Private key displayed and removed by explicit SSH_KEY_DELETE=1.'
    else _info2 "SSH key preserved: $key. Use sshkey to view; sshkey --delete explicitly removes only that private key."; fi
  fi
}

setup_alias() {
  cat > /usr/local/bin/closepwd <<'CLOSEPWD'
#!/bin/bash
# Explicit opt-in only. Keep the current SSH session open throughout.
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run closepwd as root.' >&2; exit 1; }
conf=/etc/ssh/sshd_config
[[ -f "$conf" && ! -L "$conf" ]] || { echo 'Missing or symlinked sshd_config; refusing changes.' >&2; exit 1; }
command -v sshd >/dev/null || { echo 'sshd not found.' >&2; exit 1; }
sshd -t -f "$conf" || exit 1
# sshd -T -C evaluates Match for the actual SSH connection. Refuse all
# configured Match blocks (including Includes) rather than claiming that a
# global setting closes password access for every user/address.
debug=$(sshd -T -ddd -f "$conf" 2>&1) || { echo 'Cannot inspect SSH configuration.' >&2; exit 1; }
if grep -Eiq 'checking (syntax for .match|match for)' <<< "$debug"; then
  echo 'SSH configuration contains Match rules; refusing automatic modification. Review all included files manually.' >&2
  exit 1
fi
effective=$(sshd -T -f "$conf") || exit 1
[[ $(awk '$1=="pubkeyauthentication" {print $2; exit}' <<< "$effective") == yes ]] || { echo 'Public key authentication is not enabled; refusing.' >&2; exit 1; }
echo 'Only continue after independently verifying a NEW SSH login with your private key.'
echo 'Keep this session open. This changes SSH authentication for the server.'
read -r -p 'Type CLOSE to continue: ' confirm
[[ "$confirm" == CLOSE ]] || { echo 'Cancelled; no changes made.'; exit 1; }
backup=$(mktemp -d /etc/ssh/closepwd-backup.XXXXXX)
chmod 700 "$backup"
cp -p "$conf" "$backup/sshd_config"
tmp=$(mktemp /etc/ssh/.closepwd.XXXXXX)
restart_ssh() {
  if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    systemctl restart ssh || systemctl restart sshd
  elif command -v rc-service >/dev/null; then rc-service sshd restart || rc-service ssh restart
  elif command -v service >/dev/null; then service ssh restart || service sshd restart
  else return 1; fi
}
rollback() {
  echo "Failed; restoring SSH configuration from $backup. Keep this session open." >&2
  cp -p "$backup/sshd_config" "$conf" || { echo 'CRITICAL: restore failed; repair SSH manually.' >&2; return 1; }
  sshd -t -f "$conf" && restart_ssh || { echo 'CRITICAL: could not verify or restart restored SSH; repair manually.' >&2; return 1; }
}
# Put global settings first, before any Include or Match. Preserve existing content.
{ printf '%s\n' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no'; cat "$conf"; } > "$tmp"
if ! cat "$tmp" > "$conf"; then rm -f "$tmp"; rollback || true; exit 1; fi
rm -f "$tmp"
if ! sshd -t -f "$conf"; then rollback || true; exit 1; fi
effective=$(sshd -T -f "$conf") || { rollback || true; exit 1; }
if [[ $(awk '$1=="passwordauthentication" {print $2; exit}' <<< "$effective") != no || $(awk '$1=="kbdinteractiveauthentication" {print $2; exit}' <<< "$effective") != no || $(awk '$1=="pubkeyauthentication" {print $2; exit}' <<< "$effective") != yes ]]; then
  echo 'Effective global SSH settings failed verification.' >&2; rollback || true; exit 1
fi
if ! restart_ssh; then rollback || true; exit 1; fi
echo "SSH restarted; backup: $backup/sshd_config"
echo 'Global defaults verified. Match blocks may override them: verify your actual connection with sshd -T -C and test a new login before closing this session.'
CLOSEPWD
  chmod 700 /usr/local/bin/closepwd
  cat > /usr/local/bin/sshkey <<'EOF'
#!/bin/sh
KEY=/root/.ssh/id_ed25519
[ -f "$KEY" ] || { printf '%s\n' 'No retained private key.'; exit 0; }
cat "$KEY" || exit 1
case "${1:-}" in
  --delete) rm -f "$KEY" ;;
  '') printf '%s\n' 'Private key retained. After saving it, sshkey --delete explicitly removes this private key only.' ;;
  *) printf '%s\n' 'Usage: sshkey [--delete]' >&2; exit 1 ;;
esac
EOF
  chmod 755 /usr/local/bin/sshkey
  local rc line
  for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    touch "$rc"
    for line in "alias shownode='/usr/local/bin/shownode'" "alias sshkey='sh /usr/local/bin/sshkey'" "alias showsshkey='sh /usr/local/bin/sshkey'" "alias log='tail -n 100 /var/log/sing-box.log'"; do
      grep -qxF "$line" "$rc" || printf '%s\n' "$line" >> "$rc"
    done
  done
}

# Local hopping uses nftables only; never changes host traffic queues.
hy2_hop_prepare() {
  HY2_HOP_ACTIVE=0
  # Old network state must be reviewed explicitly; never delete host queues.
  if [[ -e /etc/hy2-limit/state.json || -e /run/hy2-limit-live.json || -e /etc/systemd/system/sing-box.service.d/hy2-limit.conf ]]; then
    fail 'Legacy networking integration detected; restore/review the previous installation before retrying. No host queues changed.'; return 1
  fi
  local state=/etc/hy2-hop/state.json
  HY2_RC_DEP=''
  if [[ "$MODE" != hy2 && "$MODE" != both ]]; then
    if [[ -e "$state" ]]; then
      # This run leaves HY2 untouched; keep the existing boot integration.
      [[ -x /usr/local/sbin/hy2-hop && -f "$CONFIG_FILE" ]] &&
        jq -e --arg config "$CONFIG_FILE" --slurpfile live "$CONFIG_FILE" '
          .port as $port | .config==$config and .hop.mode=="local" and
          any($live[0].inbounds[]?; .type=="hysteria2" and .listen_port==$port)
        ' "$state" >/dev/null || { fail 'Existing HY2 forwarding does not match the live config; review it before installing another protocol'; return 1; }
      HY2_RC_DEP=hy2-hop
    fi
    return 0
  fi
  if [[ -e "$state" ]]; then
    [[ "$HY2_PORT_HOPPING_MODE" == local && -f "$CONFIG_FILE" ]] &&
      jq -e --arg config "$CONFIG_FILE" --slurpfile live "$CONFIG_FILE" '
        .port as $port | .config==$config and .hop.mode=="local" and
        any($live[0].inbounds[]?; .type=="hysteria2" and .tag=="hythy2" and .listen_port==$port)
      ' "$state" >/dev/null || { fail 'Existing local forwarding must belong to hythy2 and remain local; review it before changing HY2'; return 1; }
  fi
  [[ "$HY2_PORT_HOPPING_MODE" == local ]] || return 0
  _cmd nft || install_packages nftables
  _cmd ip || install_packages iproute2
  _cmd flock || install_packages util-linux
  if _cmd systemctl && [[ -d /run/systemd/system ]]; then HY2_HOP_INIT=systemd
  elif _cmd rc-service && _cmd rc-update; then HY2_HOP_INIT=openrc
  else fail 'Local hopping requires systemd or OpenRC'; return 1; fi
  HY2_HOP_ACTIVE=1
}

hy2_hop_install() {
  [[ "${HY2_HOP_ACTIVE:-0}" == 1 ]] || return 0
  cat > "$WORK_DIR/hy2-hop" <<'HY2_HOP_HELPER'
#!/bin/bash
set -euo pipefail
umask 077
D=/etc/hy2-hop
STATE=$D/state.json
NAT_STATE=$D/nat.json
TABLE=hy2_hopping
err() { printf '[hy2-hop] %s\n' "$*" >&2; return 1; }
iface_valid() { [[ "$1" =~ ^[a-zA-Z0-9_.:-]{1,15}$ && "$1" != lo && "$1" != -* ]]; }
secure() { [[ ! -L "$1" && $(stat -c %u "$1") == 0 && $(stat -c %a "$1") == "$2" ]]; }
put() { local tmp; tmp=$(mktemp "$D/.write.XXXXXX") || return 1; printf '%s\n' "$2" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$1"; }
intervals() {
  jq -ce '
    def port: type=="number" and floor==. and .>=1 and .<=65535;
    if type!="array" or length==0 or length>1024 or (all(.[]; type=="array" and length==2 and (.[0]|port) and (.[1]|port) and .[0]<=.[1])|not) then error("invalid intervals") else
    sort_by(.[0],.[1]) | reduce .[] as $x ([]; if length>0 and $x[0]<=.[-1][1]+1 then .[-1][1]=([.[-1][1],$x[1]]|max) else .+[$x] end) |
    if length>64 then error("more than 64 disjoint HY2 intervals") else . end end'
}
hop_load() {
  HOP=$(jq -c '.hop // {mode:"external",ports:[],iface:""}' <<< "$OLD")
  jq -e '.mode=="external" or .mode=="local"' <<< "$HOP" >/dev/null || return 1
  if [[ $(jq -r .mode <<< "$HOP") == local ]]; then
    iface_valid "$(jq -r .iface <<< "$HOP")" || return 1
    [[ $(jq -c .ports <<< "$HOP" | intervals) == "$(jq -c .ports <<< "$HOP")" ]] || return 1
  else jq -e '.mode=="external" and (.ports|type=="array" and length==0) and ((.iface // "")=="")' <<< "$HOP" >/dev/null || { err 'Invalid external hopping state'; return 1; }; fi
}

# Normalize only a redundant UDP equality when the SAME rule already
# contains a UDP destination-port match. All other objects remain significant.
nat_canonical() {
  jq -Sc '
    map(if has("rule") then
      .rule.expr |= (
        if any(.[]; .match.left.payload.protocol?=="udp" and .match.left.payload.field?=="dport") then
          map(select(. != {match:{op:"==",left:{meta:{key:"l4proto"}},right:"udp"}}))
        else . end)
    else . end)'
}
nat_expected() {
  jq -Scn --arg t "$TABLE" --argjson hop "$HOP" --argjson p "$PORT" '
    if $hop.mode!="local" then [] else
    [{table:{family:"inet",name:$t,comment:"hy2-hop v2 owned"}},
     {chain:{family:"inet",table:$t,name:"prerouting",type:"nat",hook:"prerouting",prio:-100,policy:"accept",comment:"hy2-hop v2 owned"}}] +
    [$hop.ports[] | {rule:{family:"inet",table:$t,chain:"prerouting",comment:"hy2-hop v2 owned",expr:[
      {match:{op:"==",left:{meta:{key:"iifname"}},right:$hop.iface}},
      {match:{op:"==",left:{fib:{result:"type",flags:["daddr"]}},right:"local"}},
      {match:{op:"==",left:{meta:{key:"l4proto"}},right:"udp"}},
      {match:{op:"==",left:{payload:{protocol:"udp",field:"dport"}},right:(if .[0]==.[1] then .[0] else {range:.} end)}},
      {redirect:{port:$p}}]}}] end' | nat_canonical
}
nat_snapshot() {
  local rules
  rules=$(nft -j list ruleset) || { err 'Cannot inspect nftables/CAP_NET_ADMIN'; return 1; }
  jq -Sce --arg t "$TABLE" '[.nftables[] | select(to_entries|any(.[]; .value.family=="inet" and (.value.table==$t or (.key=="table" and .value.name==$t)))) | walk(if type=="object" then del(.handle,.index) else . end)]' <<< "$rules" | nat_canonical
}
nat_owned() {
  local actual
  actual=$(nat_snapshot) || return 1
  if [[ -e "$NAT_STATE" || -L "$NAT_STATE" ]]; then
    secure "$NAT_STATE" 600 || return 1
    [[ "$actual" == '[]' || "$actual" == "${NAT_MEMORY:-}" || "$actual" == "$(nat_canonical < "$NAT_STATE")" ]] || { err 'Unknown/modified HY2 nft table: refusing replacement'; return 1; }
    # A missing table may be a reboot; a nonempty table needs the complete saved fingerprint.
  else [[ "$actual" == '[]' ]] || { err 'Foreign same-name nft table; no ownership fingerprint'; return 1; }; fi
}
nat_apply() {
  local actual expected batch
  nat_owned || return 1
  actual=$(nat_snapshot) || return 1
  expected=$(nat_expected) || return 1
  if [[ "$actual" == "$expected" ]]; then
    # A failed atomic apply may leave old rules with the intended new fingerprint file.
    if [[ -e "$NAT_STATE" || "$expected" != '[]' ]]; then put "$NAT_STATE" "$expected" || return 1; fi
    return 0
  fi
  if [[ "$expected" != '[]' ]]; then no_local_nat || return 1; fi
  batch=$(jq -cn --arg t "$TABLE" --argjson a "$actual" --argjson e "$expected" '
    {nftables:((if $a|length>0 then [{delete:{table:{family:"inet",name:$t}}}] else [] end) + ($e|map({add:.})))}') || return 1
  # Check-only and apply are both permission/capability gates; inet NAT needs Linux >=5.2.
  nft -c -j -f /dev/stdin <<< "$batch" || { err 'Local inet redirect unavailable: need nftables, Linux >=5.2 and CAP_NET_ADMIN; no kernel upgrade attempted'; return 1; }
  # Persist INTENDED content first: never claim an arbitrary post-apply snapshot.
  NAT_MEMORY=$actual
  put "$NAT_STATE" "$expected" || return 1
  nft -j -f /dev/stdin <<< "$batch" || return 1
  [[ $(nat_snapshot) == "$expected" ]] || { err 'nft post-apply fingerprint mismatch'; return 1; }
  NAT_MEMORY=$expected
}

choose_iface() {
  local routes names
  if [[ -n "$1" ]]; then IFACE=$1
  else
    routes=$(ip -j -4 route show table all default) || return 1
    names=$(ip -j -6 route show table all default) || return 1
    names=$(jq -rn --argjson a "$routes" --argjson b "$names" '[$a[],$b[]] | if any(.[]; has("nexthops") or (.type // "unicast")!="unicast") then error("multipath/unsupported default route") else map(.dev // error("default route without dev")) | unique | .[] end') || return 1
    [[ -n "$names" && "$names" != *$'\n'* ]] || { err 'Ambiguous/missing default interface; set HY2_HOPPING_INTERFACE explicitly'; return 1; }
    IFACE=$names
    if [[ ${PUBLIC_IFACE_ONLY:-0} == 1 ]]; then
    local addresses
    addresses=$(ip -j address show dev "$IFACE") || return 1
    jq -e 'any(.[].addr_info[]?; .scope=="global" and ((.family=="inet6" and (.local|test("^[23]"))) or (.family=="inet" and (.local|test("^(10\\.|127\\.|169\\.254\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.)")|not))))' <<< "$addresses" >/dev/null || { err 'Automatic interface is private/unclear; explicitly set HY2_HOPPING_INTERFACE'; return 1; }
    fi
  fi
  iface_valid "$IFACE" || { err 'Invalid interface'; return 1; }
  ip -j link show dev "$IFACE" | jq -e 'length==1 and (.[0].flags|index("UP"))!=null' >/dev/null || { err 'Interface missing/down'; return 1; }
}

no_local_nat() {
  local rules
  rules=$(nft -j list ruleset) || return 1
  nat_owned || return 1
  jq -e --arg t "$TABLE" '[.nftables[] | .chain? | select(.type=="nat" and (.family!="inet" or .table!=$t))] | length==0' <<< "$rules" >/dev/null || { err 'Third-party NAT rules present; refusing local forwarding'; return 1; }
}
main() {
  [[ $(id -u) == 0 ]] || return 1
  if [[ ${1:-} == probe-interface ]]; then PUBLIC_IFACE_ONLY=1; choose_iface "${2:-}"; printf '%s\n' "$IFACE"; return; fi
  [[ ! -L "$D" ]] || return 1
  mkdir -p "$D"; chmod 700 "$D"
  secure "$D" 700 || return 1
  [[ ! -L "$D/lock" ]] || return 1
  exec 9>"$D/lock"; flock -x 9
  if [[ ${1:-} == configure ]]; then
    [[ $# == 4 ]] || return 1
    PORT=$2; HOP=$3; CONFIG=$4
    [[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( PORT<=65535 )) || return 1
    OLD=$(jq -cn --argjson hop "$HOP" '{hop:$hop}')
    hop_load || return 1
    local prior='null' previous_port=$PORT previous_hop=$HOP
    if [[ -e "$STATE" ]]; then secure "$STATE" 600 || return 1; prior=$(jq -ce . "$STATE") || return 1; fi
    if ! nat_apply; then
      HOP=$(jq -c '.hop // {mode:"external",ports:[],iface:""}' <<< "$prior")
      PORT=$(jq -r '.port // 1' <<< "$prior")
      nat_apply || err 'Forwarding recovery failed; inspect the owned nft table before retrying'
      return 1
    fi
    if ! put "$STATE" "$(jq -cn --argjson port "$PORT" --argjson hop "$HOP" --arg config "$CONFIG" '{port:$port,hop:$hop,config:$config}')"; then
      HOP=$(jq -c '.hop // {mode:"external",ports:[],iface:""}' <<< "$prior")
      PORT=$(jq -r '.port // 1' <<< "$prior")
      nat_apply || err 'Forwarding recovery failed; inspect the owned nft table before retrying'
      return 1
    fi
  elif [[ ${1:-} == restore ]]; then
    [[ -e "$STATE" ]] || return 0
    secure "$STATE" 600 || return 1
    OLD=$(jq -ce . "$STATE"); hop_load || return 1
    PORT=$(jq -er .port <<< "$OLD"); CONFIG=$(jq -er .config <<< "$OLD")
    jq -e --argjson p "$PORT" 'any(.inbounds[]?; .type=="hysteria2" and .listen_port==$p)' "$CONFIG" >/dev/null || return 1
    choose_iface "$(jq -r .iface <<< "$HOP")" || return 1
    nat_apply
  else err 'Usage: hy2-hop restore'; fi
}
main "$@"
HY2_HOP_HELPER
  local iface
  iface=$(bash "$WORK_DIR/hy2-hop" probe-interface "${HY2_HOPPING_INTERFACE:-}") || return 1
  HY2_HOP_JSON=$(jq -cn --arg i "$iface" --argjson p "$HY2_INTERVALS_JSON" '{mode:"local",ports:$p,iface:$i}') || return 1
  mkdir -p /usr/local/sbin
  install -m 700 "$WORK_DIR/hy2-hop" /usr/local/sbin/hy2-hop
  if [[ "$HY2_HOP_INIT" == systemd ]]; then
    mkdir -p /etc/systemd/system/sing-box.service.d
    cat > /etc/systemd/system/hy2-hop.service <<'HOP_UNIT'
[Unit]
Description=HY2 local UDP forwarding
After=network-online.target
Wants=network-online.target
Before=sing-box.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hy2-hop restore
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
HOP_UNIT
    cat > /etc/systemd/system/sing-box.service.d/hy2-hop.conf <<'HOP_DROP'
[Unit]
Requires=hy2-hop.service
After=hy2-hop.service
[Service]
ExecStartPre=/usr/local/sbin/hy2-hop restore
HOP_DROP
    systemctl daemon-reload && systemctl enable hy2-hop.service
  else
    cat > /etc/init.d/hy2-hop <<'HOP_RC'
#!/sbin/openrc-run
name="hy2-hop"
depend() { need net; before sing-box; }
start() { /usr/local/sbin/hy2-hop restore; }
stop() { return 0; }
HOP_RC
    chmod 755 /etc/init.d/hy2-hop
    rc-update add hy2-hop default
    HY2_RC_DEP=hy2-hop
  fi
}

# Applied only after the self-check passes, so a failed install never leaves NAT rules or state behind.
hy2_hop_configure() {
  [[ "${HY2_HOP_ACTIVE:-0}" == 1 ]] || return 0
  /usr/local/sbin/hy2-hop configure "$HY2_LISTEN_PORT" "$HY2_HOP_JSON" "$CONFIG_FILE"
}

cleanup_installer() {
  local status=$?
  trap - EXIT
  if [[ "${CONFIG_COMMITTED:-0}" == 1 && "${CONFIG_ACCEPTED:-0}" != 1 ]]; then rollback_config || true; fi
  [[ -z "${WORK_DIR:-}" ]] || rm -rf "$WORK_DIR"
  [[ -z "${CORE_STAGE_DIR:-}" ]] || rm -rf "$CORE_STAGE_DIR"
  exit "$status"
}

restart_detached() {
  # Restore any unaccepted config before re-execution rotates node credentials.
  trap '' HUP
  if [[ "${CONFIG_COMMITTED:-0}" == 1 && "${CONFIG_ACCEPTED:-0}" != 1 ]]; then rollback_config || true; fi
  INSTALL_DAEMONIZED=1 nohup bash "${BASH_SOURCE[0]}" </dev/null >> "$INSTALL_LOG" 2>&1 &
  printf '[*] Continuing in background; log: %s\n' "$INSTALL_LOG" >&2 || true
  exit 0
}

# Interactive setup, the only flow. Answers are exported under the variable names the
# installer uses, so the detached rerun (INSTALL_DAEMONIZED=1) inherits them and never prompts.
WIZARD_INPUT="${WIZARD_INPUT:-/dev/tty}"

has_terminal() { { : < "$WIZARD_INPUT"; } 2>/dev/null; }

ask_line() {
  # ask_line PROMPT DEFAULT -> ANSWER. Enter accepts DEFAULT.
  local line
  if [[ -n "$2" ]]; then printf '%s [%s]: ' "$1" "$2" >&2; else printf '%s: ' "$1" >&2; fi
  IFS= read -r -u 3 line || { fail '没有终端输入，无法交互；请在终端中运行脚本'; exit 1; }
  ANSWER="${line:-$2}"
}

ask_valid() {
  # ask_valid PROMPT DEFAULT CHECK -> ANSWER. CHECK prints the accepted value or fails.
  local out
  while :; do
    ask_line "$1" "$2"
    if out=$("$3" "$ANSWER"); then ANSWER="$out"; return 0; fi
  done
}

check_mode() {
  case "$1" in
    1) printf 'reality\n' ;;
    2) printf 'ss\n' ;;
    3) printf 'hy2\n' ;;
    4) printf 'both\n' ;;
    *) fail '请输入 1-4'; return 1 ;;
  esac
}

check_server_ip() { validate_host "$1" SERVER_IP && printf '%s\n' "$1"; }

check_reality_name() {
  if [[ -n "$1" ]]; then validate_host "$1" REALITY_SERVER_NAME || return 1; fi
  printf '%s\n' "$1"
}

check_method() {
  case "$1" in
    aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305) printf '%s\n' "$1" ;;
    *) fail '支持: aes-128-gcm, aes-256-gcm, chacha20-ietf-poly1305'; return 1 ;;
  esac
}

check_hy2_ports() { ( normalize_hy2_ports "$1" ) && printf '%s\n' "$1"; }

hy2_confirmation() {
  local public_ports
  public_ports=$(jq -r 'map(if .[0]==.[1] then (.[0]|tostring) else "\(.[0])-\(.[1])" end) | join(",")' <<< "$HY2_INTERVALS_JSON") || return 1
  printf 'HY2 本机监听：%s/UDP\n' "$HY2_LISTEN_PORT"
  printf 'HY2 客户端连接 / 云安全组应放行的公网端口：%s（UDP）\n' "$public_ports"
  if (( HY2_PORT_COUNT == 1 )); then
    if [[ "$HY2_LISTEN_PORT" == "$HY2_SINGLE_PORT" ]]; then
      printf '%s\n' 'HY2 转发：单端口，不需要本机跳跃转发。'
    else
      printf 'HY2 转发：请在服务商面板将公网 UDP %s 映射到本机 UDP %s。\n' "$HY2_SINGLE_PORT" "$HY2_LISTEN_PORT"
    fi
  elif [[ "$HY2_PORT_HOPPING_MODE" == local ]]; then
    printf '%s\n' 'HY2 转发：脚本用本机 nftables 将这些公网 UDP 端口转到本机监听端口；云安全组只负责放行。'
  else
    printf '%s\n' 'HY2 转发：请在服务商面板将所有上述公网 UDP 端口映射到本机监听端口；脚本不做本机转发。'
  fi
  printf 'HY2 混淆：%s；TLS SNI：%s\n' "$HY2_OBFS" "$HY2_SNI"
  if [[ "${HY2_CERT_MODE:-self}" == le ]]; then
    printf "HY2 证书：Let's Encrypt（acme.sh + Cloudflare DNS 验证，注册邮箱 %s）\\n" "$ACME_EMAIL"
  else
    printf 'HY2 证书：自签名（客户端内嵌证书）\n'
  fi
}

check_hop_mode() {
  case "$1" in
    1) printf 'local\n' ;;
    2) printf 'external\n' ;;
    *) fail '请输入 1 或 2'; return 1 ;;
  esac
}

check_duration() {
  [[ "$1" =~ ^[1-9][0-9]*[smh]$ ]] || { fail '跳跃间隔格式如 30s、5m、1h'; return 1; }
  printf '%s\n' "$1"
}

check_obfs() {
  case "$1" in
    1) printf 'gecko\n' ;;
    2) printf 'salamander\n' ;;
    3) printf 'none\n' ;;
    *) fail '请输入 1、2 或 3'; return 1 ;;
  esac
}

ask_secret() {
  # ask_secret PROMPT -> ANSWER without echo, read from the wizard terminal.
  local line
  printf '%s: ' "$1" >&2
  IFS= read -r -s -u 3 line || { fail '没有终端输入，无法读取令牌'; exit 1; }
  printf '\n' >&2
  ANSWER="$line"
}

check_cert_mode() {
  case "$1" in
    1) printf 'self\n' ;;
    2) printf 'le\n' ;;
    *) fail '请输入 1 或 2'; return 1 ;;
  esac
}

check_email() {
  [[ "$1" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { fail '邮箱格式不正确'; return 1; }
  printf '%s\n' "$1"
}

check_sni() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || { fail 'SNI 必须是不含空格的域名'; return 1; }
  if [[ "${HY2_CERT_MODE:-self}" == le ]]; then
    [[ "$1" =~ ^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ && "$1" != *.local ]] || { fail "Let's Encrypt 需要真实域名，例如 hy2-a.example.com"; return 1; }
  fi
  printf '%s\n' "$1"
}

random_port() { printf '%s\n' $((20000 + RANDOM % 30000)); }

run_wizard() {
  local detected_ip ss_pw
  exec 3< "$WIZARD_INPUT" || return 1
  printf '\n交互式配置（回车使用方括号里的默认值）\n' >&2
  printf '  1) Reality\n  2) Shadowsocks\n  3) HY2 (Hysteria2)\n  4) Reality + HY2\n' >&2
  ask_valid '选择模式' 1 check_mode; MODE=$ANSWER
  detected_ip=$(curl -4 -fsS --connect-timeout 5 -m 8 https://api.ipify.org 2>/dev/null || true)
  ask_valid '服务器公网 IP' "$detected_ip" check_server_ip; SERVER_IP=$ANSWER
  ask_line '节点名称' "$MODE-$(hostname)"; NODE_NAME=$ANSWER

  if [[ "$MODE" == reality || "$MODE" == both ]]; then
    ask_valid 'Reality 本机监听 TCP 端口' "$(random_port)" normalize_port; ACTUAL_LISTEN_PORT=$ANSWER
    ask_valid 'Reality 客户端连接端口（有 NAT 端口映射时才需要改）' "$ACTUAL_LISTEN_PORT" normalize_port; LISTEN_PORT=$ANSWER
    ask_valid 'Reality 伪装域名（留空自动选择）' '' check_reality_name; REALITY_SERVER_NAME=$ANSWER
  fi
  if [[ "$MODE" == ss ]]; then
    ask_valid 'SS 本机监听端口' "$(random_port)" normalize_port; ACTUAL_LISTEN_PORT=$ANSWER
    ask_valid 'SS 客户端连接端口（有 NAT 端口映射时才需要改）' "$ACTUAL_LISTEN_PORT" normalize_port; LISTEN_PORT=$ANSWER
    ask_valid 'SS 加密方式' aes-128-gcm check_method; SS_METHOD=$ANSWER
    ask_line 'SS 密码（留空自动生成）' ''; SS_PASSWORD=$ANSWER
  fi
  if [[ "$MODE" == hy2 || "$MODE" == both ]]; then
    ask_valid 'HY2 本机监听 UDP 端口' "$(random_port)" normalize_port; HY2_LISTEN_PORT=$ANSWER
    ask_valid 'HY2 对外 UDP 端口或跳跃范围（如 443 或 20000-20100）' "$HY2_LISTEN_PORT" check_hy2_ports; HY2_SERVER_PORTS=$ANSWER
    normalize_hy2_ports "$HY2_SERVER_PORTS" || return 1
    HY2_PORT_HOPPING_MODE=external
    if (( HY2_PORT_COUNT > 1 )); then
      ask_valid '跳跃由谁处理（1 本机 nftables / 2 外部 NAT 映射）' 1 check_hop_mode; HY2_PORT_HOPPING_MODE=$ANSWER
      ask_valid '跳跃间隔' 30s check_duration; HY2_HOP_INTERVAL=$ANSWER
    fi
    ask_valid 'HY2 混淆（1 gecko / 2 salamander / 3 none）' 1 check_obfs; HY2_OBFS=$ANSWER
    ask_valid "证书方式（1 自签名 / 2 Let's Encrypt）" 1 check_cert_mode; HY2_CERT_MODE=$ANSWER
    ask_valid 'HY2 TLS 伪装 SNI' hy2.local check_sni; HY2_SNI=$ANSWER
    if [[ "$HY2_CERT_MODE" == le ]]; then
      ask_valid "Let's Encrypt 注册邮箱" '' check_email; ACME_EMAIL=$ANSWER
      ask_secret 'Cloudflare API 令牌（需 Zone:DNS:Edit 与 Zone:Zone:Read 权限，输入不显示）'; CF_API_TOKEN=$ANSWER
      [[ -n "$CF_API_TOKEN" ]] || { fail 'Cloudflare API 令牌不能为空'; return 1; }
    fi
  fi

  printf '\n--- 配置确认 ---\nMode: %s\nServer IP: %s\nNode name: %s\n' "$MODE" "$SERVER_IP" "$NODE_NAME" >&2
  if [[ "$MODE" == reality || "$MODE" == both ]]; then
    printf 'Reality: 本机端口 %s，客户端端口 %s，伪装域名 %s\n' "$ACTUAL_LISTEN_PORT" "$LISTEN_PORT" "${REALITY_SERVER_NAME:-自动选择}" >&2
  fi
  if [[ "$MODE" == ss ]]; then
    ss_pw=${SS_PASSWORD:+自定义}; ss_pw=${ss_pw:-自动生成}
    printf 'SS: 本机端口 %s，客户端端口 %s，加密 %s，密码 %s\n' "$ACTUAL_LISTEN_PORT" "$LISTEN_PORT" "$SS_METHOD" "$ss_pw" >&2
  fi
  if [[ "$MODE" == hy2 || "$MODE" == both ]]; then
    hy2_confirmation >&2 || return 1
  fi
  ask_line '确认开始安装？(y/n)' y
  case "$ANSWER" in y|Y|yes|YES) ;; *) _info2 '已取消，没有做任何修改。'; exit 0 ;; esac
  exec 3<&-
  if [[ "${HY2_CERT_MODE:-self}" == le ]]; then
    # The token goes straight into a root-only file; the detached rerun reads that file, not the environment.
    install -d -m 700 /root/.secrets || return 1
    printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" > /root/.secrets/cloudflare.ini || return 1
    chmod 600 /root/.secrets/cloudflare.ini || return 1
    unset CF_API_TOKEN
  fi
  export MODE SERVER_IP NODE_NAME ACTUAL_LISTEN_PORT LISTEN_PORT REALITY_SERVER_NAME SS_METHOD SS_PASSWORD
  export HY2_LISTEN_PORT HY2_SERVER_PORTS HY2_PORT_HOPPING_MODE HY2_HOP_INTERVAL HY2_OBFS HY2_SNI HY2_CERT_MODE ACME_EMAIL
}

main() {
  set -euo pipefail
  umask 077
  [[ "$(id -u)" == 0 ]] || { fail 'Run as root'; return 1; }
  # Questions come before the HUP trap below, so a disconnect here simply ends the script.
  if [[ "${INSTALL_DAEMONIZED:-0}" != 1 ]]; then
    has_terminal || { fail '需要在终端中运行，脚本会交互式询问配置'; return 1; }
    _cmd jq || install_packages jq
    run_wizard
  fi
  # Original disconnect behavior: rerun detached on HUP. A rerun regenerates
  # node defaults. The daemon writes directly to a private log (no tee pipe).
  INSTALL_LOG="${INSTALL_LOG:-/root/install_reality.log}"
  touch "$INSTALL_LOG"; chmod 600 "$INSTALL_LOG"
  if [[ "${INSTALL_DAEMONIZED:-0}" == 1 ]]; then
    trap '' HUP
    exec >> "$INSTALL_LOG" 2>&1
  else
    trap restart_detached HUP
  fi
  _cmd jq || install_packages jq
  init_settings
  hy2_hop_prepare
  validate_existing_config
  _cmd curl || install_packages curl ca-certificates
  if ! _cmd python3; then
    if _cmd pacman; then install_packages python; else install_packages python3; fi
  fi
  _cmd python3 || { fail 'shownode requires python3'; return 1; }
  if [[ "$MODE" == hy2 || "$MODE" == both ]]; then
    _cmd openssl || install_packages openssl
    if ! _cmd ss; then
      if _cmd apk; then install_packages iproute2-ss
      elif _cmd dnf || _cmd yum; then install_packages iproute
      else install_packages iproute2; fi
    fi
    _cmd python3 && _cmd ss || { fail 'HY2 listener check requires python3 and ss'; return 1; }
  fi
  WORK_DIR=''; CORE_STAGE_DIR=''
  CONFIG_COMMITTED=0; CONFIG_ACCEPTED=0
  trap cleanup_installer EXIT
  stage_singbox
  mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
  WORK_DIR=$(mktemp -d "$CONFIG_DIR/.installer.XXXXXX")
  if [[ "$MODE" == reality || "$MODE" == both ]]; then select_reality_dest; generate_credentials; fi
  if [[ "$MODE" == ss ]]; then generate_ss_credentials; fi
  if [[ "$MODE" == hy2 || "$MODE" == both ]]; then generate_hy2_credentials; fi
  # Avoid unset legacy port in HY2-only self-checks.
  ACTUAL_LISTEN_PORT="${ACTUAL_LISTEN_PORT:-${HY2_LISTEN_PORT:-}}"
  build_nodes
  probe_hy2_support
  stage_shownode
  if ! merge_candidate "$NEW_INBOUNDS" "$WORK_DIR/config.json" || ! prepare_outputs; then
    fail "Configuration preflight failed for MODE=$MODE; see the diagnostics above. The live core and server config have not been replaced."
    return 1
  fi
  _ok2 "Core preflight passed for MODE=$MODE (server and client configuration checks)."
  install_staged_singbox
  check_and_open_firewall
  hy2_hop_install
  commit_candidate "$WORK_DIR/config.json"
  SERVICE_START_EPOCH=$(date +%s)
  if start_service > "$WORK_DIR/service-start.log" 2>&1; then
    cat "$WORK_DIR/service-start.log"
  else
    tail -n 20 "$WORK_DIR/service-start.log" >&2
    save_install_diagnostics 'service-start' || true
    fail 'Service start failed; restoring previous configuration'; return 1
  fi
  if [[ "$MODE" == hy2 || "$MODE" == both ]]; then
    if ! hy2_check_listener; then
      save_install_diagnostics 'hy2-listener' || true
      fail "HY2 [1/3] 未确认 sing-box 在 $LISTEN_ADDR UDP $HY2_LISTEN_PORT 监听；未执行握手，正在回滚。"; return 1
    fi
    _ok2 "HY2 [1/3] sing-box 正在 $LISTEN_ADDR UDP $HY2_LISTEN_PORT 监听。"
  fi
  # The self-check starts a second sing-box (plus a Python fixture for HY2); that is too much
  # for a 128 MB machine, so it only runs on request: SELF_CHECK=1.
  if [[ "${SELF_CHECK:-0}" == 1 ]]; then
    if ! self_check; then
      save_install_diagnostics 'protocol-self-check' || true
      fail 'Protocol self-check failed; restoring previous configuration'; return 1
    fi
  else
    _info2 '已跳过本机协议自检（默认关闭；需要时用 SELF_CHECK=1 运行）。'
  fi
  if ! hy2_hop_configure; then
    fail 'HY2 local forwarding could not be applied; restoring previous configuration'; return 1
  fi
  CONFIG_ACCEPTED=1
  publish_outputs
  if ! install_shownode; then
    _warn2 'Node is running, but shownode metadata or command installation failed. The latest client files are still in the config directory.'
  fi
  setup_logrotate
  if ! _cmd ssh-keygen; then
    if _cmd apk || _cmd zypper || _cmd pacman; then install_packages openssh
    elif _cmd dnf || _cmd yum; then install_packages openssh-clients
    else install_packages openssh-client
    fi
  fi
  setup_ssh_key
  enable_pubkey_auth || _warn2 'SSH public key login was not enabled automatically.'
  setup_alias
  _ok2 "Installation complete: MODE=$MODE. Read $CONFIG_DIR/node_output.txt or run shownode."
}

if [[ "${INSTALLER_SOURCE_ONLY:-0}" != 1 ]]; then main "$@"; fi
