#!/bin/bash
### SPOTIFY RECORDER

# Detect Spotify installation (flatpak or snap)
if flatpak list 2>/dev/null | grep -q com.spotify.Client; then
    SPOTIFY_CMD="flatpak run --branch=stable --arch=x86_64 --command=spotify com.spotify.Client"
elif command -v spotify >/dev/null 2>&1; then
    SPOTIFY_CMD=$(command -v spotify)
elif command -v /snap/bin/spotify >/dev/null 2>&1; then
    SPOTIFY_CMD="/snap/bin/spotify"
else
    echo >&2 "Spotify was not found. Please install via flatpak or snap."
    exit 1
fi
command -v grep >/dev/null 2>&1 || { echo >&2 "grep was not found"; exit 1; }
command -v tr >/dev/null 2>&1 || { echo >&2 "tr was not found"; exit 1; }
command -v pactl >/dev/null 2>&1 || { echo >&2 "pactl was not found"; exit 1; }
command -v ffmpeg >/dev/null 2>&1 || { echo >&2 "ffmpeg was not found"; exit 1; }
command -v pw-record >/dev/null 2>&1 || { echo >&2 "pw-record was not found (PipeWire required)"; exit 1; }
command -v playerctl >/dev/null 2>&1 || { echo >&2 "playerctl was not found (install: sudo dnf install playerctl)"; exit 1; }

echo "Sound Server : PipeWire"

# Check for multiple Spotify installations (can cause D-Bus conflicts)
snap_installed=$(snap list spotify 2>/dev/null | grep -c spotify)
flatpak_installed=$(flatpak list 2>/dev/null | grep -c spotify)
if [ "$snap_installed" -gt 0 ] && [ "$flatpak_installed" -gt 0 ]; then
    echo "[!] WARNING: Both snap and flatpak versions of Spotify are installed!"
    echo "[!] This can cause D-Bus conflicts. Please remove one:"
    echo "[!]   sudo snap remove spotify"
    echo "[!]   OR"
    echo "[!]   flatpak uninstall com.spotify.Client"
fi

# Get Spotify's pulseaudio sink ID
get_spotify_sink(){
    # spotify_sink=$(LANG=en python3 pactl-json-parser/pactl_parser.py | jq 'to_entries[] | {sink:.key} + {value:.value.Properties["media.name"]} | if (.value | contains("Spotify")) then .sink | tonumber else empty end' | tail -f -n1)
    # spotify_sink=$(pactl list sink-inputs | grep -E "Input #|media.name" | xargs | grep -Eoi "#[0-9]* media.name = Spotify" | grep -oi "[0-9]*") # 8x faster
    spotify_sink=$(LANG=C pactl list sink-inputs | grep -E "Input #|media.name" | tr -d "[:space:]" | tr -d "\"" | grep -Eoi "#[0-9]*media.name=Spotify" | grep -oi "[0-9]*") # 1.3x even faster + remove xargs dependency
}


uri=$1
filepath="$2"
duration="$3"
verbose="$4"

if [ -z "$uri" ] || [ -z "$filepath" ] || [ -z "$duration" ]; then
    echo "Invalid usage, missing uri, filepath or song duration."
    echo "Usage : $0 <URI> <filepath> <song duration> [verbose]"
fi

tmp_folder="songs_build"
mkdir -p $tmp_folder
mkdir -p $(dirname "$filepath")

tmp_filepath="$tmp_folder/${uri/*:/}"

if [ ! -z $verbose ]; then
    echo "* URI          : $uri"
    echo "* filepath     : $filepath"
    echo "* duration     : $duration"
    echo "* Verbose      : $verbose"
    echo "* tmp_filepath : $tmp_filepath"
fi

# Function to check if Spotify is running and responsive
check_spotify_state() {
    # Check if Spotify process is running
    if ! pgrep -f "spotify" > /dev/null; then
        [ -n "$verbose" ] && echo "Spotify process not found"
        return 1
    fi

    # Check if Spotify D-Bus interface is responding
    if ! timeout 2s dbus-send --print-reply --dest=org.mpris.MediaPlayer2.spotify /org/mpris/MediaPlayer2 org.freedesktop.DBus.Properties.Get string:"org.mpris.MediaPlayer2.Player" string:"PlaybackStatus" 2>/dev/null | grep -q "string"; then
        [ -n "$verbose" ] && echo "Spotify D-Bus interface not responding"
        return 1
    fi

    [ -n "$verbose" ] && echo "Spotify is running and responsive"
    return 0
}

# Start Spotify and control playback via D-Bus
if ! check_spotify_state; then
    [ -n "$verbose" ] && echo "Starting fresh Spotify instance..."
    pkill spotify 2>/dev/null || true
    sleep 0.5
    $SPOTIFY_CMD > /dev/null 2>&1 &

    # Wait for Spotify to start
    sleep 3
else
    [ -n "$verbose" ] && echo "Reusing existing Spotify instance"
    # Small delay to ensure Spotify is ready for commands
    sleep 0.5
fi

# Activate device with Play command
[ -n "$verbose" ] && echo "Activating Spotify device..."
dbus-send --print-reply --dest=org.mpris.MediaPlayer2.spotify /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player.Play 2>/dev/null || true
sleep 1

# Load specific track via OpenUri
[ -n "$verbose" ] && echo "Loading track via D-Bus: $uri"
dbus-send --print-reply --dest=org.mpris.MediaPlayer2.spotify /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player.OpenUri string:"$uri" 2>/dev/null || true
sleep 2

# Pause immediately (we'll start playback after recording is ready)
dbus-send --print-reply --dest=org.mpris.MediaPlayer2.spotify /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player.Pause 2>/dev/null || true
sleep 0.5

