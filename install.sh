#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly REPO="yt-dlp/yt-dlp"
readonly BASE_URL="https://github.com/${REPO}/releases/latest/download"
readonly KEY_URL="https://raw.githubusercontent.com/${REPO}/master/public.key"
readonly EXPECTED_FINGERPRINT="AC0CBBE6848D6A873464AF4E57CF65933B5A7581"
readonly INSTALL_DIR="${HOME}/.local/bin"
readonly INSTALL_PATH="${INSTALL_DIR}/yt-dlp"

log() {
    printf '[yt-dlp installer] %s\n' "$*"
}

die() {
    printf '[yt-dlp installer] ERROR: %s\n' "$*" >&2
    exit 1
}

if [[ "${EUID}" -eq 0 ]]; then
    die "Do not run this script as root or with sudo. Run it as your normal user."
fi

if [[ ! -r /etc/os-release ]]; then
    die "Cannot identify the operating system."
fi

# shellcheck disable=SC1091
. /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    die "This installer is intended for Ubuntu. Detected: ${PRETTY_NAME:-unknown}."
fi

command -v sudo >/dev/null 2>&1 || die "sudo is required to install Ubuntu dependencies."
command -v apt-get >/dev/null 2>&1 || die "apt-get was not found."

log "Installing required Ubuntu packages (curl, GnuPG, CA certificates, ffmpeg)..."
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    ffmpeg \
    gnupg

for cmd in curl gpg sha256sum awk install mktemp; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found after dependency installation: $cmd"
done

tmpdir="$(mktemp -d)"
gnupg_home="${tmpdir}/gnupg"

cleanup() {
    rm -rf -- "$tmpdir"
}
trap cleanup EXIT INT TERM

mkdir -m 700 "$gnupg_home"
mkdir -p "$INSTALL_DIR"

log "Downloading official yt-dlp release files..."
curl --fail --show-error --location --proto '=https' --tlsv1.2 \
    --output "${tmpdir}/yt-dlp" \
    "${BASE_URL}/yt-dlp"

curl --fail --show-error --location --proto '=https' --tlsv1.2 \
    --output "${tmpdir}/SHA2-256SUMS" \
    "${BASE_URL}/SHA2-256SUMS"

curl --fail --show-error --location --proto '=https' --tlsv1.2 \
    --output "${tmpdir}/SHA2-256SUMS.sig" \
    "${BASE_URL}/SHA2-256SUMS.sig"

log "Downloading the official yt-dlp signing public key..."
curl --fail --show-error --location --proto '=https' --tlsv1.2 \
    --output "${tmpdir}/public.key" \
    "$KEY_URL"

log "Checking signing-key fingerprint..."
actual_fingerprint="$(
    GNUPGHOME="$gnupg_home" \
    gpg --batch --with-colons --import-options show-only --import "${tmpdir}/public.key" 2>/dev/null |
    awk -F: '$1 == "fpr" { print $10; exit }'
)"

[[ -n "$actual_fingerprint" ]] || die "Could not read the signing-key fingerprint."

if [[ "$actual_fingerprint" != "$EXPECTED_FINGERPRINT" ]]; then
    die "Signing-key fingerprint mismatch.
Expected: ${EXPECTED_FINGERPRINT}
Received: ${actual_fingerprint}"
fi

log "Signing-key fingerprint is correct:"
printf '  %s\n' "$actual_fingerprint"

GNUPGHOME="$gnupg_home" \
gpg --batch --quiet --import "${tmpdir}/public.key"

log "Verifying GPG signature of SHA2-256SUMS..."
GNUPGHOME="$gnupg_home" \
gpg --batch --verify \
    "${tmpdir}/SHA2-256SUMS.sig" \
    "${tmpdir}/SHA2-256SUMS"

log "Verifying SHA-256 of the yt-dlp binary..."
expected_sha256="$(
    awk '$2 == "yt-dlp" || $2 == "*yt-dlp" { print $1; exit }' \
        "${tmpdir}/SHA2-256SUMS"
)"

[[ "$expected_sha256" =~ ^[0-9A-Fa-f]{64}$ ]] ||
    die "Could not obtain a valid SHA-256 for yt-dlp from SHA2-256SUMS."

actual_sha256="$(sha256sum "${tmpdir}/yt-dlp" | awk '{print $1}')"

if [[ "${actual_sha256,,}" != "${expected_sha256,,}" ]]; then
    die "SHA-256 mismatch.
Expected: ${expected_sha256}
Received: ${actual_sha256}"
fi

log "SHA-256 verified:"
printf '  %s\n' "$actual_sha256"

# Keep the current executable untouched until all cryptographic checks pass.
staged_path="${INSTALL_PATH}.new.$$"
trap 'rm -f -- "$staged_path"; cleanup' EXIT INT TERM

install -m 0755 "${tmpdir}/yt-dlp" "$staged_path"
mv -f -- "$staged_path" "$INSTALL_PATH"

# Restore the simpler cleanup trap now that the staged file no longer exists.
trap cleanup EXIT INT TERM

log "Installed successfully:"
printf '  %s\n' "$INSTALL_PATH"

log "Installed yt-dlp version:"
"$INSTALL_PATH" --version

log "ffmpeg version:"
ffmpeg -version | head -n 1

case ":${PATH}:" in
    *":${INSTALL_DIR}:"*)
        log "yt-dlp is already available through PATH."
        ;;
    *)
        printf '\n'
        log "${INSTALL_DIR} is not in the current PATH."
        printf 'Ubuntu normally adds ~/.local/bin after a new login.\n'
        printf 'For this terminal, run:\n\n'
        printf '  export PATH="$HOME/.local/bin:$PATH"\n\n'
        ;;
esac

printf '\n'
log "Installation complete."
printf 'Run: %s --version\n' "$INSTALL_PATH"
