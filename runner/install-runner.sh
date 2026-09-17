#!/usr/bin/env bash
#
# install-runner.sh -- set up a self-hosted GitHub Actions runner on a Linux VM.
#
# This script is deliberately verbose and heavily commented: it is also teaching
# material for an operator who has never used GitHub Actions before. Read it top
# to bottom before running it; nothing here is magic.
#
# =============================================================================
#  WHAT A SELF-HOSTED RUNNER IS (30 seconds)
# =============================================================================
#
#  GitHub Actions needs a machine to run your workflow jobs on. GitHub can lend
#  you one ("GitHub-hosted runner"), but a GitHub-hosted runner cannot reach a
#  private Kubernetes API endpoint. So for the deploy workflow we run the job on
#  a machine we control: a "self-hosted runner".
#
#  The runner is a small agent process. It *polls* GitHub over outbound HTTPS,
#  asking "any jobs for me?". When a job arrives it runs the job's steps on this
#  machine and streams the logs back.
#
# =============================================================================
#  !!  NO INBOUND PORTS ARE REQUIRED.  NONE.  NOT ONE.  !!
# =============================================================================
#
#  This is the single most common misconception about self-hosted runners, so it
#  gets the biggest banner in this file:
#
#     * GitHub NEVER connects to this machine.
#     * The runner opens an outbound HTTPS (443) long-poll to GitHub and waits.
#     * You do NOT need a public IP.
#     * You do NOT need a port forward, a NAT rule, an ingress, or a hole in
#       your firewall's inbound rules.
#     * You do NOT need a DNS name for this VM.
#     * A VM behind NAT with only egress allowed is a perfectly good runner.
#
#  If you find yourself opening an inbound port "so GitHub can reach the
#  runner", stop: that is not how it works, and the port is pure added risk.
#
# =============================================================================
#  VM REQUIREMENTS (spec section 9.1)
# =============================================================================
#
#  Works on ANY Linux VM: a KVM guest, bare metal, an LXC container, a cloud
#  instance -- no hyperscaler assumptions anywhere. There is deliberately no
#  cloud provider in this project.
#
#  Hardware / OS
#    * Linux, x86_64 or arm64.
#    * Debian/Ubuntu family, or RHEL family (RHEL, Rocky, Alma, CentOS Stream,
#      Fedora, Amazon Linux).
#    * 2 vCPU, 2 GB RAM, 20 GB disk is comfortable. The deploy workload is a
#      handful of CLI calls (kubectl/helm) -- it is not a build farm.
#    * systemd (used to keep the runner running across reboots).
#    * Not a Docker/Kubernetes container, for the MVP. Running the runner
#      containerised works and is a reasonable later option, but it adds a layer
#      to debug while you are still learning; an LXC system container is fine
#      because it has systemd.
#
#  Outbound HTTPS (443) -- the ONLY network requirement
#    Needed by the runner and the deploy workflow:
#      github.com                        runner download, git operations
#      api.github.com                    registration, job coordination
#      *.actions.githubusercontent.com   job/log traffic, run-time tokens
#      objects.githubusercontent.com     release asset downloads (redirect target)
#      charts.releases.teleport.dev      the Teleport Helm chart repository
#      your container registry           image pulls happen on the *cluster*, but
#                                        allow it if the runner ever pulls
#      your Kubernetes API endpoint      kubectl/helm target (often private)
#    Needed by this installer only, at install time:
#      dl.k8s.io, cdn.dl.k8s.io          pinned kubectl binary + checksum
#      get.helm.sh                       pinned helm archive + checksum
#      your distro's package mirrors     curl, tar, git, jq, openssl, gettext
#
#  Outbound SMTP, SSH to GitHub, or anything else: not required.
#
# =============================================================================
#  WHAT THIS SCRIPT DOES *NOT* DO -- READ THIS
# =============================================================================
#
#  It does NOT give the runner access to your Kubernetes cluster.
#
#  Per spec section 3, Kubernetes credentials are out of scope for this project.
#  The pipeline's entire contract with this machine is:
#
#      "kubectl and helm are on PATH and already authenticated to the
#       right cluster, when running as the github-runner user."
#
#  This script installs kubectl and helm. It does not, and will never,
#  authenticate them -- it never reads, writes, or handles a credential.
#  Wiring that up is a separate, deliberate step you perform afterwards
#  (spec section 10, item 5). The usual answer is short-lived credentials from
#  Teleport Machine & Workload Identity (`tbot`) in a separate Teleport cluster;
#  a kubeconfig or an in-cluster ServiceAccount also work.
#
#  The finish line for that separate step is one command succeeding:
#
#      sudo -u github-runner kubectl get ns <your-teleport-namespace>
#
#  Until that command works, this runner CANNOT deploy anything. The summary
#  printed at the end of this script will remind you again.
#
# =============================================================================
#  USAGE
# =============================================================================
#
#      sudo ./install-runner.sh \
#        --url    https://github.com/OWNER/REPO \
#        --token  <registration-token> \
#        --labels self-hosted,linux,teleport-deploy
#
#  Run `./install-runner.sh --help` for the full flag reference.
#
#  This script must be run as root (it installs packages, creates a user, and
#  installs a systemd unit). The runner itself will NOT run as root -- see the
#  long explanation at `assert_runner_is_not_root` below.
#
#  It is idempotent: run it twice and the second run reports what is already in
#  place and exits 0 rather than failing. If the runner is already registered it
#  will not re-register (and so does not need a fresh token).
#

# -----------------------------------------------------------------------------
# Shell safety. Non-negotiable for an installer.
#   -e            stop at the first command that fails
#   -u            treat an unset variable as an error (catches typo'd names)
#   -o pipefail   a failure anywhere in a pipeline fails the whole pipeline
# -----------------------------------------------------------------------------
set -euo pipefail