# Seek to beginning (0:00) while paused
dbus-send --print-reply --dest=org.mpris.MediaPlayer2.spotify /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player.SetPosition objpath:/org/mpris/MediaPlayer2/Track/0 int64:0 2>/dev/null || true
sleep 0.5

# Wait for track to load (verify correct track is loaded via metadata)
[ -n "$verbose" ] && echo "Waiting for track to load..."
track_load_timeout=30
track_load_elapsed=0
track_loaded=false

while [ $track_load_elapsed -lt $track_load_timeout ]; do
    # Get current track URI using playerctl
    # Note: playerctl returns D-Bus object path format: /com/spotify/track/ID
    current_track=$(playerctl -p spotify metadata mpris:trackid 2>/dev/null)
    current_track_id=$(echo "$current_track" | grep -o '[^/]*$')
    expected_track_id=$(echo "$uri" | grep -o '[^:]*$')

    if [ "$current_track_id" = "$expected_track_id" ]; then
        track_loaded=true
        [ -n "$verbose" ] && echo "Track loaded (paused at 0:00): $current_track"
        break
    fi

    if [ -n "$verbose" ] && [ $((track_load_elapsed % 5)) -eq 0 ]; then
        echo "Waiting for track load... ${track_load_elapsed}s (current: ${current_track:-none})"
    fi

    sleep 1
    track_load_elapsed=$((track_load_elapsed + 1))
done

if [ "$track_loaded" != "true" ]; then
    echo "[!] Error: Track did not load after ${track_load_timeout}s"
    echo "[!] Current track: ${current_track:-none}"
    echo "[!] Expected track: $uri"
    exit 1
fi

# Wait until Spotify's sink is spotted (with timeout)
timeout=60
elapsed=0
[ -n "$verbose" ] && echo "Waiting for Spotify audio sink..."
while [ -z "$spotify_sink" ] && [ $elapsed -lt $timeout ];
do
    get_spotify_sink
    if [ -z "$spotify_sink" ]; then
        sleep 0.5
        elapsed=$((elapsed + 1))
        [ -n "$verbose" ] && [ $((elapsed % 4)) -eq 0 ] && echo "Still waiting... ${elapsed}/2 seconds"
    fi
done

if [ -z "$spotify_sink" ]; then
    echo "[!] Error: Could not find Spotify audio sink after $((timeout/2)) seconds"
    echo "[!] Make sure Spotify is installed and can play audio"
    echo "[!] Current sink inputs:"
    pactl list sink-inputs short
    pkill spotify
    exit 1
fi

echo "Found Spotify sink: $spotify_sink"

# Verify the sink still exists
if ! pactl list sink-inputs short | grep -q "^$spotify_sink"; then
    echo "[!] Error: Spotify sink $spotify_sink disappeared"
    pactl list sink-inputs short
    exit 1
fi

[ -n "$verbose" ] && echo "Verified sink $spotify_sink exists"

# Create null sink for silent recording (instead of muting)
[ -n "$verbose" ] && echo "Creating null sink for silent recording..."
null_sink_module=$(pactl load-module module-null-sink sink_name=spotify_recorder_null sink_properties=device.description="Spotify-Recorder-Silent")

if [ -z "$null_sink_module" ]; then
    echo "[!] Error: Failed to create null sink"
    exit 1
fi

[ -n "$verbose" ] && echo "Created null sink module: $null_sink_module"

# Move Spotify to null sink (silent output, but audio still flows)
[ -n "$verbose" ] && echo "Moving Spotify to null sink..."
pactl move-sink-input "$spotify_sink" spotify_recorder_null

# Start high-quality PipeWire recording WHILE PAUSED (track at 0:00)
# Note: Records from sink-input BEFORE it reaches the null sink
[ -n "$verbose" ] && echo "Starting pw-record while track is paused at 0:00..."
pw-record --latency=20ms --volume=1.0 --format=f32 --channel-map stereo --rate 44100 --quality=15 --target="$spotify_sink" "$tmp_filepath.rec" &
record_pid=$!

[ -n "$verbose" ] && echo "Started pw-record with PID $record_pid targeting sink $spotify_sink"

# NOW start playback - recording will capture from exact 0:00
[ -n "$verbose" ] && echo "Starting playback from 0:00..."
dbus-send --print-reply --dest=org.mpris.MediaPlayer2.spotify /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player.Play 2>/dev/null || true
sleep 0.5

printf "==> Recording %s as \"%s\" for %s seconds\r" "$uri" "$filepath" "$duration"

# Wait till the end & stop
sleep "$duration"

# Properly terminate recording process
if [ -n "$record_pid" ]; then
    [ -n "$verbose" ] && echo "Terminating pw-record (PID $record_pid)..."
    kill "$record_pid" 2>/dev/null || true
    wait "$record_pid" 2>/dev/null || true
else
    # Fallback to pkill if PID wasn't captured
    pkill pw-record
fi

# Clean up null sink
if [ -n "$null_sink_module" ]; then
    [ -n "$verbose" ] && echo "Unloading null sink module $null_sink_module..."
    pactl unload-module "$null_sink_module" 2>/dev/null || true
fi

# Convert file to MP3
verbose_flags="-hide_banner -loglevel error"
[ -n "$verbose" ] && verbose_flags=""
ffmpeg $verbose_flags -y -i "$tmp_filepath.rec" -acodec mp3 -b:a 320k "$filepath"
[ -n "$verbose" ] && echo "Converted to MP3: $filepath"
printf "\033[K[+] File saved at %s\n" "$filepath"

# Clean up temporary .rec file
rm "$tmp_filepath.rec"
[ -n "$verbose" ] && echo "Cleaned up temporary file: $tmp_filepath.rec"

# Note: Spotify is NOT killed here to support multi-track albums/playlists

exit 0
