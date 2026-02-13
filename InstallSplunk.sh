#!/usr/bin/env bash
set -euo pipefail

############################################
# Splunk Lab Installer (Ubuntu/Debian)
# Installs Splunk as root, runs Splunk as user "splunk"
############################################

# ---------- Config ----------
SPLUNK_USER="splunk"

SPLUNK_DEB="splunk-10.2.0-d749cb17ea65-linux-amd64.deb"
SPLUNK_URL="https://download.splunk.com/products/splunk/releases/10.2.0/linux/${SPLUNK_DEB}"
SPLUNK_DEB_PATH="/tmp/${SPLUNK_DEB}"

SPLUNK_DIR="/opt/splunk"
SPLUNK_BIN="${SPLUNK_DIR}/bin/splunk"

ADMIN_USER="admin"
ADMIN_PASS="admin"

POKE_URL="https://drive.google.com/uc?export=download&id=129XqTtIrR04SFES0F2FfVU9Rj9WkzGEs"
DATA_DIR="/tmp/splunk_lab_data"
POKE_FILE="${DATA_DIR}/pokemon.csv"
INGEST_MARKER="/var/tmp/.splunk_pokedex_ingested"

# ---------- Color / UI ----------
if [[ -t 1 ]]; then
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"; CYAN="$(tput setaf 6)"; BOLD="$(tput bold)"
  RESET="$(tput sgr0)"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; BOLD=""; RESET=""
fi

STEP=0
TOTAL=6

die() { echo -e "${RED}ERROR${RESET} - $*" >&2; exit 1; }
ok()  { echo -e "${GREEN}OK${RESET} - $*"; }
warn(){ echo -e "${YELLOW}WARN${RESET} - $*"; }

step() {
  STEP=$((STEP+1))
  echo -e "\n${BOLD}${CYAN}[${STEP}/${TOTAL}]${RESET} $*"
}

run_with_spinner() {
  # run_with_spinner "Message" command args...
  local msg="$1"; shift
  local tmp pid rc
  tmp="$(mktemp)"

  echo -ne "${msg} "
  ( "$@" ) >"$tmp" 2>&1 &
  pid=$!

  local spin='-\|/'
  local i=0
  echo -ne "${spin:0:1}\b"

  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) % 4 ))
    echo -ne "${spin:$i:1}\b"
    sleep 0.15
  done

  wait "$pid"
  rc=$?

  if [[ "$rc" -eq 0 ]]; then
    echo -e "${GREEN}done${RESET}"
    rm -f "$tmp"
    return 0
  fi

  echo -e "${RED}failed${RESET}"
  echo "---- last output ----" >&2
  tail -n 120 "$tmp" >&2 || true
  rm -f "$tmp"
  exit "$rc"
}

# ---------- Checks ----------
need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root. Example: sudo ./InstallSplunk.sh"
}

block_arm() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) : ;;
    aarch64|arm64|armv7l|armv6l) die "ARM detected (${arch}). This lab will not function on ARM systems." ;;
    *) die "Unsupported architecture: ${arch}" ;;
  esac
}

warn_if_low_disk_space() {
  local check_path free_gb resp
  check_path="/opt"
  [[ -d "${SPLUNK_DIR}" ]] && check_path="${SPLUNK_DIR}"

  free_gb="$(df -BG "${check_path}" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')"
  [[ -n "${free_gb}" ]] || { warn "Could not determine free disk space for ${check_path}. Continuing."; return 0; }

  if (( free_gb < 40 )); then
    warn "Only ${free_gb} GB free on filesystem backing ${check_path}."
    warn "Splunk + ingested data may exceed this and cause 'no space left on device'."
    read -r -p "Continue anyway? (y/N): " resp
    case "${resp}" in
      y|Y|yes|YES) : ;;
      *) echo "Exiting."; exit 1 ;;
    esac
  fi
}

# ---------- Users / Run-as ----------
ensure_splunk_user() {
  if ! id -u "${SPLUNK_USER}" >/dev/null 2>&1; then
    # Students often already have it; if not, create a system-style account.
    useradd --system --home "${SPLUNK_DIR}" --shell /usr/sbin/nologin "${SPLUNK_USER}"
  fi

  # Ensure Splunk directory is owned by splunk user for non-root operation
  if [[ -d "${SPLUNK_DIR}" ]]; then
    chown -R "${SPLUNK_USER}:${SPLUNK_USER}" "${SPLUNK_DIR}"
  fi
}

run_as_splunk() {
  # Run /opt/splunk/bin/splunk ... as SPLUNK_USER (safe quoting)
  su -s /bin/bash "${SPLUNK_USER}" -c "$(printf '%q ' "${SPLUNK_BIN}" "$@")"
}