# =============================================================================
#  PINNED VERSIONS AND CHECKSUMS
# =============================================================================
#
# Everything downloaded here is pinned to an exact version AND verified against
# a SHA-256 recorded in this file. Pinning alone is not enough: without the
# hash, a compromised mirror or a MITM could hand us a different binary under
# the same version number. The hashes below were copied from the publishers'
# own checksum files / release notes.
#
# TO BUMP A VERSION you must also update its hashes. Where to get them:
#
#   kubectl  https://dl.k8s.io/release/<ver>/bin/linux/<arch>/kubectl.sha256
#   helm     https://get.helm.sh/helm-<ver>-linux-<arch>.tar.gz.sha256sum
#   runner   the release notes at
#            https://github.com/actions/runner/releases/tag/<ver>
#            (each asset is listed with its SHA-256), or, scriptably:
#            curl -s https://api.github.com/repos/actions/runner/releases/tags/<ver> \
#              | jq -r '.assets[] | "\(.name) \(.digest)"'
#
# If you ever cannot look a checksum up, do NOT invent one and do NOT delete the
# check. Leave the pin alone, or set the corresponding *_SHA256 to the literal
# string "UNKNOWN" -- this script treats that as a hard error and tells you to go
# find the real value, which is the correct outcome. Never "verify" against a
# hash you computed from the very file you just downloaded: that only proves the
# download was not corrupted in flight, not that it is the right file.

# kubectl -- the Kubernetes CLI. A kubectl within one minor version of the
# cluster's API server is supported, so this pin does not have to match your
# cluster exactly.
readonly KUBECTL_VERSION="v1.37.0"
readonly KUBECTL_SHA256_AMD64="6129359f4e1f3848a5572ccb0b26cf28b8ca08cef38c95a765b2f64a2c961a2f"
readonly KUBECTL_SHA256_ARM64="922df28df248cc00a9e025f947704f1d1482de64ece54cfe57e61f19eaf1eef3"

# helm -- deliberately pinned to the 3.x line. Helm 4 exists, but the deploy
# workflow is written against Helm 3 semantics; upgrading the major version is a
# decision to make on purpose, not to inherit from "latest".
readonly HELM_VERSION="v3.22.0"
readonly HELM_SHA256_AMD64="1e4ab49e429626cf6c6958d914248b78c9730803c2751b87627e171dc800e7bb"
readonly HELM_SHA256_ARM64="f14e804dfee240f55525b667488fe9adca349e63e00c9af634c0beb1421ac310"

# actions/runner -- the agent itself. GitHub auto-updates the runner in place
# after registration, so this pin is only the starting point.
readonly RUNNER_VERSION="2.337.0"
readonly RUNNER_SHA256_X64="70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613"
readonly RUNNER_SHA256_ARM64="9b1dc70626422526e3c94767cf024896beb15da5342a3f4819bf2feac13e0393"

# =============================================================================
#  FIXED LOCAL PATHS AND NAMES
# =============================================================================

# The unprivileged account the runner runs as. Not root. See
# `assert_runner_is_not_root`.
readonly RUNNER_USER="github-runner"
readonly RUNNER_USER_HOME="/home/${RUNNER_USER}"

# Where the runner software lives. Inside the runner user's home so that
# everything the runner owns is in one place and easy to reason about (and easy
# to delete if you want to start over).
readonly RUNNER_DIR="${RUNNER_USER_HOME}/actions-runner"

# Where we put kubectl and helm. /usr/local/bin is on PATH for every login shell
# on both supported distro families and is not managed by the package manager,
# so we are not fighting apt/dnf over these files.
readonly BIN_DIR="/usr/local/bin"

# =============================================================================
#  SMALL OUTPUT HELPERS
# =============================================================================
# Everything user-facing goes through these so the output has one voice.
# Diagnostics go to stderr; only the final summary is "real" stdout content.

log()  { printf '[ install-runner ] %s\n' "$*"; }
warn() { printf '[ install-runner ] WARNING: %s\n' "$*" >&2; }

# die: print a clear, actionable error and stop. Every call site should say what
# to fix, not just what went wrong.
die() {
  printf '\n[ install-runner ] ERROR: %s\n\n' "$1" >&2
  exit 1
}

# A visual section divider, because this script prints a lot.
section() {
  printf '\n===============================================================================\n'
  printf '  %s\n' "$*"
  printf '===============================================================================\n'
}

# =============================================================================
#  --help
# =============================================================================

usage() {
  cat <<'EOF'
install-runner.sh -- install a self-hosted GitHub Actions runner on a Linux VM.

USAGE
  sudo ./install-runner.sh --url <repo-url> --token <registration-token> \
                           --labels <comma-separated> [--runner-name <name>]

REQUIRED FLAGS
  --url <repo-url>
        The repository the runner will serve, as a full URL:
          https://github.com/OWNER/REPO
        This runner is registered to a single repository (not to an
        organisation), which is the least-privilege choice.

  --token <registration-token>
        A short-lived runner REGISTRATION token.

        Where to get it:
          the repository on github.com
            -> Settings
            -> Actions
            -> Runners
            -> "New self-hosted runner"
            -> copy the token out of the `./config.sh --token ...` line
               shown in the "Configure" section.

        IMPORTANT: this token EXPIRES IN ABOUT ONE HOUR. It is a
        single-purpose, short-lived registration credential -- NOT a personal
        access token, NOT a long-lived secret, and it grants nothing but the
        ability to register one runner. If registration fails with "Invalid
        configuration provided for token" or a 404, the usual cause is simply
        that the token went stale: go and copy a fresh one.

        To keep the token out of your shell history you may pass it in the
        RUNNER_TOKEN environment variable instead of --token, e.g.
          sudo RUNNER_TOKEN=... ./install-runner.sh --url ... --labels ...
        --token wins if both are given.

  --labels <comma-separated>
        Labels this runner advertises. A workflow job selects a runner with
        `runs-on:`, so these must match what the workflow asks for.
        Example:  --labels self-hosted,linux,teleport-deploy
        The `self-hosted` label is always added by GitHub whether you list it
        or not; listing it does no harm and makes the intent obvious.

OPTIONAL FLAGS
  --runner-name <name>
        The name shown in the GitHub Runners list. Defaults to this machine's
        short hostname. Must be unique within the repository -- if the name is
        already taken, the existing registration is replaced (config.sh is
        called with --replace), which is what you want when rebuilding a VM.

  --help
        Print this help and exit 0.

WHAT THIS SCRIPT DOES NOT DO
  It does NOT set up Kubernetes access for the runner. That is a separate step
  (see spec section 3 and section 10 item 5). This script installs kubectl and
  helm but never authenticates them and never touches a credential. The runner
  is not able to deploy anything until, as a separate exercise,
      sudo -u github-runner kubectl get ns <namespace>
  succeeds -- typically via short-lived credentials from Teleport Machine &
  Workload Identity, or a kubeconfig, or an in-cluster ServiceAccount.

NETWORKING
  Outbound HTTPS only. NO INBOUND PORTS ARE REQUIRED -- the runner polls
  GitHub; nothing ever connects to this machine. See the comment block at the
  top of this file for the exact outbound destinations.

IDEMPOTENCY
  Safe to re-run. Already-installed tools are left alone, and an
  already-registered runner is detected and reported rather than re-registered
  (so a re-run does not need a fresh token).

EXAMPLE
  sudo ./install-runner.sh \
    --url    https://github.com/acme/teleport-cluster \
    --token  AXXXXXXXXXXXXXXXXXXXXXXXXXXXXX \
    --labels self-hosted,linux,teleport-deploy \
    --runner-name teleport-deploy-01
EOF
}

