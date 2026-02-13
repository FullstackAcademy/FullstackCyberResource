#!/usr/bin/env bash
set -euo pipefail
set +H 2>/dev/null || true  # disable history expansion if sourced in an interactive shell

# =========================
# Lab configuration
# =========================
LAB_USER="${LAB_USER:-splunk}"
LAB_PASS="${LAB_PASS:-Password.1!!}"
SPLUNK_SCRIPT_SRC="${SPLUNK_SCRIPT_SRC:-./InstallSplunk.sh}"     # path to your InstallSplunk.sh (default: current dir)
SPLUNK_SCRIPT_DEST="/home/${LAB_USER}/InstallSplunk.sh"

# Set to 0 if you do NOT want this script to create/reset the user's password
SET_PASSWORD="${SET_PASSWORD:-1}"

# Set to 0 if you do NOT want SSH pre-login banner configured
CONFIGURE_SSH_BANNER="${CONFIGURE_SSH_BANNER:-1}"

timestamp() { date +"%Y%m%d_%H%M%S"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root (or: sudo $0)"
    exit 1
  fi
}

backup_if_exists() {
  local f="$1"
  if [[ -e "$f" ]]; then
    cp -a "$f" "${f}.bak.$(timestamp)"
  fi
}

write_file() {
  local path="$1"
  local content="$2"
  backup_if_exists "$path"
  printf "%s" "$content" > "$path"
}

ensure_user() {
  if id "$LAB_USER" &>/dev/null; then
    :
  else
    # Create user with home directory and bash shell
    useradd -m -s /bin/bash "$LAB_USER"
  fi

  if [[ "$SET_PASSWORD" == "1" ]]; then
    printf "%s:%s
" "$LAB_USER" "$LAB_PASS" | chpasswd
  fi

  # Add to sudo/wheel group if present (best-effort)
  if getent group sudo &>/dev/null; then
    usermod -aG sudo "$LAB_USER"
  elif getent group wheel &>/dev/null; then
    usermod -aG wheel "$LAB_USER"
  fi
}

install_splunk_script() {
  if [[ ! -f "$SPLUNK_SCRIPT_SRC" ]]; then
    echo "ERROR: Cannot find $SPLUNK_SCRIPT_SRC"
    echo "Place InstallSplunk.sh next to this script, or set SPLUNK_SCRIPT_SRC=/path/to/InstallSplunk.sh"
    exit 1
  fi

  install -o "$LAB_USER" -g "$LAB_USER" -m 755 "$SPLUNK_SCRIPT_SRC" "$SPLUNK_SCRIPT_DEST"
}

configure_sudoers_nopasswd() {
  local sudoers_file="/etc/sudoers.d/lab-splunk"
  local line="${LAB_USER} ALL=(root) NOPASSWD: ${SPLUNK_SCRIPT_DEST}"

  backup_if_exists "$sudoers_file"
  printf "%s
" "$line" > "$sudoers_file"
  chmod 0440 "$sudoers_file"

  # Validate sudoers syntax
  if ! visudo -cf "$sudoers_file" >/dev/null 2>&1; then
    echo "ERROR: sudoers validation failed for $sudoers_file"
    exit 1
  fi
}

configure_banners() {
  local prelogin_banner
  prelogin_banner=$(
    cat <<EOF
========================================
  CYBER LAB VM

  Username: ${LAB_USER}
  Password: ${LAB_PASS}

  After login:
    cd ~
    sudo ./InstallSplunk.sh
========================================

EOF
  )

  local postlogin_banner
  postlogin_banner=$(
    cat <<EOF
========================================
  LAB INSTRUCTIONS

  Run:
    cd ~
    sudo ./InstallSplunk.sh
========================================
EOF
  )

  # Console pre-login banner
  write_file "/etc/issue" "$prelogin_banner"

  # Post-login banner (some distros overwrite /etc/motd; we also add /etc/profile.d banner)
  write_file "/etc/motd" "$postlogin_banner"

  local profile_banner="/etc/profile.d/lab-banner.sh"
  backup_if_exists "$profile_banner"
  cat > "$profile_banner" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${PS1-}" ]]; then
cat <<'BANNER'
========================================
  LAB INSTRUCTIONS

  Run:
    cd ~
    sudo ./InstallSplunk.sh
========================================
BANNER
fi
EOF
  chmod 0755 "$profile_banner"
}

configure_ssh_banner() {
  [[ "$CONFIGURE_SSH_BANNER" == "1" ]] || return 0

  if [[ -f /etc/ssh/sshd_config ]]; then
    # Copy /etc/issue content into /etc/issue.net for SSH pre-login banner
    cp -a /etc/issue /etc/issue.net

    backup_if_exists /etc/ssh/sshd_config

    # Ensure "Banner /etc/issue.net" is set (uncomment or add)
    if grep -Eq '^[[:space:]]*Banner[[:space:]]+' /etc/ssh/sshd_config; then
      sed -i 's|^[[:space:]]*Banner[[:space:]].*|Banner /etc/issue.net|' /etc/ssh/sshd_config
    elif grep -Eq '^[[:space:]]*#?[[:space:]]*Banner[[:space:]]+' /etc/ssh/sshd_config; then
      sed -i 's|^[[:space:]]*#?[[:space:]]*Banner[[:space:]].*|Banner /etc/issue.net|' /etc/ssh/sshd_config
    else
      printf "
Banner /etc/issue.net
" >> /etc/ssh/sshd_config
    fi

    # Reload ssh service (best-effort)
    if command -v systemctl &>/dev/null; then
      systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
    else
      service sshd reload 2>/dev/null || service ssh reload 2>/dev/null || true
    fi
  fi
}

main() {
  require_root
  ensure_user
  install_splunk_script
  configure_sudoers_nopasswd
  configure_banners
  configure_ssh_banner

  echo "Done."
  echo "User: ${LAB_USER}"
  echo "Script installed: ${SPLUNK_SCRIPT_DEST}"
  echo "Pre-login: /etc/issue"
  echo "Post-login: /etc/motd and /etc/profile.d/lab-banner.sh"
  if [[ "$CONFIGURE_SSH_BANNER" == "1" && -f /etc/ssh/sshd_config ]]; then
    echo "SSH Banner: /etc/issue.net (enabled)"
  fi
}

main "$@"
