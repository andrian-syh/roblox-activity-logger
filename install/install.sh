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
	printf '\nGAGAL: %s\n' "$1" >&2
	exit 1
}

step() {
	printf '  %s\n' "$1"
}

# A quote or a backslash would end or escape the Luau string the value is
# written into, whatever the XML around it says.
reject_unsafe() {
	case "$1" in
		*'"'*|*'\'*) fail "$2 tidak boleh memuat tanda kutip atau garis miring terbalik." ;;
	esac
}

printf '\nStudio Activity Logger\n\n'

if [ ! -t 0 ]; then
	fail 'Skrip ini butuh input. Jalankan dengan: bash -c "$(curl -fsSL <url>)"'
fi

# A plugin file replaced underneath a running Studio is simply ignored until the
# next start, which looks exactly like a successful install.
if pgrep -x 'RobloxStudio' >/dev/null 2>&1 || pgrep -x 'RobloxStudioBeta' >/dev/null 2>&1; then
	fail 'Roblox Studio sedang berjalan. Tutup Studio sepenuhnya, lalu jalankan lagi perintah ini.'
fi

if [ ! -d "$PLUGINS_DIR" ]; then
	mkdir -p "$PLUGINS_DIR"
	step "Folder plugin dibuat: $PLUGINS_DIR"
fi

TARGET="$PLUGINS_DIR/$PLUGIN_FILE"

printf 'URL collector (diakhiri /exec): '
read -r COLLECTOR_URL
[ -n "$COLLECTOR_URL" ] || fail 'URL collector wajib diisi.'
if ! printf '%s' "$COLLECTOR_URL" | grep -Eq '^https://[^[:space:]/]+\.[^[:space:]/]+/.+'; then
	fail 'URL collector tidak berbentuk alamat https yang utuh. Salin apa adanya dari PM.'
fi
reject_unsafe "$COLLECTOR_URL" 'URL collector'

printf 'Shared token: '
read -rs SHARED_TOKEN
printf '\n'
[ -n "$SHARED_TOKEN" ] || fail 'Shared token wajib diisi.'
[ "${#SHARED_TOKEN}" -ge 8 ] || fail 'Shared token terlalu pendek untuk benar. Salin apa adanya dari PM.'
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
step 'Memeriksa collector...'
# Apps Script turns away good requests for minutes at a time, so a failed
# check is tried again before it is believed.
for ATTEMPT in 1 2 3; do
	CHECK="$("${COLLECTOR_CURL[@]}" --max-time 30 "$COLLECTOR_URL?token=$ENCODED_TOKEN" || true)"
	case "$CHECK" in
		*'"ok":'*) break ;;
	esac
	if [ "$ATTEMPT" -lt 3 ]; then
		step 'Collector belum menjawab. Mencoba lagi dalam 10 detik...'
		sleep 10
	fi
done
case "$CHECK" in
	*'"ok":true'*) step 'Collector menjawab, token diterima.' ;;
	*'bad token'*) fail 'Collector menolak token. Periksa token, atau minta yang terbaru ke PM.' ;;
	*) fail 'Collector tidak bisa dihubungi atau jawabannya tidak dikenali.' ;;
esac

step 'Mengunduh plugin...'
DOWNLOAD_BASE="https://github.com/$REPOSITORY/releases/latest/download"
TEMP="$(mktemp -t StudioActivityLogger)"
trap 'rm -f "$TEMP" "$COOKIE_JAR"' EXIT

curl -fsSL --max-time 120 -o "$TEMP" "$DOWNLOAD_BASE/$PLUGIN_FILE" || fail 'Unduhan plugin gagal.'
EXPECTED="$(curl -fsSL --max-time 60 "$DOWNLOAD_BASE/$PLUGIN_FILE.sha256" | awk '{print tolower($1)}')" \
	|| fail 'Unduhan checksum gagal.'
ACTUAL="$(shasum -a 256 "$TEMP" | awk '{print tolower($1)}')"

if [ "$ACTUAL" != "$EXPECTED" ]; then
	fail 'Checksum tidak cocok. Unduhan rusak atau berkas rilis diganti. Ulangi, lapor ke PM jika tetap gagal.'
fi
step 'Checksum cocok.'

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
		step "Versi lama dihapus: $legacy"
	fi
done

step "Plugin $VERSION dipasang."

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
	*'"stored":true'*) step 'Mesin ini terdaftar di sheet.' ;;
	*) step 'Terpasang. Pendaftaran akan menyusul saat Studio dibuka.' ;;
esac

printf '\nSELESAI.\n'
printf '  1. Buka Roblox Studio.\n'
printf '  2. Panel di bawah harus hijau.\n'
printf '  3. Panel merah, baca pesannya dan hubungi PM jika tidak jelas.\n\n'
