#!/bin/bash
# Spotify Recorder Installation Script for Fedora 42+

set -e

echo "=== Spotify Recorder Installation ==="
echo ""

# Check if running on Fedora
if [ -f /etc/fedora-release ]; then
    echo "✓ Detected Fedora"
    FEDORA_VERSION=$(rpm -E %fedora)
    echo "  Version: $FEDORA_VERSION"
else
    echo "⚠ Warning: This script is optimized for Fedora 42+"
    echo "  You may need to adjust package names for your distribution"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo ""
echo "Step 1: Installing system dependencies..."

# Check for required packages
PACKAGES="pipewire-utils ffmpeg grep coreutils playerctl"

for pkg in $PACKAGES; do
    if rpm -q $pkg &>/dev/null; then
        echo "  ✓ $pkg already installed"
    else
        echo "  → Installing $pkg..."
        sudo dnf install -y $pkg
    fi
done

# Check for Spotify
if command -v spotify &>/dev/null || [ -x /snap/bin/spotify ]; then
    echo "  ✓ Spotify already installed"
else
    echo "  ⚠ Spotify not found"
    echo "  Please install Spotify from: https://www.spotify.com/download/linux/"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo ""
echo "Step 2: Installing Python dependencies..."

# Check if uv is available
if command -v uv &>/dev/null; then
    echo "  ✓ uv found, using uv for dependency installation"
    uv sync
else
    echo "  ℹ uv not found, would you like to install it? (recommended for faster installs)"
    read -p "Install uv? (Y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo "  → Installing uv..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.cargo/bin:$PATH"
        uv sync
    else
        echo "  → Using pip..."
        pip install -r requirements.txt
    fi
fi

echo ""
echo "Step 3: Setting up Spotify API credentials..."

# Change to project root (parent of src/)
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
    echo "  → Creating .env file from template"
    cat > .env << 'EOF'
SPOTIPY_CLIENT_ID='YOUR_CLIENT_ID'
SPOTIPY_CLIENT_SECRET='YOUR_CLIENT_SECRET'
SPOTIPY_REDIRECT_URI='http://127.0.0.1:8000/callback'
EOF
    echo "  ✓ .env file created"
else
    echo "  ✓ .env file already exists"
fi

# Check if credentials are set
if grep -q "YOUR_CLIENT_ID" .env; then
    echo ""
    echo "⚠ Please update .env with your Spotify API credentials:"
    echo "  1. Visit: https://developer.spotify.com/dashboard"
    echo "  2. Create a new app"
    echo "  3. Set Redirect URI: http://127.0.0.1:8000/callback"
    echo "  4. Copy Client ID and Secret to .env file"
    echo ""
    read -p "Press Enter when done..."
fi

echo ""
echo "Step 4: Verifying installation..."

# Check Python modules
python3 -c "import spotipy, mutagen, dotenv" 2>/dev/null && echo "  ✓ Python dependencies OK" || echo "  ✗ Python dependencies missing"

# Check PipeWire
if command -v pw-record &>/dev/null; then
    PW_VERSION=$(pw-record --version 2>&1 | head -n1)
    echo "  ✓ PipeWire recording available: $PW_VERSION"
else
    echo "  ✗ pw-record not found"
    exit 1
fi

# Make scripts executable
chmod +x spotdl.sh 2>/dev/null || true
chmod +x api.py 2>/dev/null || true

echo ""
echo "=== Installation Complete! ==="
echo ""
echo "Next steps:"
echo "  1. Ensure .env has valid Spotify API credentials"
echo "  2. Run: python3 api.py --help"
echo "  3. Try recording: python3 api.py <spotify-link>"
echo ""
echo "For more information, see README.md and MODERNIZATION.md"
