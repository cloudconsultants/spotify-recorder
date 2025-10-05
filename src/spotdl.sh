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

# Start pre-roll recording buffer (2 seconds before playback)
# This captures the beginning and prevents start cutoff
[ -n "$verbose" ] && echo "Starting pre-roll recording buffer (2 seconds)..."
pw-record --latency=20ms --volume=1.0 --format=f32 --channel-map stereo --rate 44100 --quality=15 --target="$spotify_sink" "$tmp_filepath.rec" &
record_pid=$!

[ -n "$verbose" ] && echo "Started pw-record with PID $record_pid targeting sink $spotify_sink"

# Wait a moment for recording to stabilize
sleep 0.5

# NOW start playback - recording has 2 second head start
[ -n "$verbose" ] && echo "Starting playback from 0:00..."
dbus-send --print-reply --dest=org.mpris.MediaPlayer2.spotify /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player.Play 2>/dev/null || true

printf "==> Recording %s as \"%s\" (monitoring playback)\r" "$uri" "$filepath"

# Monitor playback in real-time instead of fixed duration
elapsed_time=0
max_duration=$((duration + 5)) # Add 5 second safety buffer
still_playing=true

while [ $elapsed_time -lt $max_duration ] && [ "$still_playing" = "true" ]; do
    sleep 1
    elapsed_time=$((elapsed_time + 1))

    # Check if track is still playing via D-Bus
    current_position=$(dbus-send --print-reply --dest=org.mpris.MediaPlayer2.spotify /org/mpris/MediaPlayer2 org.freedesktop.DBus.Properties.Get string:"org.mpris.MediaPlayer2.Player" string:"Position" 2>/dev/null | grep -o '[0-9]*' | head -1)
    current_status=$(dbus-send --print-reply --dest=org.mpris.MediaPlayer2.spotify /org/mpris/MediaPlayer2 org.freedesktop.DBus.Properties.Get string:"org.mpris.MediaPlayer2.Player" string:"PlaybackStatus" 2>/dev/null | grep -o '"[^"]*"' | grep -o '[^"]*')

    # Convert position from microseconds to seconds
    if [ -n "$current_position" ] && [ "$current_position" -gt 0 ]; then
        position_seconds=$((current_position / 1000000))

        # Check if we're near the end (within 2 seconds) or track has stopped
        if [ "$current_status" != "Playing" ] || [ $position_seconds -ge $((duration - 2)) ]; then
            [ -n "$verbose" ] && echo "Track ending detected at ${position_seconds}s, stopping recording..."
            still_playing=false
            # Add a small buffer to capture the very end
            sleep 2
        fi
    fi

    # Verbose progress updates
    if [ -n "$verbose" ] && [ $((elapsed_time % 10)) -eq 0 ]; then
        echo "Recording progress: ${elapsed_time}s / ${duration}s"
    fi
done

# Properly terminate recording process
if [ -n "$record_pid" ]; then
    [ -n "$verbose" ] && echo "Terminating pw-record (PID $record_pid) after ${elapsed_time}s..."
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

# Convert file to MP3 with silence detection and trimming
verbose_flags="-hide_banner -loglevel error"
[ -n "$verbose" ] && verbose_flags=""

[ -n "$verbose" ] && echo "Converting to MP3 with silence detection..."

# First pass: detect silence at beginning and end
if [ -n "$verbose" ]; then
    echo "Analyzing silence levels..."
    ffmpeg $verbose_flags -i "$tmp_filepath.rec" -af "silencedetect=noise=-30dB:duration=0.5" -f null - 2>"$tmp_filepath.silence.txt"

    # Extract silence information
    start_silence=$(grep "silence_start" "$tmp_filepath.silence.txt" | head -1 | grep -o '[0-9]*\.[0-9]*' | head -1)
    end_silence=$(grep "silence_end" "$tmp_filepath.silence.txt" | tail -1 | grep -o '[0-9]*\.[0-9]*' | tail -1)

    echo "Silence analysis: start=${start_silence:-0}s, end=${end_silence:-0}s"
fi

# Convert with smart trimming
if [ -n "$start_silence" ] && [ -n "$end_silence" ] && [ "$start_silence" != "0" ] && [ "$end_silence" != "0" ]; then
    # Both start and end silence detected - trim both
    trim_start=$(echo "$start_silence + 0.1" | bc -l 2>/dev/null || echo "0.1")  # Small offset to ensure we get the music
    duration_trim=$(echo "$end_silence - $trim_start" | bc -l 2>/dev/null || echo "$duration")

    [ -n "$verbose" ] && echo "Trimming: start=${trim_start}s, duration=${duration_trim}s"
    ffmpeg $verbose_flags -y -i "$tmp_filepath.rec" -ss "$trim_start" -t "$duration_trim" -acodec mp3 -b:a 320k "$filepath"
elif [ -n "$start_silence" ] && [ "$start_silence" != "0" ]; then
    # Only start silence detected - trim beginning
    trim_start=$(echo "$start_silence + 0.1" | bc -l 2>/dev/null || echo "0.1")

    [ -n "$verbose" ] && echo "Trimming start: ${trim_start}s"
    ffmpeg $verbose_flags -y -i "$tmp_filepath.rec" -ss "$trim_start" -acodec mp3 -b:a 320k "$filepath"
else
    # No significant silence detected or analysis failed - convert normally
    [ -n "$verbose" ] && echo "No trimming needed, converting normally"
    ffmpeg $verbose_flags -y -i "$tmp_filepath.rec" -acodec mp3 -b:a 320k "$filepath"
fi

[ -n "$verbose" ] && echo "Converted to MP3: $filepath"
printf "\033[K[+] File saved at %s\n" "$filepath"

# Clean up silence analysis file
[ -f "$tmp_filepath.silence.txt" ] && rm "$tmp_filepath.silence.txt"

# Clean up temporary .rec file
rm "$tmp_filepath.rec"
[ -n "$verbose" ] && echo "Cleaned up temporary file: $tmp_filepath.rec"

# Note: Spotify is NOT killed here to support multi-track albums/playlists

exit 0