# =============================================================================
#  ARGUMENT PARSING
# =============================================================================

# Defaults. RUNNER_TOKEN may already be set in the environment (documented
# above); `${RUNNER_TOKEN:-}` keeps `set -u` happy when it is not.
ARG_URL=""
ARG_TOKEN="${RUNNER_TOKEN:-}"
ARG_LABELS=""
ARG_RUNNER_NAME=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --url)
        [[ $# -ge 2 ]] || die "--url needs a value, e.g. --url https://github.com/OWNER/REPO"
        ARG_URL="$2"
        shift 2
        ;;
      --token)
        [[ $# -ge 2 ]] || die "--token needs a value. Get one from the repository: Settings -> Actions -> Runners -> New self-hosted runner."
        ARG_TOKEN="$2"
        shift 2
        ;;
      --labels)
        [[ $# -ge 2 ]] || die "--labels needs a value, e.g. --labels self-hosted,linux,teleport-deploy"
        ARG_LABELS="$2"
        shift 2
        ;;
      --runner-name)
        [[ $# -ge 2 ]] || die "--runner-name needs a value, e.g. --runner-name teleport-deploy-01"
        ARG_RUNNER_NAME="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "Unknown argument: '$1'. See the usage above."
        ;;
    esac
  done
}

# Validate what we were given, and explain how to fix anything missing. We check
# every problem we can before doing any work, so the operator does not discover
# a typo three minutes into a package install.
validate_args() {
  local problems=()

  [[ -n "$ARG_URL" ]] || problems+=("--url is required (the repository URL, e.g. https://github.com/OWNER/REPO)")

  if [[ -z "$ARG_TOKEN" ]]; then
    problems+=("--token is required (or set RUNNER_TOKEN). Get a fresh one from: repo -> Settings -> Actions -> Runners -> New self-hosted runner. It expires in ~1 hour.")
  fi

  [[ -n "$ARG_LABELS" ]] || problems+=("--labels is required (e.g. --labels self-hosted,linux,teleport-deploy). It must match the workflow's runs-on.")

  # A repo URL, not an org URL and not an SSH remote: the runner API endpoints
  # differ, and getting this wrong produces a confusing 404 much later.
  if [[ -n "$ARG_URL" && ! "$ARG_URL" =~ ^https://[^/]+/[^/]+/[^/]+/?$ ]]; then
    problems+=("--url '${ARG_URL}' does not look like a repository URL. Expected https://github.com/OWNER/REPO (not an SSH remote, not an organisation URL, no trailing path).")
  fi

  if [[ ${#problems[@]} -gt 0 ]]; then
    printf '\n[ install-runner ] ERROR: cannot continue:\n\n' >&2
    local p
    for p in "${problems[@]}"; do
      printf '  * %s\n' "$p" >&2
    done
    printf '\nRun "%s --help" for the full flag reference.\n\n' "$0" >&2
    exit 2
  fi

  # Default the runner name to the short hostname. Distinct hostnames are the
  # norm, and this keeps the GitHub Runners list readable.
  if [[ -z "$ARG_RUNNER_NAME" ]]; then
    ARG_RUNNER_NAME="$(hostname -s 2>/dev/null || hostname)"
    log "No --runner-name given; using this machine's hostname: ${ARG_RUNNER_NAME}"
  fi
}

# =============================================================================
#  STEP 0 -- ENVIRONMENT CHECKS
# =============================================================================

# We need root to install packages, create a user, and install a systemd unit.
# (The runner process itself will NOT be root -- that is a separate check.)
assert_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "This installer must run as root, because it installs packages, creates the '${RUNNER_USER}' user, and installs a systemd service. Re-run it with sudo:
    sudo $0 <same flags>
  (The runner process itself will run as the unprivileged '${RUNNER_USER}' user, never as root.)"
  fi
}

# ---- Step 1a: detect the distribution family -------------------------------
#
# We support exactly two families and refuse everything else clearly, rather
# than guessing and half-working. /etc/os-release is the standard, machine
# readable answer on every modern Linux; ID_LIKE catches derivatives (Rocky,
# Alma, Mint, Pop!_OS, ...) without us maintaining a list of every downstream.
DISTRO_FAMILY=""   # "debian" or "rhel"
PKG_MANAGER=""     # "apt-get", "dnf" or "yum"
DISTRO_PRETTY=""   # for logging only

detect_distro() {
  [[ -r /etc/os-release ]] || die "/etc/os-release is missing, so I cannot identify this Linux distribution. This script supports the Debian/Ubuntu and RHEL families only."

  # shellcheck disable=SC1091  # a runtime file, not available to shellcheck
  . /etc/os-release

  DISTRO_PRETTY="${PRETTY_NAME:-${NAME:-unknown} ${VERSION_ID:-}}"
  local id="${ID:-}"
  local id_like="${ID_LIKE:-}"

  case " ${id} ${id_like} " in
    *" debian "*|*" ubuntu "*)
      DISTRO_FAMILY="debian"
      PKG_MANAGER="apt-get"
      ;;
    *" rhel "*|*" fedora "*|*" centos "*)
      DISTRO_FAMILY="rhel"
      # dnf on anything current; yum only on old RHEL/CentOS 7-era systems.
      if command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
      elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
      else
        die "This looks like a RHEL-family system (${DISTRO_PRETTY}) but neither dnf nor yum is installed, so I cannot install packages. Install one, or install curl/tar/git/jq/openssl/gettext by hand and re-run."
      fi
      ;;
    *)
      die "Unsupported Linux distribution: ${DISTRO_PRETTY} (ID='${id}', ID_LIKE='${id_like}').
  Supported: the Debian/Ubuntu family (Debian, Ubuntu, Mint, ...) and the RHEL
  family (RHEL, Rocky, Alma, CentOS Stream, Fedora, Amazon Linux).
  Nothing about a runner is distro-specific except package installation, so
  porting this script is mostly a matter of adding a case here."
      ;;
  esac

  log "Distribution: ${DISTRO_PRETTY}  (family: ${DISTRO_FAMILY}, package manager: ${PKG_MANAGER})"
}

# ---- Step 1b: detect the CPU architecture ---------------------------------
#
# Annoyingly, the three projects we download from spell architectures three
# different ways, so we record all three spellings once and use the right one
# per download instead of scattering `if` statements through the script:
#   kubectl/helm : amd64 / arm64
#   actions/runner: x64  / arm64
ARCH_RAW=""        # what uname -m said, for error messages
ARCH_GO=""         # amd64 | arm64   (kubectl, helm)
ARCH_RUNNER=""     # x64   | arm64   (actions/runner)

detect_arch() {
  ARCH_RAW="$(uname -m)"

  case "$ARCH_RAW" in
    x86_64|amd64)
      ARCH_GO="amd64"
      ARCH_RUNNER="x64"
      ;;
    aarch64|arm64)
      ARCH_GO="arm64"
      ARCH_RUNNER="arm64"
      ;;
    *)
      die "Unsupported CPU architecture: '${ARCH_RAW}'.
  Supported: x86_64 (amd64) and aarch64 (arm64).
  In particular 32-bit ARM (armv7l/armhf) and 32-bit x86 (i686) are NOT
  supported -- GitHub does not publish a Linux runner for them, so there is no
  binary to install. Use a 64-bit VM."
      ;;
  esac

  log "Architecture: ${ARCH_RAW}  (downloads will use '${ARCH_GO}' / runner '${ARCH_RUNNER}')"
}

# We drop privileges to run anything that belongs to the runner. runuser is part
# of util-linux and is present on both families without needing sudo installed;
# sudo is the fallback for the rare image that lacks runuser.
PRIV_DROP_CMD=()

detect_priv_drop() {
  if command -v runuser >/dev/null 2>&1; then
    PRIV_DROP_CMD=(runuser -u "$RUNNER_USER" --)
  elif command -v sudo >/dev/null 2>&1; then
    PRIV_DROP_CMD=(sudo -u "$RUNNER_USER" --)
  else
    die "Neither 'runuser' nor 'sudo' is available, so I cannot run the runner's own commands as the unprivileged '${RUNNER_USER}' user. Install util-linux (runuser) or sudo and re-run."
  fi
}

# Run a command as the runner user, from the runner directory.
as_runner() {
  "${PRIV_DROP_CMD[@]}" "$@"
}

# systemd is how we keep the runner alive across reboots. Check early: finding
# out at the last step is a waste of the operator's time.
assert_systemd() {
  if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
    die "systemd does not appear to be running on this machine (no systemctl, or /run/systemd/system is absent).
  This installer uses the runner's bundled svc.sh, which installs a systemd
  unit, so the runner survives reboots. Common cause: this is an application
  container rather than a VM or a systemd-enabled LXC container. Per spec
  section 9.1 the MVP targets a real (or system-container) Linux VM."
  fi
}

# =============================================================================
#  STEP 2 -- BASE PACKAGES
# =============================================================================
#
# What each one is for -- nothing here is speculative:
#   curl     downloading the runner, kubectl and helm (and used by workflows)
#   tar      unpacking the runner and helm archives
#   git      actions/checkout shells out to git on the runner
#   jq       the deploy workflow parses kubectl JSON output with it
#   openssl  the workflow inspects the TLS cert's SANs with it
#   gettext  provides `envsubst`, which templates helm/values.yaml
#
# `sha256sum` (coreutils) is also required and is present on both families out
# of the box; we assert it rather than install it.

install_base_packages() {
  section "Step 2/8: base packages (curl, tar, git, jq, openssl, envsubst)"

  # Happily, these six (plus ca-certificates, without which curl cannot verify
  # any TLS certificate) are spelled the same on both families. `gettext` is the
  # package that provides `envsubst` on Debian and on RHEL alike -- newer RHEL
  # also offers a slimmer `gettext-envsubst`, but plain `gettext` works
  # everywhere, so we use the portable name.
  local packages=(curl tar git jq openssl gettext ca-certificates)

  # Idempotency: figure out what is genuinely missing first, so a re-run on a
  # fully provisioned box does not touch the package database at all.
  local missing=()
  local pkg
  for pkg in "${packages[@]}"; do
    if ! is_package_installed "$pkg"; then
      missing+=("$pkg")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    log "All base packages already installed -- nothing to do."
  else
    log "Installing: ${missing[*]}"
    case "$PKG_MANAGER" in
      apt-get)
        # noninteractive + -y so this never blocks waiting for a prompt.
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
        ;;
      dnf|yum)
        "$PKG_MANAGER" install -y "${missing[@]}"
        ;;
    esac
  fi

  # Belt and braces: confirm the commands we actually care about now exist. A
  # package can be installed and still not provide what we expected.
  local cmd
  for cmd in curl tar git jq openssl envsubst sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 \
      || die "'${cmd}' is still not on PATH after package installation. Install it by hand and re-run. (envsubst comes from the 'gettext' package; sha256sum from 'coreutils'.)"
  done
  log "Verified on PATH: curl tar git jq openssl envsubst sha256sum"
}

