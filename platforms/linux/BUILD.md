# Trojan Horse — Linux Build Instructions

## Dependencies

### Debian/Ubuntu/Mint:
```bash
sudo apt install \
  libwebkit2gtk-4.1-dev \
  libgtk-3-dev \
  nlohmann-json3-dev \
  build-essential \
  pkg-config
```

### Fedora/RHEL:
```bash
sudo dnf install webkit2gtk4.1-devel gtk3-devel nlohmann-json-devel gcc-c++
```

### Arch Linux:
```bash
sudo pacman -S webkit2gtk-4.1 gtk3 nlohmann-json base-devel
```

## Build
```bash
g++ main.cpp -o trojan-horse \
  $(pkg-config --cflags --libs webkit2gtk-4.1 gtk+-3.0) \
  -std=c++17 -lpthread
```

## Install (optional)
```bash
sudo cp trojan-horse /usr/local/bin/
sudo cp -r apps/ /usr/local/share/trojan-horse/
```

## App Structure
Place next to trojan-horse binary:
```
trojan-horse
apps/
  phantom/
    index.html
  home/
    index.html
phantom_api.py
venv/
  bin/
    python3
```

## Systemd Service (optional — auto-start on login)
```ini
[Unit]
Description=Trojan Horse

[Service]
ExecStart=/usr/local/bin/trojan-horse
Restart=on-failure

[Install]
WantedBy=default.target
```

## Notes
- Serial ports: /dev/ttyUSB*, /dev/ttyACM*
- Notifications: requires libnotify / notify-send
- Tested on Ubuntu 22.04+, Debian 12+, Fedora 38+, Arch
- For Raspberry Pi: same build, targets ARM natively
