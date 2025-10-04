#!/usr/bin/env python3
"""
Improved Spotify Recorder with Web API playback control
"""

import subprocess
import time
import signal
import os
from typing import Optional
from pathlib import Path
from playback_monitor import PlaybackMonitor
from utils import DINFO, DERROR, DOK, ERROR


class SpotifyRecorder:
    """Handle recording of Spotify tracks with Web API playback control"""

    def __init__(self, monitor: PlaybackMonitor, sp_client, verbose: bool = False):
        """
        Initialize recorder

        Args:
            monitor: PlaybackMonitor instance for tracking playback
            sp_client: Spotipy Spotify client for API calls
            verbose: Enable verbose logging
        """
        self.monitor = monitor
        self.sp = sp_client
        self.verbose = verbose
        self.recording_process = None
        self.recording_pid = None

    def ensure_spotify_device_active(self, max_wait: int = 15) -> bool:
        """
        Ensure Spotify desktop client is running and active as a device

        Args:
            max_wait: Maximum time to wait for device (seconds)

        Returns:
            True if device found, False otherwise
        """
        import subprocess

        if self.verbose:
            DINFO("Starting Spotify desktop client...")

        # Start Spotify desktop client
        try:
            subprocess.Popen(["spotify"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except:
            try:
                subprocess.Popen(["/snap/bin/spotify"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception as e:
                DERROR(f"Failed to start Spotify: {e}")
                return False

        # Wait for Spotify device to appear
        start_time = time.time()
        while time.time() - start_time < max_wait:
            try:
                devices = self.sp.devices()
                if devices and devices.get('devices'):
                    if self.verbose:
                        device_names = [d['name'] for d in devices['devices']]
                        DOK(f"Found Spotify devices: {device_names}")
                    return True
            except Exception as e:
                if self.verbose:
                    DINFO(f"Waiting for Spotify device... ({int(time.time() - start_time)}s)")

            time.sleep(1)

        DERROR("No Spotify device found after waiting")
        return False

    def start_playback_web_api(self, uri: str, max_retries: int = 3) -> bool:
        """
        Start playback of specific track using Spotify Web API

        Args:
            uri: Spotify track URI
            max_retries: Maximum number of retry attempts

        Returns:
            True if track started playing successfully, False otherwise
        """
        # Ensure Spotify device is active first
        if not self.ensure_spotify_device_active():
            DERROR("Cannot start playback: No active Spotify device")
            return False

        for attempt in range(max_retries):
            try:
                if self.verbose:
                    DINFO(f"Starting playback via Web API (attempt {attempt + 1}/{max_retries}): {uri}")

                # Start playback of specific track from beginning
                self.sp.start_playback(uris=[uri], position_ms=0)

                # Wait for playback to start
                time.sleep(2)

                # Verify correct track is playing
                current = self.sp.current_playback()
                if not current or not current.get('item'):
                    if self.verbose:
                        DERROR("No playback state available")
                    continue

                current_uri = current['item']['uri']
                is_playing = current.get('is_playing', False)
                position_ms = current.get('progress_ms', 0)

                if current_uri == uri and is_playing:
                    if self.verbose:
                        DOK(f"Track verified playing: {uri} at position {position_ms}ms")
                    return True
                else:
                    if self.verbose:
                        DERROR(f"Wrong track playing: expected {uri}, got {current_uri}")

            except Exception as e:
                if self.verbose:
                    DERROR(f"Error starting playback (attempt {attempt + 1}): {e}")

            # Wait before retry
            if attempt < max_retries - 1:
                time.sleep(1)

        DERROR(f"Failed to start playback after {max_retries} attempts")
        return False

    def record_track_simple(
        self,
        uri: str,
        filepath: str,
        expected_duration_s: int,
    ) -> bool:
        """
        Record track using spotdl.sh (D-Bus playback control + recording)

        Args:
            uri: Spotify track URI
            filepath: Output file path
            expected_duration_s: Expected track duration

        Returns:
            True if recording succeeded, False otherwise
        """
        # Run spotdl.sh script (handles D-Bus playback control and recording)
        script_dir = Path(__file__).parent
        spotdl_path = str(script_dir / 'spotdl.sh')
        spotdl_cmd = [spotdl_path, uri, filepath, str(expected_duration_s)]
        if self.verbose:
            spotdl_cmd.append("1")

        try:
            if self.verbose:
                DOK(f"Starting recording for {uri}")

            # Start recording subprocess
            result = subprocess.run(spotdl_cmd, check=True, capture_output=False)

            if result.returncode != 0:
                DERROR(f"Recording process exited with code {result.returncode}")
                return False

            # Verify file was created and has reasonable size
            if not os.path.exists(filepath):
                DERROR(f"Output file not created: {filepath}")
                return False

            file_size = os.path.getsize(filepath)
            # Rough check: 320kbps = 40KB/s, expect at least 20KB/s
            min_expected_size = expected_duration_s * 20 * 1024

            if file_size < min_expected_size:
                DERROR(f"Output file too small: {file_size} bytes (expected > {min_expected_size})")
                return False

            if self.verbose:
                DOK(f"Recording completed successfully: {filepath} ({file_size} bytes)")

            return True

        except subprocess.CalledProcessError as e:
            DERROR(f"Recording failed: {e}")
            return False
        except KeyboardInterrupt:
            DERROR("Recording interrupted by user")
            self._cleanup_recording()
            return False
        except Exception as e:
            DERROR(f"Unexpected error during recording: {e}")
            self._cleanup_recording()
            return False

    def _cleanup_recording(self):
        """Clean up any running recording processes"""
        if self.recording_pid:
            try:
                os.kill(self.recording_pid, signal.SIGTERM)
                time.sleep(0.5)
                os.kill(self.recording_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass  # Process already terminated
            except Exception as e:
                if self.verbose:
                    DERROR(f"Error cleaning up recording process: {e}")

        # Also kill any stray pw-record processes
        try:
            subprocess.run(["pkill", "pw-record"], check=False, capture_output=True)
        except Exception:
            pass