# Is a package installed? Query the package manager rather than looking for a
# binary, so we do not reinstall things on every run.
is_package_installed() {
  local pkg="$1"
  case "$DISTRO_FAMILY" in
    debian)
      # dpkg-query prints e.g. "install ok installed" for a real installation.
      [[ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)" == "install ok installed" ]]
      ;;
    rhel)
      rpm -q "$pkg" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

# =============================================================================
#  CHECKSUM VERIFICATION HELPER
# =============================================================================
#
# Used for every download. This is the whole reason the hashes are pinned at the
# top of the file: it proves the bytes we got are the bytes the publisher
# published, even if a mirror, proxy or DNS answer along the way is hostile.

verify_sha256() {
  local file="$1" expected="$2" description="$3"

  if [[ -z "$expected" || "$expected" == "UNKNOWN" ]]; then
    die "No known-good SHA-256 is recorded for ${description}. I will not install an unverified binary.
  Fix: look the checksum up from the publisher (see the 'PINNED VERSIONS AND
  CHECKSUMS' comment block near the top of this script for the exact URLs) and
  set it in this file. Do not compute the hash of the file you just downloaded
  -- that proves nothing about whether it is the right file."
  fi

  local actual
  actual="$(sha256sum "$file" | awk '{print $1}')"

  if [[ "$actual" != "$expected" ]]; then
    die "SHA-256 mismatch for ${description} -- refusing to continue.
    expected: ${expected}
    actual:   ${actual}
  This means the file you downloaded is not the file this script expects. Either
  the pinned checksum in this script is stale/wrong for the pinned version, or
  the download was tampered with or truncated. Do NOT work around this by
  editing the hash to match; verify the value against the publisher first."
  fi

  log "SHA-256 verified for ${description}: ${actual}"
}

# A curl invocation with sane, explicit behaviour: fail on HTTP errors, follow
# redirects (GitHub and dl.k8s.io both redirect to a CDN), retry transient
# failures, and never wait forever.
download() {
  local url="$1" dest="$2"
  log "Downloading ${url}"
  curl --fail --location --silent --show-error \
       --retry 3 --retry-delay 2 --retry-connrefused \
       --connect-timeout 20 --max-time 900 \
       --output "$dest" "$url" \
    || die "Download failed: ${url}
  Check outbound HTTPS from this VM (this is the ONLY network direction that
  matters -- see the top of this script). A proxy that intercepts TLS will also
  break this; set the standard https_proxy/HTTPS_PROXY variables if you use one."
}

# =============================================================================
#  STEP 3 -- PINNED kubectl AND helm
# =============================================================================

install_kubectl() {
  section "Step 3/8 (a): kubectl ${KUBECTL_VERSION}"

  # Idempotency: if the pinned version is already in place, leave it alone.
  if [[ -x "${BIN_DIR}/kubectl" ]] \
     && "${BIN_DIR}/kubectl" version --client=true -o json 2>/dev/null | grep -q "\"gitVersion\": \"${KUBECTL_VERSION}\""; then
    log "kubectl ${KUBECTL_VERSION} is already installed at ${BIN_DIR}/kubectl -- skipping."
    return 0
  fi

  local expected
  case "$ARCH_GO" in
    amd64) expected="$KUBECTL_SHA256_AMD64" ;;
    arm64) expected="$KUBECTL_SHA256_ARM64" ;;
    *)     die "internal error: unexpected ARCH_GO='${ARCH_GO}'" ;;
  esac

  local tmp="${WORK_DIR}/kubectl"
  download "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_GO}/kubectl" "$tmp"
  verify_sha256 "$tmp" "$expected" "kubectl ${KUBECTL_VERSION} (linux/${ARCH_GO})"

  # install(1) does mode + ownership + move in one atomic-ish step.
  install -o root -g root -m 0755 "$tmp" "${BIN_DIR}/kubectl"
  log "Installed ${BIN_DIR}/kubectl"
}

