#!/usr/bin/env bash
#
# Builds iTorrent and installs it on a connected iPhone or iPad.
#
# Why this builds from source instead of installing the .ipa from dist/:
# an unsigned archive cannot be installed on any device. iOS only runs code
# signed against a provisioning profile that lists the target device's UDID,
# and only Apple issues those, against an Apple ID with two-factor auth. Any
# script that re-signed the prebuilt archive would still need a profile the
# user does not have. Building instead lets xcodebuild request that profile
# automatically, which is the part that actually works.
#
# Usage: ./install.sh [options]   (--help for the list)

set -euo pipefail

readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly XCODE_PROJECT="$PROJECT_DIR/iTorrent/iTorrent.xcodeproj"
readonly SCHEME="iTorrent"
readonly MINIMUM_IOS=17

DEVICE_UDID=""
BUNDLE_ID=""
TEAM_ID=""
CONFIGURATION="Debug"
SHOULD_LAUNCH=1
BUILD_DIR="$PROJECT_DIR/build"

# ---------------------------------------------------------------- output ----

if [[ -t 1 ]]; then
	readonly BOLD=$'\033[1m' RED=$'\033[31m' GREEN=$'\033[32m'
	readonly YELLOW=$'\033[33m' BLUE=$'\033[34m' DIM=$'\033[2m' RESET=$'\033[0m'
else
	readonly BOLD="" RED="" GREEN="" YELLOW="" BLUE="" DIM="" RESET=""
fi

step_number=0
step()  { step_number=$((step_number + 1)); printf '\n%s[%d/7] %s%s\n' "$BOLD$BLUE" "$step_number" "$1" "$RESET"; }
ok()    { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
info()  { printf '  %s\n' "$1"; }
note()  { printf '  %s%s%s\n' "$DIM" "$1" "$RESET"; }
warn()  { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }

# Prints the problem, then how to fix it, then leaves.
fail() {
	printf '\n%s✗ %s%s\n' "$RED$BOLD" "$1" "$RESET" >&2
	shift
	for line in "$@"; do printf '  %s\n' "$line" >&2; done
	printf '\n' >&2
	exit 1
}

usage() {
	cat <<EOF
${BOLD}iTorrent installer${RESET}

Builds the app and installs it on a connected iPhone or iPad, signing it with
your own Apple ID.

${BOLD}Usage${RESET}
  ./install.sh [options]

${BOLD}Options${RESET}
  --device UDID      Install on this device (default: the only connected one)
  --bundle-id ID     Bundle identifier to sign with
  --team TEAMID      Apple Developer team (default: taken from your certificate)
  --release          Build Release instead of Debug
  --no-launch        Install without launching
  --list-devices     Show connected devices and exit
  -h, --help         This text

${BOLD}Requirements${RESET}
  * macOS with Xcode installed (not just the Command Line Tools)
  * An Apple ID added in Xcode → Settings → Accounts
  * An iPhone or iPad on iOS $MINIMUM_IOS or later, connected by cable,
    unlocked, trusting this computer, with Developer Mode turned on
EOF
}

# ------------------------------------------------------------- arguments ----

while [[ $# -gt 0 ]]; do
	case "$1" in
		--device)       DEVICE_UDID="${2:-}"; shift 2 ;;
		--bundle-id)    BUNDLE_ID="${2:-}"; shift 2 ;;
		--team)         TEAM_ID="${2:-}"; shift 2 ;;
		--release)      CONFIGURATION="Release"; shift ;;
		--no-launch)    SHOULD_LAUNCH=0; shift ;;
		--list-devices) LIST_ONLY=1; shift ;;
		-h|--help)      usage; exit 0 ;;
		*)              fail "Unknown option: $1" "Run ./install.sh --help for the list." ;;
	esac
done

# ------------------------------------------------------------ 1. the mac ----

step "Checking macOS and Xcode"

[[ "$(uname -s)" == "Darwin" ]] || fail "This script only runs on macOS." \
	"Signing and installing iOS apps needs Xcode, which is macOS only."

command -v xcrun >/dev/null 2>&1 || fail "The Xcode command line tools are missing." \
	"Install Xcode from the App Store, then run:" \
	"  sudo xcode-select -s /Applications/Xcode.app"

developer_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ "$developer_dir" != *".app/Contents/Developer" ]]; then
	fail "xcode-select points at the Command Line Tools, not at Xcode." \
		"Currently: ${developer_dir:-nothing}" \
		"" \
		"Building for a device needs the full Xcode. Install it from the App" \
		"Store, then point the tools at it:" \
		"  sudo xcode-select -s /Applications/Xcode.app"
fi

xcode_version="$(xcodebuild -version 2>/dev/null | head -1 || true)"
[[ -n "$xcode_version" ]] || fail "xcodebuild will not run." \
	"Open Xcode once so it can finish installing its components, then retry."
ok "$xcode_version"

[[ -d "$XCODE_PROJECT" ]] || fail "Cannot find the Xcode project." \
	"Expected it at: $XCODE_PROJECT" \
	"Run this script from inside a clone of the repository."
