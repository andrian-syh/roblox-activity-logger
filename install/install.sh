#!/usr/bin/env bash
#
# Installs the Studio Activity Logger on a macOS machine.
#
# Asks for the collector address, proves it works before touching anything on
# disk, then writes the plugin where Studio loads it from. Run it again at any
# time to update. The address is always typed in full: a wrong one carried over
# from a previous install is the hardest kind of fault to notice.
#
# Run it with the command substitution form, never by piping into bash. Piping
# leaves stdin attached to the pipe, and the prompts below cannot be answered:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/andrian-syh/roblox-activity-logger/main/install/install.sh)"

set -euo pipefail

REPOSITORY='andrian-syh/roblox-activity-logger'
PLUGIN_FILE='StudioActivityLogger.rbxmx'
LEGACY_FILES=('StudioActivityLogger.rbxm' 'ActivityLogger.rbxmx')
URL_PLACEHOLDER='PASTE_COLLECTOR_URL_HERE'
TOKEN_PLACEHOLDER='PASTE_SHARED_TOKEN_HERE'
PLUGINS_DIR="$HOME/Documents/Roblox/Plugins"

fail() {
	printf '\nFAILED: %s\n' "$1" >&2
	exit 1
}

step() {
	printf '  %s\n' "$1"
}

# A quote or a backslash would end or escape the Luau string the value is
# written into, whatever the XML around it says.
reject_unsafe() {
	case "$1" in
		*'"'*|*'\'*) fail "$2 must not contain quotes or backslashes." ;;
	esac
}

printf '\nStudio Activity Logger\n\n'

if [ ! -t 0 ]; then
	fail 'This script needs your input. Run it with: bash -c "$(curl -fsSL <url>)"'
fi

# A plugin file replaced underneath a running Studio is simply ignored until the
# next start, which looks exactly like a successful install.
if pgrep -x 'RobloxStudio' >/dev/null 2>&1 || pgrep -x 'RobloxStudioBeta' >/dev/null 2>&1; then
	fail 'Roblox Studio is running. Close Studio completely, then run this command again.'
fi

if [ ! -d "$PLUGINS_DIR" ]; then
	mkdir -p "$PLUGINS_DIR"
	step "Created plugins folder: $PLUGINS_DIR"
fi

TARGET="$PLUGINS_DIR/$PLUGIN_FILE"

printf 'Collector URL (ends in /exec): '
read -r COLLECTOR_URL
[ -n "$COLLECTOR_URL" ] || fail 'Collector URL is required.'
if ! printf '%s' "$COLLECTOR_URL" | grep -Eq '^https://[^[:space:]/]+\.[^[:space:]/]+/.+'; then
	fail 'Collector URL is not a complete https address. Copy it exactly as your supervisor sent it.'
fi
reject_unsafe "$COLLECTOR_URL" 'Collector URL'

printf 'Shared token: '
read -rs SHARED_TOKEN
printf '\n'
[ -n "$SHARED_TOKEN" ] || fail 'Shared token is required.'
[ "${#SHARED_TOKEN}" -ge 8 ] || fail 'Shared token is too short to be right. Copy it exactly as your supervisor sent it.'
reject_unsafe "$SHARED_TOKEN" 'Shared token'

ENCODED_TOKEN="$(printf '%s' "$SHARED_TOKEN" | perl -MURI::Escape -ne 'print uri_escape($_)' 2>/dev/null || printf '%s' "$SHARED_TOKEN")"

# A spreadsheet collector answers over a redirect that carries a cookie, and
# the answer is refused to anyone who drops it on the way.
COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT
COLLECTOR_CURL=(curl -fsSL -c "$COOKIE_JAR" -b "$COOKIE_JAR")

# Proving the address before writing anything turns a typo into a message here
# rather than a machine that silently never reports.
printf '\n'
step 'Checking the collector...'
# Apps Script turns away good requests for minutes at a time, so a failed
# check is tried again before it is believed.
for ATTEMPT in 1 2 3; do
	CHECK="$("${COLLECTOR_CURL[@]}" --max-time 30 "$COLLECTOR_URL?token=$ENCODED_TOKEN" || true)"
	case "$CHECK" in
		*'"ok":'*) break ;;
	esac
	if [ "$ATTEMPT" -lt 3 ]; then
		step 'No answer from the collector. Retrying in 10 seconds...'
		sleep 10
	fi
done
case "$CHECK" in
	*'"ok":true'*) step 'Collector reached, token accepted.' ;;
	*'bad token'*) fail 'The collector refused the token. Check it, or ask your supervisor for the latest one.' ;;
	*) fail 'Could not reach the collector, or its answer was not recognised.' ;;