install_helm() {
  section "Step 3/8 (b): helm ${HELM_VERSION}"

  if [[ -x "${BIN_DIR}/helm" ]] \
     && "${BIN_DIR}/helm" version --short 2>/dev/null | grep -q "^${HELM_VERSION}"; then
    log "helm ${HELM_VERSION} is already installed at ${BIN_DIR}/helm -- skipping."
    return 0
  fi

  local expected
  case "$ARCH_GO" in
    amd64) expected="$HELM_SHA256_AMD64" ;;
    arm64) expected="$HELM_SHA256_ARM64" ;;
    *)     die "internal error: unexpected ARCH_GO='${ARCH_GO}'" ;;
  esac

  local tarball="${WORK_DIR}/helm.tar.gz"
  download "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH_GO}.tar.gz" "$tarball"
  verify_sha256 "$tarball" "$expected" "helm ${HELM_VERSION} (linux/${ARCH_GO})"

  # The archive contains linux-<arch>/helm plus licence files; we only want the
  # binary, so extract just that member.
  local extract_dir="${WORK_DIR}/helm-extract"
  mkdir -p "$extract_dir"
  tar -xzf "$tarball" -C "$extract_dir" "linux-${ARCH_GO}/helm"
  install -o root -g root -m 0755 "${extract_dir}/linux-${ARCH_GO}/helm" "${BIN_DIR}/helm"
  log "Installed ${BIN_DIR}/helm"
}

# Print what we ended up with. The deploy workflow's preflight will print these
# too, but seeing them here confirms the install before you go near GitHub.
print_tool_versions() {
  section "Step 3/8 (c): installed tool versions"
  log "kubectl: $("${BIN_DIR}/kubectl" version --client=true -o yaml 2>/dev/null | awk '/gitVersion/ {print $2; exit}')"
  log "helm:    $("${BIN_DIR}/helm" version --short 2>/dev/null)"
  log "git:     $(git --version)"
  log "jq:      $(jq --version)"
  log "openssl: $(openssl version)"
}

