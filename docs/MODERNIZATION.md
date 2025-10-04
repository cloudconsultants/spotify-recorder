# Spotify Recorder Modernization Summary

## Changes Made (October 2025)

### 1. Fixed Critical Recording Bug ✅
**Issue**: `pw-record` process continued running after script exit, creating ever-growing `.rec` files
**Solution**:
- Captured process PID when starting `pw-record`
- Properly terminate using `kill $record_pid` and `wait` for graceful shutdown
- Added fallback to `pkill` if PID wasn't captured

**Files Modified**: `spotdl.sh` (lines 100, 133, 148-154)

---

### 2. Implemented Spotify Web API Playback Monitoring ✅
**Issue**:
- Songs started from middle position
- Track changes during recording not detected
- Fixed duration recording instead of monitoring actual playback

**Solution**: Created new monitoring architecture
- **`playback_monitor.py`**: Monitors playback state via Spotify Web API
  - `wait_for_track_start()`: Ensures track is playing from position 0
  - `wait_for_position_reset()`: Verifies position < 1 second before recording
  - `monitor_until_track_change()`: Detects when track changes
  - `get_remaining_time()`: Calculates time left in track

- **`recorder.py`**: Improved recording with monitoring integration
  - `record_track_monitored()`: Verifies playback before recording
  - Validates output file size after recording
  - Proper cleanup on errors or interruption

**Files Created**: `playback_monitor.py`, `recorder.py`
**Files Modified**: `api.py` (integrated new recorder, added required scopes)

---

### 3. PipeWire Quality Improvements ✅
**Changes**:
- Added `--quality=15` for maximum resampler quality
- Using `--format=f32` (32-bit float) for best quality
- Locked rate at 44100 Hz (Spotify's native rate)
- Removed all legacy PulseAudio code

**Files Modified**: `spotdl.sh` (line 89)

---

### 4. Removed PulseAudio Legacy Code ✅
**Rationale**: Fedora 42 is PipeWire-native, no need for dual support

**Removed**:
- PulseAudio detection logic
- `module-combine-sink` loading/unloading
- `parecord` fallback code
- Conditional branching for different sound servers

**Files Modified**: `spotdl.sh` (simplified from 157 to 114 lines)

---

### 5. Modern Dependency Management ✅
**Migration**: `requirements.txt` → `pyproject.toml` with `uv`

**Benefits**:
- Faster dependency resolution (Rust-based)
- Lock file support for reproducibility
- Modern Python packaging standards
- Better compatibility with Fedora 42

**Files Created**: `pyproject.toml`

---

## Installation Instructions

### Install System Dependencies
```bash
# Fedora 42
sudo dnf install spotify pipewire-utils ffmpeg python3-pip

# Install uv (modern Python package manager)
curl -LsSf https://astral.sh/uv/install.sh | sh
```

### Install Python Dependencies
```bash
# Using uv (recommended)
uv sync

# OR using pip
pip install -r requirements.txt
```

### Setup Spotify API Credentials
1. Visit [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)
2. Create new application
3. Set Redirect URI: `http://127.0.0.1:8000/callback`
4. Update `.env` file with your Client ID and Secret

**Important**: First run will require OAuth authorization since we added new scopes:
- `user-read-playback-state`
- `user-read-currently-playing`

---

## Usage

### Single Track
```bash
python3 api.py https://open.spotify.com/track/TRACK_ID
```

### Playlist
```bash
python3 api.py https://open.spotify.com/playlist/PLAYLIST_ID
```

### With Verbose Logging
```bash
python3 api.py https://open.spotify.com/track/TRACK_ID --verbose
```

---

## Architecture Overview

```
api.py (main entry point)
  ├── sp_instance: Spotify API wrapper
  │   ├── monitor: PlaybackMonitor (tracks playback state)
  │   └── recorder: SpotifyRecorder (handles recording)
  │
  └─> spotdl.sh: Bash script for actual recording
        └─> pw-record: PipeWire recording tool
```

**Recording Flow**:
1. API gets track metadata from Spotify
2. `spotdl.sh` starts Spotify and seeks to position 0
3. `PlaybackMonitor` verifies track is at beginning (<1s)
4. `SpotifyRecorder` starts `spotdl.sh` recording process
5. Monitors playback state during recording
6. Properly terminates `pw-record` process
7. Validates output file size
8. Adds metadata and lyrics

---

## Technical Details

### PipeWire Recording Settings
```bash
pw-record \
  --latency=20ms \
  --volume=1.0 \
  --format=f32 \          # 32-bit float
  --channel-map stereo \
  --rate 44100 \          # Spotify native rate
  --quality=15 \          # Maximum resampler quality
  --target=$SINK \
  output.rec
```

### Playback Monitoring
- **Poll interval**: 500ms (configurable)
- **Position tolerance**: <2000ms for track start verification
- **Reset verification**: <1000ms for position reset check
- **Timeout**: 30s for track start, 5s for position reset

### File Validation
- Minimum expected size: `duration_seconds * 20KB/s`
- Based on 320kbps MP3 ≈ 40KB/s, using 50% safety margin

---

## Known Limitations

1. **Spotify Premium Required**: Recording requires Spotify desktop client
2. **Internet Connection**: Spotify Web API requires network access
3. **OAuth Flow**: First run requires browser authentication
4. **Track Availability**: Some tracks may not be available in your region

---

## Troubleshooting

### "pw-record was not found"
```bash
sudo dnf install pipewire-utils
```

### "Failed to get playback state"
Check that you authorized the new scopes. Delete `.cache` and re-run:
```bash
rm .cache
python3 api.py <spotify-link>
```

### Wrong track playing or recording microphone
**Fixed in latest version!** See `FIXES.md` for details.
- Now uses D-Bus OpenUri for reliable track loading
- Added sink validation to ensure correct audio source

### "Could not find Spotify audio sink"
```bash
# Check if Spotify can play audio normally
spotify
# While playing, check: pactl list sink-inputs
```

### Recording process keeps running
This should be fixed, but if it happens:
```bash
pkill pw-record
pkill spotify
```

### Track starts from middle
**Fixed!** Now uses D-Bus OpenUri + SetPosition for guaranteed position 0 start.

---

## Future Improvements

- [ ] Support for continuous recording (auto-detect playlist changes)
- [ ] Parallel recording of multiple tracks
- [ ] Web interface for easier management
- [ ] Docker containerization
- [ ] Support for other streaming services (Tidal, Apple Music)
- [ ] Automatic silence detection and trimming