esac

step 'Downloading the plugin...'
DOWNLOAD_BASE="https://github.com/$REPOSITORY/releases/latest/download"
TEMP="$(mktemp -t StudioActivityLogger)"
trap 'rm -f "$TEMP" "$COOKIE_JAR"' EXIT

curl -fsSL --max-time 120 -o "$TEMP" "$DOWNLOAD_BASE/$PLUGIN_FILE" || fail 'Plugin download failed.'
EXPECTED="$(curl -fsSL --max-time 60 "$DOWNLOAD_BASE/$PLUGIN_FILE.sha256" | awk '{print tolower($1)}')" \
	|| fail 'Checksum download failed.'
ACTUAL="$(shasum -a 256 "$TEMP" | awk '{print tolower($1)}')"

if [ "$ACTUAL" != "$EXPECTED" ]; then
	fail 'Checksum mismatch. The download is damaged or the release files were replaced. Try again, and tell your supervisor if it keeps failing.'
fi
step 'Checksum verified.'

VERSION="$(perl -0777 -ne 'print $1 if /Config\.VERSION = "([^"]*)"/' "$TEMP")"
VERSION="${VERSION:-unknown}"

PLUGIN_URL="$COLLECTOR_URL" PLUGIN_TOKEN="$SHARED_TOKEN" perl -pi -e '
	BEGIN {
		for my $key (qw(PLUGIN_URL PLUGIN_TOKEN)) {
			$ENV{$key} =~ s/&/&amp;/g;
			$ENV{$key} =~ s/</&lt;/g;
			$ENV{$key} =~ s/>/&gt;/g;
		}
	}
	s/\QPASTE_COLLECTOR_URL_HERE\E/$ENV{PLUGIN_URL}/g;
	s/\QPASTE_SHARED_TOKEN_HERE\E/$ENV{PLUGIN_TOKEN}/g;
' "$TEMP"

cp "$TEMP" "$TARGET"

# Two copies under different names both load, and every event is then reported
# twice.
for legacy in "${LEGACY_FILES[@]}"; do
	if [ -f "$PLUGINS_DIR/$legacy" ]; then
		rm -f "$PLUGINS_DIR/$legacy"
		step "Removed old copy: $legacy"
	fi
done

step "Plugin $VERSION installed."

# Registering here means the supervisor sees the machine straight away, instead
# of waiting for whenever Studio is next opened.
BATCH_ID="$(uuidgen)"
SESSION_ID="$(uuidgen)"
EPOCH="$(date +%s)"
MACHINE="install:$(scutil --get ComputerName 2>/dev/null || hostname)"

PAYLOAD="$(BATCH_ID="$BATCH_ID" SESSION_ID="$SESSION_ID" EPOCH="$EPOCH" MACHINE="$MACHINE" \
	VERSION="$VERSION" TOKEN="$SHARED_TOKEN" perl -e '
	my %e = map { $_ => $ENV{$_} } qw(BATCH_ID SESSION_ID EPOCH MACHINE VERSION TOKEN);
	for my $key (keys %e) { $e{$key} =~ s/(["\\])/\\$1/g; }
	print qq({"token":"$e{TOKEN}","version":"$e{VERSION}","batchId":"$e{BATCH_ID}",);
	print qq("sessionId":"$e{SESSION_ID}","userId":"$e{MACHINE}","placeId":0,);
	print qq("placeName":"installer","sentAtEpoch":$e{EPOCH},"events":[);
	print qq({"epoch":$e{EPOCH},"kind":"installed","target":"$e{VERSION}",);
	print qq("mode":"edit","confidence":"","origin":"","via":""}]});
')"

"${COLLECTOR_CURL[@]}" --max-time 60 -X POST -H 'Content-Type: application/json' \
	-d "$PAYLOAD" "$COLLECTOR_URL" >/dev/null 2>&1 || true

STORED="$("${COLLECTOR_CURL[@]}" --max-time 30 "$COLLECTOR_URL?token=$ENCODED_TOKEN&batchId=$BATCH_ID" 2>/dev/null || true)"
case "$STORED" in
	*'"stored":true'*) step 'This machine is registered in the sheet.' ;;
	*) step 'Installed. Registration will follow when Studio opens.' ;;
esac

printf '\nDONE.\n'
printf '  1. Open Roblox Studio and find the Studio Activity Logger panel.\n'
printf '  2. The Status tile should read Recording, in green.\n'
printf '  3. If a Problem card appears, follow what it says. Ask your supervisor if it is unclear.\n\n'