# =============================================================================
#  STEP 4 -- THE UNPRIVILEGED RUNNER USER
# =============================================================================

create_runner_user() {
  section "Step 4/8: unprivileged '${RUNNER_USER}' user"

  if id -u "$RUNNER_USER" >/dev/null 2>&1; then
    log "User '${RUNNER_USER}' already exists -- leaving it as it is."
  else
    log "Creating user '${RUNNER_USER}' with home directory ${RUNNER_USER_HOME}"
    # --system would give a system account without a real home and with
    # /usr/sbin/nologin; the runner wants a normal home directory (it writes
    # _work, _diag, .credentials there) so we create a regular locked account.
    #   --create-home  make ${RUNNER_USER_HOME}
    #   --shell bash   the runner executes shell steps as this user
    # No password is ever set, so interactive login by password is impossible.
    useradd --create-home --home-dir "$RUNNER_USER_HOME" --shell /bin/bash "$RUNNER_USER" \
      || die "Failed to create the '${RUNNER_USER}' user. Create it by hand (useradd --create-home ${RUNNER_USER}) and re-run."
  fi

  # Home directory sanity: a pre-existing account might not have one.
  if [[ ! -d "$RUNNER_USER_HOME" ]]; then
    log "Home directory ${RUNNER_USER_HOME} is missing; creating it."
    mkdir -p "$RUNNER_USER_HOME"
    chown "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_USER_HOME"
    chmod 0750 "$RUNNER_USER_HOME"
  fi

  # Deliberate non-decision: we do NOT grant this user sudo, and we do NOT add
  # it to the docker group. Both would hand every workflow that runs on this
  # machine a straight path to root. If a future workflow genuinely needs a
  # privileged action, grant exactly that one command via a narrow sudoers rule
  # -- as a conscious decision, not as a side effect of this installer.
  log "User '${RUNNER_USER}' has no sudo rights and no docker group membership -- by design."
}

# ---- Step 4 (continued): refuse to run the runner as root -----------------
#
# WHY THIS MATTERS, at length, because it is the security crux of the whole
# setup:
#
# A self-hosted runner executes whatever the workflow file says to execute. The
# workflow file lives in the repository, so anyone who can change a workflow --
# or, if the repository ever accepts workflow runs from forks, potentially an
# outsider -- can run arbitrary commands on this machine. That is not a bug in
# GitHub Actions; it is the entire point of a runner.
#
# So the only sane posture is: assume workflow code is untrusted, and give it
# the smallest possible account. As root, one careless (or hostile) workflow
# line owns the whole VM: it can read every credential on the box, install a
# persistent backdoor, tamper with the systemd units, and -- most relevant here
# -- steal the Kubernetes credentials that this VM will hold, which are keys to
# your Teleport cluster.
#
# GitHub agrees: actions/runner's config.sh refuses to run as root unless you
# set RUNNER_ALLOW_RUNASROOT. This script never sets that variable, and you
# should not either.
assert_runner_is_not_root() {
  local runner_uid
  runner_uid="$(id -u "$RUNNER_USER")"

  if [[ "$runner_uid" -eq 0 ]]; then
    die "The account '${RUNNER_USER}' has UID 0 (root). I refuse to configure a runner that executes workflow code as root.

  Why: a self-hosted runner runs whatever the repository's workflow files say to
  run. Treat that code as untrusted. As root, a single malicious or careless
  workflow step owns this entire VM -- including the Kubernetes credentials this
  machine will hold, which are effectively keys to your Teleport cluster. As an
  unprivileged user, the damage is bounded by that user's (deliberately tiny)
  permissions.

  Fix: use a normal unprivileged account. Delete the UID 0 '${RUNNER_USER}'
  account and re-run this script so it can create a proper one.

  Note also that GitHub's own config.sh refuses to run as root unless
  RUNNER_ALLOW_RUNASROOT is set. This script never sets it. Neither should you."
  fi

  log "Runner will execute as '${RUNNER_USER}' (uid ${runner_uid}), not root -- correct."
}

# =============================================================================
#  STEP 5 -- DOWNLOAD AND EXTRACT actions/runner
# =============================================================================

install_runner_software() {
  section "Step 5/8: actions/runner ${RUNNER_VERSION}"

  mkdir -p "$RUNNER_DIR"
  chown "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_DIR"
  chmod 0750 "$RUNNER_DIR"

  # Idempotency: config.sh and svc.sh present means the archive is already
  # unpacked here. Re-extracting over a *registered* runner risks clobbering its
  # state, so we do not.
  if [[ -x "${RUNNER_DIR}/config.sh" && -x "${RUNNER_DIR}/svc.sh" ]]; then
    log "Runner software is already extracted in ${RUNNER_DIR} -- skipping download."
    log "(GitHub auto-updates the runner in place after registration, so the"
    log " version on disk may legitimately be newer than the pinned ${RUNNER_VERSION}.)"
    return 0
  fi

  local expected
  case "$ARCH_RUNNER" in
    x64)   expected="$RUNNER_SHA256_X64" ;;
    arm64) expected="$RUNNER_SHA256_ARM64" ;;
    *)     die "internal error: unexpected ARCH_RUNNER='${ARCH_RUNNER}'" ;;
  esac

  local archive_name="actions-runner-linux-${ARCH_RUNNER}-${RUNNER_VERSION}.tar.gz"
  local tarball="${WORK_DIR}/${archive_name}"

  download "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${archive_name}" "$tarball"
  verify_sha256 "$tarball" "$expected" "actions/runner ${RUNNER_VERSION} (linux-${ARCH_RUNNER})"

  log "Extracting into ${RUNNER_DIR}"
  tar -xzf "$tarball" -C "$RUNNER_DIR"
  # Everything under the runner directory must belong to the runner user: it
  # writes _work/, _diag/ and its credential files there at run time.
  chown -R "${RUNNER_USER}:${RUNNER_USER}" "$RUNNER_DIR"

  # The runner is a .NET application and needs a few native libraries (ICU,
  # libkrb5, zlib, ...). GitHub ships a script that installs exactly the right
  # ones per distro; using it beats us maintaining that list. It needs root,
  # which is why it runs here and not as the runner user.
  if [[ -x "${RUNNER_DIR}/bin/installdependencies.sh" ]]; then
    log "Installing the runner's native dependencies via bin/installdependencies.sh"
    ( cd "$RUNNER_DIR" && ./bin/installdependencies.sh ) \
      || die "installdependencies.sh failed. It installs the .NET native libraries the runner needs (ICU, libkrb5, ...). Read its output above; usually it is a package repository problem on this VM."
  else
    warn "bin/installdependencies.sh not found in the runner archive; continuing, but if the runner fails to start with a .NET/ICU error, install libicu by hand."
  fi
}

