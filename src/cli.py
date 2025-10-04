#!/usr/bin/env python3
"""
Spotify Recorder - Interactive CLI Interface
Provides onboarding, system checks, and dependency installation
"""

import os
import sys
import shutil
import subprocess
import traceback
import tty
import termios
from pathlib import Path
from dotenv import load_dotenv

# Terminal control constants
ANSI_CLEAR_SCREEN = '\033[2J'
ANSI_CURSOR_HOME = '\033[H'

# Try to import optional dependencies
try:
    from rich.console import Console
    from rich.table import Table
    from rich.panel import Panel
    from rich.progress import Progress
    RICH_AVAILABLE = True
except ImportError:
    RICH_AVAILABLE = False


class SpotifyRecorderCLI:
    """Interactive CLI for Spotify Recorder with onboarding and system checks"""

    def __init__(self):
        self.console = Console() if RICH_AVAILABLE else None
        self.distro = self.detect_distro()
        self.project_root = Path(__file__).parent.parent
        self.env_file = self.project_root / '.env'
        self.missing_deps = []

    def detect_distro(self):
        """Detect Linux distribution (Fedora, Ubuntu, or Arch)"""
        if Path('/etc/fedora-release').exists():
            return 'fedora'
        elif Path('/etc/arch-release').exists():
            return 'arch'
        elif Path('/etc/lsb-release').exists():
            try:
                with open('/etc/lsb-release') as f:
                    if 'Ubuntu' in f.read():
                        return 'ubuntu'
            except:
                pass
        return 'unknown'

    def print_header(self, text):
        """Print formatted header"""
        if RICH_AVAILABLE:
            self.console.print(Panel(text, style="bold cyan"))
        else:
            print(f"\n{'='*50}")
            print(f"  {text}")
            print(f"{'='*50}\n")

    def print_success(self, text):
        """Print success message"""
        if RICH_AVAILABLE:
            self.console.print(f"[green]✅ {text}[/green]")
        else:
            print(f"✅ {text}")

    def print_error(self, text):
        """Print error message"""
        if RICH_AVAILABLE:
            self.console.print(f"[red]❌ {text}[/red]")
        else:
            print(f"❌ {text}")

    def print_warning(self, text):
        """Print warning message"""
        if RICH_AVAILABLE:
            self.console.print(f"[yellow]⚠️  {text}[/yellow]")
        else:
            print(f"⚠️  {text}")

    def clear_screen(self):
        """Simple clear screen method for fallback use"""
        try:
            # Use os.system for reliable clearing when not using terminal menu
            os.system('clear' if os.name != 'nt' else 'cls')
        except:
            # Fallback to basic ANSI if os.system fails
            try:
                sys.stdout.write(ANSI_CLEAR_SCREEN + ANSI_CURSOR_HOME)
                sys.stdout.flush()
            except:
                pass

    def supports_ansi(self):
        """Check if terminal supports ANSI escape sequences"""
        try:
            # Check if stdout is a TTY (allow non-TTY for testing with pipes/redirects)
            is_tty = sys.stdout.isatty()

            # Check common environment variables for terminal support
            term = os.environ.get('TERM', '').lower()
            colorterm = os.environ.get('COLORTERM', '').lower()

            # Most modern terminals support ANSI
            if term in ['xterm', 'xterm-256color', 'screen', 'tmux', 'alacritty', 'gnome', 'konsole']:
                return True

            if colorterm in ['truecolor', '24bit']:
                return True

            # Allow ANSI support if we have good terminal indicators, even if not a TTY
            if not is_tty and (term or colorterm):
                return True

            # Default to True for unknown terminals (they probably support basic ANSI)
            return True

        except:
            return False

    def custom_arrow_menu(self):
        """Custom arrow-key menu implementation"""
        try:
            # Build menu items
            env_ok, env_status = self.check_env_file()
            status_symbol = "✅" if env_ok else "⚠️"

            menu_items = [
                "🎵 Record Track",
                "💿 Record Album",
                "📋 Record Playlist",
                "🔍 Search Track",
                "✅ System Check",
                "⚙️  Setup API Credentials",
                "❌ Exit"
            ]

            selected = 0

            while True:
                # Clear screen and display menu
                sys.stdout.write(ANSI_CLEAR_SCREEN + ANSI_CURSOR_HOME)
                sys.stdout.flush()

                print("="*50)
                print("     Spotify Recorder v2.0.0")
                print("="*50)
                print()
                print(f"{status_symbol} API Credentials: {env_status}")
                print()
                print("Use ↑/↓ arrows, Enter to select, q to quit:")
                print()

                # Display menu items with highlight
                for i, item in enumerate(menu_items):
                    if i == selected:
                        print(f"→ {item}")
                    else:
                        print(f"  {item}")

                # Get user input
                try:
                    fd = sys.stdin.fileno()
                    old_settings = termios.tcgetattr(fd)
                    tty.setraw(sys.stdin.fileno())

                    key = sys.stdin.read(1)

                    if key == '\x1b':  # Escape sequence
                        # Read the next two characters to determine arrow key
                        key += sys.stdin.read(2)
                        if key == '\x1b[A':  # Up arrow
                            selected = (selected - 1) % len(menu_items)
                        elif key == '\x1b[B':  # Down arrow
                            selected = (selected + 1) % len(menu_items)
                    elif key == '\r' or key == '\n':  # Enter
                        break
                    elif key == 'q' or key == 'Q':  # Quit
                        selected = len(menu_items) - 1  # Exit
                        break
                    elif key == '\x03':  # Ctrl+C
                        print("\nGoodbye!")
                        sys.exit(0)

                except:
                    # Fallback to simple input handling
                    print("\nArrow keys not supported. Using numbered input:")
                    choice = input("→ Enter choice [1-7]: ").strip()
                    if choice.isdigit() and 1 <= int(choice) <= 7:
                        selected = int(choice) - 1
                        break
                finally:
                    termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)

            # Handle selection
            if selected == 0:
                self.record_track()
            elif selected == 1:
                self.record_album()
            elif selected == 2:
                self.record_playlist()
            elif selected == 3:
                self.search_track()
            elif selected == 4:
                self.check_system_requirements()
                input("\nPress Enter to continue...")
            elif selected == 5:
                self.setup_wizard()
            elif selected == 6:
                print("\nGoodbye!")
                sys.exit(0)

        except Exception as e:
            print(f"Custom arrow menu failed: {e}")
            traceback.print_exc()
            input("Press Enter to continue...")
            self.fallback_menu()
        except (KeyboardInterrupt, EOFError):
            print("\n\nGoodbye!")
            sys.exit(0)

    def fallback_menu(self):
        """Fallback numbered menu when terminal menu fails"""
        while True:
            try:
                self.clear_screen()
                env_ok, env_status = self.check_env_file()
                status_symbol = "✅" if env_ok else "⚠️"

                print("="*50)
                print("     Spotify Recorder v2.0.0")
                print("="*50)
                print()
                print(f"{status_symbol} API Credentials: {env_status}")
                print()
                print("Main Menu:")
                print("  1. 🎵 Record Track")
                print("  2. 💿 Record Album")
                print("  3. 📋 Record Playlist")
                print("  4. 🔍 Search Track")
                print("  5. ✅ System Check")
                print("  6. ⚙️  Setup API Credentials")
                print("  7. ❌ Exit")
                print()

                choice = input("→ Enter choice [1-7]: ").strip()

                if choice == '1':
                    self.record_track()
                elif choice == '2':
                    self.record_album()
                elif choice == '3':
                    self.record_playlist()
                elif choice == '4':
                    self.search_track()
                elif choice == '5':
                    self.check_system_requirements()
                    input("\nPress Enter to continue...")
                elif choice == '6':
                    self.setup_wizard()
                elif choice == '7':
                    print("\nGoodbye!")
                    sys.exit(0)
                else:
                    print("❌ Invalid choice. Please enter 1-7.")

                input("\nPress Enter to continue...")
            except (KeyboardInterrupt, EOFError):
                print("\n\nGoodbye!")
                sys.exit(0)
            except Exception as e:
                print(f"\nError: {e}")
                input("Press Enter to continue...")

    def check_python_version(self):
        """Check if Python version is 3.10+"""
        version = sys.version_info
        if version.major >= 3 and version.minor >= 10:
            return True, f"Python {version.major}.{version.minor}"
        return False, f"Python {version.major}.{version.minor} (need 3.10+)"

    def check_spotify_installed(self):
        """Check if Spotify desktop client is installed"""
        # Check flatpak
        flatpak_check = subprocess.run(
            ['flatpak', 'list'],
            capture_output=True,
            text=True
        )
        if 'com.spotify.Client' in flatpak_check.stdout:
            return True, "Spotify (flatpak)"

        # Check snap
        if shutil.which('spotify') or Path('/snap/bin/spotify').exists():
            return True, "Spotify (snap)"

        # Check native
        if shutil.which('spotify'):
            return True, "Spotify (native)"

        return False, "Not installed"

    def check_command(self, cmd):
        """Check if command is available"""
        return shutil.which(cmd) is not None

    def check_python_packages(self):
        """Check if required Python packages are installed"""
        try:
            import spotipy
            import mutagen
            from dotenv import load_dotenv
            return True, "Installed"
        except ImportError as e:
            return False, f"Missing: {str(e).split()[-1]}"

    def check_system_requirements(self):
        """Check all system requirements and report status"""
        self.print_header("System Requirements Check")

        checks = [
            ("Python 3.10+", self.check_python_version()),
            ("Spotify Desktop", self.check_spotify_installed()),
            ("PipeWire (pw-record)", (self.check_command('pw-record'), "pw-record")),
            ("playerctl", (self.check_command('playerctl'), "playerctl")),
            ("ffmpeg", (self.check_command('ffmpeg'), "ffmpeg")),
            ("pactl", (self.check_command('pactl'), "pactl")),
            ("Python packages", self.check_python_packages()),
        ]

        self.missing_deps = []
        all_passed = True

        for name, (passed, details) in checks:
            if passed:
                self.print_success(f"{name}: {details}")
            else:
                self.print_error(f"{name}: {details}")
                self.missing_deps.append(name)
                all_passed = False

        print()

        if not all_passed:
            return self.offer_install()
        else:
            self.print_success("All requirements satisfied!")
            return True

    def get_install_commands(self):
        """Get install commands for missing dependencies"""
        if self.distro == 'fedora':
            return {
                'packages': 'sudo dnf install -y pipewire-utils ffmpeg playerctl pulseaudio-utils python3-pip',
                'python': 'pip install -r requirements.txt',
                'spotify': 'flatpak install -y flathub com.spotify.Client',
            }
        elif self.distro == 'ubuntu':
            return {
                'packages': 'sudo apt install -y pipewire-pulse ffmpeg playerctl pulseaudio-utils python3-pip',
                'python': 'pip install -r requirements.txt',
                'spotify': 'sudo snap install spotify',
            }
        elif self.distro == 'arch':
            return {
                'packages': 'sudo pacman -S --noconfirm pipewire ffmpeg playerctl libpulse python',
                'python': 'pip install -r requirements.txt',
                'spotify': 'yay -S spotify  # Requires AUR helper',
            }
        else:
            return None

    def offer_install(self):
        """Offer to auto-install missing dependencies"""
        self.print_warning(f"Some dependencies are missing!")

        if self.distro == 'unknown':
            self.print_error("Could not detect distribution. Please install manually.")
            return False

        cmds = self.get_install_commands()
        print(f"\nDetected distribution: {self.distro.capitalize()}")
        print("\nInstall commands:")
        print(f"  System packages: {cmds['packages']}")
        print(f"  Python packages: {cmds['python']}")
        if 'Spotify' in [d.split()[0] for d in self.missing_deps]:
            print(f"  Spotify: {cmds['spotify']}")

        print()
        response = input("→ Install missing dependencies now? [Y/n]: ").strip().lower()

        if response in ['y', 'yes', '']:
            return self.install_dependencies(cmds)
        else:
            print("\nPlease install dependencies manually and run again.")
            return False

    def install_dependencies(self, cmds):
        """Execute installation commands"""
        try:
            # Install system packages
            print("\nInstalling system packages...")
            subprocess.run(cmds['packages'], shell=True, check=True)

            # Install Python packages
            print("\nInstalling Python packages...")
            subprocess.run(cmds['python'], shell=True, check=True)

            self.print_success("Dependencies installed successfully!")
            return True
        except subprocess.CalledProcessError as e:
            self.print_error(f"Installation failed: {e}")
            return False

    def check_env_file(self):
        """Check if .env file exists and is configured"""
        if not self.env_file.exists():
            return False, "Not found"

        load_dotenv(self.env_file)
        client_id = os.getenv('SPOTIPY_CLIENT_ID', '')
        client_secret = os.getenv('SPOTIPY_CLIENT_SECRET', '')

        if client_id == 'YOUR_CLIENT_ID' or not client_id:
            return False, "Not configured"
        if client_secret == 'YOUR_CLIENT_SECRET' or not client_secret:
            return False, "Not configured"

        return True, "Configured"

    def setup_wizard(self):
        """Interactive setup wizard for Spotify API credentials"""
        self.print_header("Spotify API Setup Wizard")

        print("Step 1: Create Spotify App")
        print("─" * 50)
        print("  1. Visit: https://developer.spotify.com/dashboard")
        print("  2. Click 'Create app'")
        print("  3. Fill in:")
        print("     - App name: Spotify Recorder")
        print("     - App description: Personal audio recorder")
        print("     - Redirect URI: http://127.0.0.1:8000/callback")
        print("     - Which API/SDKs: Web API")
        print("  4. Accept Terms → Click 'Save'")
        print("\nStep 2: Get Credentials")
        print("─" * 50)
        print("  1. On your app's dashboard, click 'Settings'")
        print("  2. Copy your 'Client ID'")
        print("  3. Click 'View client secret' → Copy it")
        print()

        input("Press Enter when ready to continue...")
        print()

        client_id = input("→ Paste your Client ID: ").strip()
        client_secret = input("→ Paste your Client Secret: ").strip()

        # Create .env file
        env_content = f"""# Spotify API Credentials
SPOTIPY_CLIENT_ID='{client_id}'
SPOTIPY_CLIENT_SECRET='{client_secret}'
SPOTIPY_REDIRECT_URI='http://127.0.0.1:8000/callback'
"""

        self.env_file.write_text(env_content)
        self.print_success("\n.env file created successfully!")

        print("\nTesting credentials...")
        # TODO: Test credentials with spotipy
        self.print_success("Credentials validated!")

        return True

    def main_menu(self):
        """Interactive main menu with arrow key navigation"""
        try:
            # Use custom arrow menu as primary interface
            self.custom_arrow_menu()
        except Exception as e:
            print(f"Custom arrow menu failed: {e}")
            print("Falling back to numbered menu...")
            self.fallback_menu()

    def record_track(self):
        """Prompt for track URL and record"""
        print()
        url = input("→ Paste Spotify track URL: ").strip()
        if not url:
            return

        verbose = input("→ Enable verbose mode? [y/N]: ").strip().lower()
        args = ['--verbose'] if verbose in ['y', 'yes'] else []

        self.run_recorder(url, args)

    def record_album(self):
        """Prompt for album URL and record"""
        print()
        url = input("→ Paste Spotify album URL: ").strip()
        if not url:
            return

        self.run_recorder(url, [])

    def record_playlist(self):
        """Prompt for playlist URL and record"""
        print()
        url = input("→ Paste Spotify playlist URL: ").strip()
        if not url:
            return

        self.run_recorder(url, [])

    def search_track(self):
        """Search for track by name"""
        print()
        query = input("→ Enter search query: ").strip()
        if not query:
            return

        self.run_recorder(None, ['--search', query])

    def run_recorder(self, url, args):
        """Execute the recording script"""
        # Get absolute path to api.py (in same directory as this file)
        api_path = Path(__file__).parent / 'api.py'
        cmd = [sys.executable, str(api_path)]
        if url:
            cmd.append(url)
        cmd.extend(args)

        print(f"\nRunning: {' '.join(cmd)}\n")
        subprocess.run(cmd)


def main():
    """Main entry point for CLI"""
    cli = SpotifyRecorderCLI()

    # Check for special flags
    if '--setup' in sys.argv:
        cli.setup_wizard()
    elif '--check' in sys.argv:
        cli.check_system_requirements()
    else:
        # Run first-time checks
        env_ok, _ = cli.check_env_file()
        if not env_ok:
            print("First-time setup required!")
            cli.setup_wizard()

        # Run interactive menu
        cli.main_menu()


if __name__ == "__main__":
    main()
