#!/usr/bin/env python3
"""
Playback Monitor for Spotify - monitors playback state and track changes using Spotify Web API
"""

import time
from typing import Optional, Dict, Callable
from spotipy import Spotify
from utils import DINFO, DERROR, DOK


class PlaybackMonitor:
    """Monitor Spotify playback state and detect track changes using Web API"""

    def __init__(self, sp: Spotify, poll_interval: float = 0.5, verbose: bool = False):
        """
        Initialize playback monitor

        Args:
            sp: Authenticated Spotify client with user-read-playback-state scope
            poll_interval: How often to poll playback state (seconds)
            verbose: Enable verbose logging
        """
        self.sp = sp
        self.poll_interval = poll_interval
        self.verbose = verbose
        self.current_track_id = None
        self.current_track_uri = None

    def get_playback_state(self) -> Optional[Dict]:
        """Get current playback state from Spotify API"""
        try:
            playback = self.sp.current_playback()
            return playback
        except Exception as e:
            if self.verbose:
                DERROR(f"Failed to get playback state: {e}")
            return None

    def wait_for_track_start(self, expected_uri: str, timeout: int = 30) -> bool:
        """
        Wait for a specific track to start playing from position 0

        Args:
            expected_uri: The Spotify URI we expect to be playing
            timeout: Maximum time to wait (seconds)

        Returns:
            True if track started successfully, False otherwise
        """
        start_time = time.time()

        while time.time() - start_time < timeout:
            playback = self.get_playback_state()

            if not playback or not playback.get('item'):
                if self.verbose:
                    DINFO("Waiting for playback to start...")
                time.sleep(self.poll_interval)
                continue

            current_uri = playback['item']['uri']
            is_playing = playback.get('is_playing', False)
            progress_ms = playback.get('progress_ms', 0)

            if current_uri == expected_uri and is_playing:
                # Track is playing, check if we're near the beginning
                if progress_ms < 2000:  # Within first 2 seconds
                    if self.verbose:
                        DOK(f"Track started at position {progress_ms}ms")
                    self.current_track_id = playback['item']['id']
                    self.current_track_uri = current_uri
                    return True
                elif self.verbose:
                    DINFO(f"Track playing but at {progress_ms}ms, waiting for position reset...")

            time.sleep(self.poll_interval)

        DERROR(f"Timeout waiting for track {expected_uri} to start")
        return False

    def monitor_until_track_change(self, on_change: Optional[Callable] = None) -> Optional[str]:
        """
        Monitor playback until track changes

        Args:
            on_change: Optional callback when track changes

        Returns:
            New track URI if changed, None if playback stopped
        """
        while True:
            playback = self.get_playback_state()

            if not playback or not playback.get('item'):
                if self.verbose:
                    DINFO("Playback stopped")
                return None

            current_uri = playback['item']['uri']

            # Check if track changed
            if current_uri != self.current_track_uri:
                if self.verbose:
                    DINFO(f"Track changed: {self.current_track_uri} -> {current_uri}")

                if on_change:
                    on_change(current_uri, playback)

                return current_uri

            time.sleep(self.poll_interval)

    def get_remaining_time(self) -> Optional[int]:
        """
        Get remaining time in current track (milliseconds)

        Returns:
            Remaining time in ms, or None if not available
        """
        playback = self.get_playback_state()

        if not playback or not playback.get('item'):
            return None

        duration_ms = playback['item']['duration_ms']
        progress_ms = playback.get('progress_ms', 0)

        return duration_ms - progress_ms

    def wait_for_position_reset(self, expected_uri: str, max_wait: int = 5) -> bool:
        """
        Wait for track position to be reset to beginning

        Args:
            expected_uri: URI of track to check
            max_wait: Maximum time to wait (seconds)

        Returns:
            True if position is at beginning, False otherwise
        """
        start_time = time.time()

        while time.time() - start_time < max_wait:
            playback = self.get_playback_state()

            if not playback or not playback.get('item'):
                time.sleep(self.poll_interval)
                continue

            if playback['item']['uri'] == expected_uri:
                progress_ms = playback.get('progress_ms', 0)

                if progress_ms < 1000:  # Less than 1 second
                    if self.verbose:
                        DOK(f"Track position verified: {progress_ms}ms")
                    return True
                elif self.verbose:
                    DINFO(f"Waiting for position reset (currently at {progress_ms}ms)...")

            time.sleep(self.poll_interval)

        DERROR(f"Track did not reset to beginning within {max_wait}s")
        return False