# =============================================================================
#  STEP 6 -- REGISTER THE RUNNER WITH GITHUB
# =============================================================================
#
# About the registration token (--token / RUNNER_TOKEN):
#
#   It comes from the repository UI:
#     repo -> Settings -> Actions -> Runners -> "New self-hosted runner"
#   and appears in the `./config.sh --url ... --token ...` line GitHub shows.
#
#   It EXPIRES IN ABOUT ONE HOUR. That is by design and it is a good thing: it
#   is a narrow, short-lived, single-purpose credential whose only power is to
#   register one runner. It is NOT a personal access token and NOT a long-lived
#   secret, so do not treat it as one, and do not go looking for a permanent
#   token to use instead. If registration fails with an "Invalid configuration"
#   or 404 error, the overwhelmingly likely cause is that the token went stale:
#   copy a fresh one from that same page and re-run.
#
#   During registration the runner exchanges this token for its own long-lived
#   credential, stored in ${RUNNER_DIR}/.credentials* with tight permissions and
#   owned by the runner user. After that, the registration token is useless.
#
# Flags we pass to config.sh, and why:
#   --unattended   never prompt; this must work non-interactively
#   --replace      if a runner with this name already exists in the repo,
#                  replace it. This is what makes rebuilding a VM painless.
#   --labels       what the workflow's `runs-on:` selects on
#   --name         the display name in the Runners list

register_runner() {
  section "Step 6/8: register with GitHub"

  # ---- Idempotency, the important case -----------------------------------
  # A configured runner leaves a `.runner` file (its config) in RUNNER_DIR. If
  # that exists we are already registered, so we stop here rather than trying to
  # re-register -- re-registering would need a fresh token and would pointlessly
  # rotate the runner's credentials. This is what lets you re-run this script
  # safely, and without a token, after the first successful install.
  if [[ -f "${RUNNER_DIR}/.runner" ]]; then
    ALREADY_REGISTERED="yes"
    log "This runner is ALREADY REGISTERED (found ${RUNNER_DIR}/.runner) -- skipping registration."
    log "Existing registration:"
    # .runner is JSON; show the interesting fields. It contains no secret --
    # the credentials live in the separate .credentials files, which we never
    # read or print.
    if jq -e . "${RUNNER_DIR}/.runner" >/dev/null 2>&1; then
      log "  name:      $(jq -r '.agentName // "unknown"' "${RUNNER_DIR}/.runner")"
      log "  repo/url:  $(jq -r '.gitHubUrl // .serverUrl // "unknown"' "${RUNNER_DIR}/.runner")"
    fi
    log "To change the labels, name or repository, remove the old registration first:"
    log "  cd ${RUNNER_DIR} && sudo ./svc.sh stop && sudo ./svc.sh uninstall"
    log "  sudo -u ${RUNNER_USER} ./config.sh remove --token <a fresh removal token>"
    log "  then re-run this script with the new flags."
    return 0
  fi

  log "Registering runner '${ARG_RUNNER_NAME}' with ${ARG_URL}"
  log "Labels: ${ARG_LABELS}"

  # Run config.sh as the unprivileged runner user, from the runner directory, so
  # every file it creates (including .credentials) is owned by that user and not
  # by root. Note the token appears in this process's argument list for the few
  # seconds config.sh runs; on a single-tenant runner VM that is acceptable, and
  # the token is short-lived and single-purpose anyway.
  # (The subshell `cd` is inherited by the dropped-privilege child, which is how
  # `./config.sh` resolves; both runuser and sudo preserve the working
  # directory.)
  if ! ( cd "$RUNNER_DIR" && as_runner ./config.sh \
        --unattended \
        --replace \
        --url    "$ARG_URL" \
        --token  "$ARG_TOKEN" \
        --name   "$ARG_RUNNER_NAME" \
        --labels "$ARG_LABELS" ); then
    die "Runner registration failed. The three usual causes, in order of likelihood:

  1. THE TOKEN EXPIRED. Registration tokens last about an hour. Get a fresh one:
     ${ARG_URL}/settings/actions/runners/new  (Settings -> Actions -> Runners ->
     New self-hosted runner) and copy the value from the --token argument shown.

  2. The --url is wrong. It must be the repository URL, exactly like
     https://github.com/OWNER/REPO -- and you must have admin rights on that
     repository.

  3. Outbound HTTPS to github.com / api.github.com is blocked, or a TLS-
     intercepting proxy is in the way. Test with:
       curl -sS -o /dev/null -w '%{http_code}\\n' https://api.github.com
     Remember: only OUTBOUND access is needed. No inbound port is involved."
  fi

  log "Registration succeeded. The short-lived token has now been exchanged for"
  log "the runner's own credential in ${RUNNER_DIR}/.credentials (owned by"
  log "'${RUNNER_USER}', not readable by others). The token itself is now spent."
}

# =============================================================================
#  STEP 7 -- INSTALL AND START THE SYSTEMD SERVICE
# =============================================================================
#
# svc.sh is bundled with the runner. `svc.sh install <user>` generates a systemd
# unit (named actions.runner.<owner>-<repo>.<runner-name>.service) that runs the
# runner as <user> and starts at boot; `svc.sh start` starts it now. We use it
# rather than hand-writing a unit because GitHub keeps it working across runner
# versions.