ok "Project found"

# -------------------------------------------------------- 2. the account ----

step "Checking your signing certificate"

identity="$(security find-identity -v -p codesigning 2>/dev/null \
	| grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)"

[[ -n "$identity" ]] || fail "No Apple Development certificate in your keychain." \
	"Xcode creates one for you once an Apple ID is added:" \
	"  Xcode → Settings (⌘,) → Accounts → + → Apple ID" \
	"" \
	"A free Apple ID is enough. Then run this script again."
ok "$identity"

if [[ -z "$TEAM_ID" ]]; then
	# The team id is the certificate's organisational unit.
	TEAM_ID="$(security find-certificate -c "$identity" -p 2>/dev/null \
		| openssl x509 -noout -subject 2>/dev/null \
		| tr ',' '\n' | awk -F'=' '/OU=/ {gsub(/ /, "", $2); print $2; exit}' || true)"
fi
[[ -n "$TEAM_ID" ]] || fail "Could not work out your team id from the certificate." \
	"Pass it explicitly:  ./install.sh --team ABCDE12345" \
	"You can find it in Xcode → Settings → Accounts, next to your team."
ok "Team $TEAM_ID"

# --------------------------------------------------------- 3. the device ----

step "Looking for a connected device"

devices_json="$(mktemp -t itorrent-devices)"
trap 'rm -f "$devices_json"' EXIT
xcrun devicectl list devices --json-output "$devices_json" >/dev/null 2>&1 \
	|| fail "devicectl could not talk to CoreDevice." \
		"Open Xcode once and let it finish installing components, then retry."

# Emits one tab-separated row per usable device.
read_devices() {
	python3 - "$devices_json" "$MINIMUM_IOS" <<'PY'
import json, sys

path, minimum = sys.argv[1], int(sys.argv[2])
with open(path) as handle:
    payload = json.load(handle)

for device in payload.get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties", {})
    properties = device.get("deviceProperties", {})
    connection = device.get("connectionProperties", {})

    if hardware.get("platform") != "iOS":
        continue
    if connection.get("tunnelState") == "unavailable":
        continue

    version = properties.get("osVersionNumber") or "0"
    try:
        major = int(version.split(".")[0])
    except ValueError:
        major = 0

    print("\t".join([
        device.get("identifier", ""),
        properties.get("name", "device"),
        hardware.get("marketingName", ""),
        version,
        "old" if major < minimum else "ok",
        properties.get("developerModeStatus", "unknown"),
        connection.get("tunnelState", "unknown"),
    ]))
PY
}

# Built with a loop rather than `mapfile`, which is bash 4 only: macOS still
# ships bash 3.2, where the script would die here at runtime.
device_rows=()
while IFS= read -r device_line; do
	[[ -n "$device_line" ]] && device_rows+=("$device_line")
done < <(read_devices)