# ---------- Network / IP ----------
get_lab_ip() {
  local def_if ip
  def_if="$(ip route show default 0.0.0.0/0 2>/dev/null | awk 'NR==1{print $5}')"
  if [[ -n "${def_if}" ]]; then
    ip="$(ip -4 addr show dev "${def_if}" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
    [[ -n "${ip}" ]] && { echo "${ip}"; return 0; }
  fi
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "${ip}" ]] && { echo "${ip}"; return 0; }
  echo ""
}

# ---------- Downloads ----------
download_file() {
  # download_file URL OUTFILE
  local url="$1"
  local out="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fL --progress-bar "${url}" -o "${out}"
  elif command -v wget >/dev/null 2>&1; then
    wget --progress=bar:force:noscroll -O "${out}" "${url}"
  else
    die "Neither curl nor wget is installed."
  fi

  [[ -s "${out}" ]] || die "Download failed or file is empty: ${out}"
}

# ---------- Splunk actions ----------
install_splunk_if_missing() {
  if [[ -x "${SPLUNK_BIN}" ]]; then
    ok "Splunk already installed at ${SPLUNK_DIR} (skipping install)."
    ensure_splunk_user
    return 0
  fi

  warn_if_low_disk_space

  echo "Downloading Splunk package..."
  download_file "${SPLUNK_URL}" "${SPLUNK_DEB_PATH}"

  run_with_spinner "Installing package (dpkg)..." dpkg -i "${SPLUNK_DEB_PATH}"

  echo "Deleting installer package to save space..."
  rm -f "${SPLUNK_DEB_PATH}"

  ensure_splunk_user

  echo "Seeding admin credentials (lab): ${ADMIN_USER}/${ADMIN_PASS}"
  mkdir -p "${SPLUNK_DIR}/etc/system/local"
  cat > "${SPLUNK_DIR}/etc/system/local/user-seed.conf" <<EOC
[user_info]
USERNAME = ${ADMIN_USER}
PASSWORD = ${ADMIN_PASS}
EOC
  chown "${SPLUNK_USER}:${SPLUNK_USER}" "${SPLUNK_DIR}/etc/system/local/user-seed.conf"

  run_with_spinner "First start (accept license)..." run_as_splunk start --accept-license --answer-yes --no-prompt

  run_with_spinner "Enabling boot-start (systemd)..." bash -c "printf 'y\n' | '${SPLUNK_BIN}' enable boot-start -user '${SPLUNK_USER}' >/dev/null 2>&1 || true"
  systemctl daemon-reload >/dev/null 2>&1 || true

  # Cleanup seed file after first successful start
  rm -f "${SPLUNK_DIR}/etc/system/local/user-seed.conf" >/dev/null 2>&1 || true

  ok "Splunk installed."
}

ensure_splunk_running() {
  run_as_splunk status >/dev/null 2>&1 && return 0
  run_with_spinner "Starting Splunk..." run_as_splunk start --answer-yes --no-prompt
  run_as_splunk status >/dev/null 2>&1 || die "Splunk is not running after start attempt."
}

ingest_pokemon_csv_once() {
  if [[ -f "${INGEST_MARKER}" ]]; then
    ok "pokemon.csv already ingested (marker present)."
    return 0
  fi

  mkdir -p "${DATA_DIR}"

  echo "Downloading pokemon.csv..."
  download_file "${POKE_URL}" "${POKE_FILE}"

  run_with_spinner "Uploading pokemon.csv to Splunk (oneshot)..." \
    run_as_splunk add oneshot "${POKE_FILE}" \
      -index "main" \
      -sourcetype "pokedex" \
      -source "Pokedex" \
      -host "Pokedex" \
      -auth "${ADMIN_USER}:${ADMIN_PASS}"

  touch "${INGEST_MARKER}"
  ok "Data uploaded."
}

# ---------- Main ----------
need_root

step "Architecture check"
block_arm
ok "x86_64/amd64 confirmed."

step "Install (or reuse existing)"
install_splunk_if_missing

step "Ensure Splunk is running"
ensure_splunk_running
ok "Splunk running as user '${SPLUNK_USER}'."

step "Ingest lab data (pokemon.csv)"
ingest_pokemon_csv_once

step "Access information"
ip_addr="$(get_lab_ip)"

echo
echo -e "${BOLD}Splunk is running.${RESET}"
echo -e "URL: ${BOLD}http://${ip_addr:-<server-ip>}:8000${RESET}"
echo -e "Credentials: ${BOLD}${ADMIN_USER} / ${ADMIN_PASS}${RESET}"
echo