install_runner_service() {
  section "Step 7/8: systemd service"

  # svc.sh records the unit name in a `.service` file in RUNNER_DIR. Its
  # presence is our idempotency check.
  if [[ -f "${RUNNER_DIR}/.service" ]]; then
    SERVICE_NAME="$(tr -d '[:space:]' < "${RUNNER_DIR}/.service")"
    log "Service '${SERVICE_NAME}' is already installed -- not reinstalling."
  else
    log "Installing the systemd service to run the runner as '${RUNNER_USER}'"
    # svc.sh install must run as root (it writes into /etc/systemd/system) and
    # takes the target user as its argument -- which is how the service ends up
    # running unprivileged even though we install it as root.
    ( cd "$RUNNER_DIR" && ./svc.sh install "$RUNNER_USER" ) \
      || die "'svc.sh install ${RUNNER_USER}' failed. Read its output above. If it complains about systemd, confirm this machine really runs systemd (systemctl is-system-running)."

    [[ -f "${RUNNER_DIR}/.service" ]] \
      || die "svc.sh reported success but did not write ${RUNNER_DIR}/.service, so I cannot determine the systemd unit name. Inspect 'systemctl list-units \"actions.runner.*\"'."
    SERVICE_NAME="$(tr -d '[:space:]' < "${RUNNER_DIR}/.service")"
    log "Installed unit: ${SERVICE_NAME}"
  fi

  # `svc.sh install` already enables the unit at boot; make sure it is actually
  # running now. Starting an already-started service is harmless, which keeps
  # this re-runnable.
  log "Starting/ensuring the service is running"
  ( cd "$RUNNER_DIR" && ./svc.sh start ) \
    || die "'svc.sh start' failed. Inspect the service with:
    systemctl status ${SERVICE_NAME}
    journalctl -u ${SERVICE_NAME} -n 50 --no-pager"

  # Give systemd a breath to settle before we report status in the summary.
  sleep 2
}

# =============================================================================
#  STEP 8 -- SUMMARY
# =============================================================================

print_summary() {
  local service_state="unknown" service_enabled="unknown"

  if [[ -n "$SERVICE_NAME" ]]; then
    service_state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
    service_enabled="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
    [[ -n "$service_state" ]] || service_state="unknown"
    [[ -n "$service_enabled" ]] || service_enabled="unknown"
  fi

  section "Step 8/8: summary"

  cat <<EOF

  Runner name      : ${ARG_RUNNER_NAME}
  Repository       : ${ARG_URL}
  Labels           : ${ARG_LABELS}
  Runs as user     : ${RUNNER_USER} (unprivileged -- never root)
  Runner directory : ${RUNNER_DIR}
  Registration     : $([[ "$ALREADY_REGISTERED" == "yes" ]] && echo "already registered before this run (unchanged)" || echo "registered during this run")
  systemd unit     : ${SERVICE_NAME:-<none>}
  Service active   : ${service_state}
  Start at boot    : ${service_enabled}
  kubectl          : ${BIN_DIR}/kubectl ($("${BIN_DIR}/kubectl" version --client=true -o yaml 2>/dev/null | awk '/gitVersion/ {print $2; exit}'))
  helm             : ${BIN_DIR}/helm ($("${BIN_DIR}/helm" version --short 2>/dev/null))

  The runner should now appear as "Idle" at:
    ${ARG_URL%/}/settings/actions/runners

  Reminder: NO INBOUND PORTS are open or needed. The runner polls GitHub over
  outbound HTTPS. If it does not show up in that list, the problem is egress,
  not ingress.

===============================================================================
  NOT DONE YET -- KUBERNETES ACCESS IS A SEPARATE STEP
===============================================================================

  This runner CAN accept jobs. It CANNOT deploy anything yet.

  This script installed kubectl and helm. It did NOT authenticate them to any
  cluster, and by design it never touches a credential (spec sections 3 and 10
  item 5). Kubernetes access is out of scope for this project and is your next,
  separate task.

  Do NOT run the deploy workflow until this command succeeds:

      sudo -u ${RUNNER_USER} kubectl get ns <your-teleport-namespace>

  It must succeed as the '${RUNNER_USER}' user, because that is the user the
  workflow's steps run as. Working as root or as yourself proves nothing.

  How operators usually satisfy this (pick one, all out of scope here):
    * Teleport Machine & Workload Identity -- 'tbot' running on this VM, from a
      SEPARATE Teleport cluster, writing short-lived credentials the runner
      picks up. This is the recommended option: no long-lived secret ever sits
      on this machine.
    * A kubeconfig readable by '${RUNNER_USER}'.
    * An in-cluster ServiceAccount, if this runner runs inside the target
      cluster.

  Minimum permissions needed in the target namespace: full CRUD on the
  resources the Teleport chart creates, 'get' on the TLS and license secrets
  (the workflow's preflight checks read their metadata), and 'pods/exec' (for
  'tctl users add'). The chart also creates cluster-scoped RBAC, so the
  credential needs 'escalate'/'bind' on ClusterRoles -- or you pre-create them
  and set rbac.create=false.

  THEN, and only then: run deploy.yml with dry_run: true as your first test.

===============================================================================

  Useful commands from here:
    systemctl status ${SERVICE_NAME:-actions.runner.*}
    journalctl -u ${SERVICE_NAME:-actions.runner.*} -f
    cd ${RUNNER_DIR} && sudo ./svc.sh stop | start | status | uninstall

EOF
}

# =============================================================================
#  MAIN
# =============================================================================

# State shared between steps and the summary.
SERVICE_NAME=""
ALREADY_REGISTERED="no"
WORK_DIR=""

# Clean up the scratch directory on any exit path, so a failed run does not
# leave half-downloaded binaries lying around.
cleanup() {
  [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
  return 0
}

main() {
  parse_args "$@"
  validate_args

  section "Step 1/8: environment checks"
  assert_root
  detect_distro
  detect_arch
  detect_priv_drop
  assert_systemd

  WORK_DIR="$(mktemp -d /tmp/install-runner.XXXXXX)"
  trap cleanup EXIT

  install_base_packages

  install_kubectl
  install_helm
  print_tool_versions

  create_runner_user
  assert_runner_is_not_root

  install_runner_software
  register_runner
  install_runner_service
  print_summary
}

main "$@"