if [[ ${#device_rows[@]} -eq 0 ]]; then
	fail "No iPhone or iPad found." \
		"Check all of these:" \
		"  * connected by cable (Wi-Fi pairing also works once set up in Xcode)" \
		"  * unlocked, and 'Trust This Computer' tapped" \
		"  * Developer Mode on: Settings → Privacy & Security → Developer Mode"
fi

if [[ "${LIST_ONLY:-0}" == "1" ]]; then
	printf '\n'
	for row in "${device_rows[@]}"; do
		IFS=$'\t' read -r udid name model version age mode state <<<"$row"
		printf '  %s%s%s  %s, iOS %s\n  %s%s%s\n\n' \
			"$BOLD" "$name" "$RESET" "$model" "$version" "$DIM" "$udid" "$RESET"
	done
	exit 0
fi

selected_row=""
if [[ -n "$DEVICE_UDID" ]]; then
	for row in "${device_rows[@]}"; do
		[[ "$row" == "$DEVICE_UDID"* ]] && selected_row="$row"
	done
	[[ -n "$selected_row" ]] || fail "No connected device with UDID $DEVICE_UDID." \
		"Run ./install.sh --list-devices to see what is available."
elif [[ ${#device_rows[@]} -eq 1 ]]; then
	selected_row="${device_rows[0]}"
else
	printf '\n  More than one device is connected:\n\n'
	index=1
	for row in "${device_rows[@]}"; do
		IFS=$'\t' read -r _ name model version _ _ _ <<<"$row"
		printf '    %d) %s — %s, iOS %s\n' "$index" "$name" "$model" "$version"
		index=$((index + 1))
	done
	printf '\n  Which one? [1-%d] ' "${#device_rows[@]}"
	read -r choice
	[[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#device_rows[@]} )) \
		|| fail "That is not one of the choices."
	selected_row="${device_rows[$((choice - 1))]}"
fi

IFS=$'\t' read -r DEVICE_UDID device_name device_model ios_version version_age developer_mode tunnel_state <<<"$selected_row"

[[ "$version_age" == "ok" ]] || fail "$device_name runs iOS $ios_version." \
	"iTorrent needs iOS $MINIMUM_IOS or later."

if [[ "$developer_mode" != "enabled" ]]; then
	fail "Developer Mode is off on $device_name." \
		"Turn it on:  Settings → Privacy & Security → Developer Mode" \
		"The device restarts afterwards. Then run this script again."
fi

ok "$device_name — $device_model, iOS $ios_version"
note "$DEVICE_UDID"
[[ "$tunnel_state" == "connected" ]] || warn "Connection state is '$tunnel_state'; the install may be slow to start."

# ---------------------------------------------------- 4. the bundle id ------

step "Choosing a bundle identifier"

project_team="$(grep -m1 'DEVELOPMENT_TEAM = ' "$XCODE_PROJECT/project.pbxproj" 2>/dev/null \
	| sed 's/.*DEVELOPMENT_TEAM = \([^;]*\);.*/\1/' | tr -d ' ' || true)"
project_bundle="$(grep -m1 'PRODUCT_BUNDLE_IDENTIFIER = ' "$XCODE_PROJECT/project.pbxproj" 2>/dev/null \
	| sed 's/.*PRODUCT_BUNDLE_IDENTIFIER = \([^;]*\);.*/\1/' | tr -d ' ' || true)"

if [[ -z "$BUNDLE_ID" ]]; then
	if [[ "$TEAM_ID" == "$project_team" ]]; then
		BUNDLE_ID="$project_bundle"
		ok "$BUNDLE_ID (the project's own, and it is your team)"
	else
		# An explicit App ID belongs to exactly one team on Apple's portal, so a
		# different team cannot reuse this one.
		BUNDLE_ID="com.$(id -un | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]').itorrent"
		BUNDLE_ID="${BUNDLE_ID//../.}"
		ok "$BUNDLE_ID"
		note "The project's own id belongs to another team, so it cannot be reused."
		note "Override with --bundle-id if you want a different one."
	fi
else
	ok "$BUNDLE_ID (from --bundle-id)"
fi

# ------------------------------------------------------------ 5. build -----

step "Building ($CONFIGURATION)"
info "The first build takes a few minutes. Xcode may ask for your Apple ID"
info "password so it can register the app and fetch a provisioning profile."

build_log="$(mktemp -t itorrent-build)"
trap 'rm -f "$devices_json" "$build_log"' EXIT

if ! xcodebuild \
	-project "$XCODE_PROJECT" \
	-scheme "$SCHEME" \
	-configuration "$CONFIGURATION" \
	-destination 'generic/platform=iOS' \
	-derivedDataPath "$BUILD_DIR" \
	-allowProvisioningUpdates \
	DEVELOPMENT_TEAM="$TEAM_ID" \
	PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
	build >"$build_log" 2>&1
then
	printf '\n'
	grep -E 'error:' "$build_log" | sort -u | head -10 | sed 's/^/  /' >&2 || true

	if grep -q 'No Accounts\|No profiles for' "$build_log"; then
		fail "Xcode could not get a provisioning profile." \
			"It needs an Apple ID to register the app with Apple:" \
			"  Xcode → Settings (⌘,) → Accounts → + → Apple ID" \
			"" \
			"Sign in there (two-factor included), then run this script again." \
			"Full log: $build_log"
	fi
	fail "The build failed." "Full log: $build_log"
fi

app_path="$BUILD_DIR/Build/Products/$CONFIGURATION-iphoneos/$SCHEME.app"
[[ -d "$app_path" ]] || fail "The build reported success but produced no app." \
	"Expected it at: $app_path"
ok "Built $(du -sh "$app_path" | cut -f1 | tr -d ' ')"

# ---------------------------------------------------------- 6. install -----

step "Installing on $device_name"

if ! xcrun devicectl device install app --device "$DEVICE_UDID" "$app_path" >"$build_log" 2>&1; then
	printf '\n'
	tail -12 "$build_log" | sed 's/^/  /' >&2
	fail "The install failed." \
		"Most often this means the device locked itself. Unlock it and retry." \
		"If it mentions an untrusted developer, go to:" \
		"  Settings → General → VPN & Device Management → trust your Apple ID"
fi
ok "Installed"

# ----------------------------------------------------------- 7. launch -----

step "Launching"

if [[ "$SHOULD_LAUNCH" -eq 0 ]]; then
	note "Skipped (--no-launch). Tap iTorrent on the home screen."
elif xcrun devicectl device process launch --device "$DEVICE_UDID" --terminate-existing "$BUNDLE_ID" >/dev/null 2>&1; then
	ok "Running on $device_name"
else
	# A locked device refuses the launch even though the install worked.
	warn "Could not launch it — the device is probably locked."
	note "Unlock it and tap iTorrent on the home screen."
fi

printf '\n%s✓ Done.%s iTorrent is on %s.\n\n' "$GREEN$BOLD" "$RESET" "$device_name"
printf '  %sA signature from a free Apple ID stops working after seven days;%s\n' "$DIM" "$RESET"
printf '  %srun this script again to renew it. A paid account lasts a year.%s\n\n' "$DIM" "$RESET"
