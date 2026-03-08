# cc-music

Self-hosted ComputerCraft streaming music. Fork of [computercraft-streaming-music](https://github.com/terreng/computercraft-streaming-music) — replaces Firebase + RapidAPI with a self-hosted PHP backend using `yt-dlp` and `ffmpeg`.

**No API keys. No vendor timeouts. No limits.**

---

## Requirements

### VPS / Server
- PHP 8.x with `popen`/`shell_exec` enabled
- [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) in `$PATH`
- [`ffmpeg`](https://ffmpeg.org/) in `$PATH`
- Apache with `mod_rewrite` **or** Nginx

### In-Game
- [CC: Tweaked](https://tweaked.cc/) mod v1.100.0+
- Advanced Computer + Speaker, or Advanced Noisy Pocket Computer

---

## Server Setup

### 1. Install dependencies (Ubuntu/Debian)

```bash
apt install php ffmpeg
pip install yt-dlp
# or: wget https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -O /usr/local/bin/yt-dlp && chmod +x /usr/local/bin/yt-dlp
```

### 2. Deploy files

Copy the contents of `server/` to your web root (e.g. `/var/www/cc-music/`):

```
/var/www/cc-music/
├── index.php
└── .htaccess   (Apache only)
```

### 3. Nginx config (if not using Apache)

Add the snippet from `server/nginx.conf` inside your `server {}` block, pointing `root` at your deploy directory. Key settings:

```nginx
fastcgi_read_timeout 86400;   # allow 24h streams
fastcgi_buffering off;         # don't buffer audio — stream directly
```

### 4. Update music.lua

Edit line 1 of `music.lua` to point at your server:

```lua
local api_base_url = "https://your-domain.com/"
```

Then transfer `music.lua` to your ComputerCraft computer and run it:

```
music
```

---

## API

The PHP script exposes the same query interface as the original Firebase function, so the Lua client is compatible without changes (beyond the URL).

| Request | Response |
|---|---|
| `GET /?search=<query>` | JSON array of search results |
| `GET /?search=<youtube-url>` | JSON array with single video or playlist |
| `GET /?id=<video_id>` | Raw DFPWM audio stream (48kHz mono) |

### Search result shape

```json
[
  {
    "id": "dQw4w9WgXcQ",
    "name": "Never Gonna Give You Up",
    "artist": "3:33 · Rick Astley"
  }
]
```

### Playlist shape

```json
[
  {
    "id": "PLxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "name": "My Playlist",
    "artist": "Playlist · 12 videos · Channel Name",
    "type": "playlist",
    "playlist_items": [ ... ]
  }
]
```

---

## Key Differences from Original

| | Original | cc-music |
|---|---|---|
| Backend | Firebase Cloud Functions | PHP on any VPS |
| Audio source | RapidAPI (paid, rate-limited) | `yt-dlp` (free, self-hosted) |
| Max track length | ~60s function timeout | Unlimited (`set_time_limit(0)`) |
| API key required | Yes | No |
| Deploy | Firebase CLI | Copy 1 PHP file |

---

## Troubleshooting

- **"Network error" in-game** — check that `yt-dlp` and `ffmpeg` are in `$PATH` for the PHP process (try `which yt-dlp` and `which ffmpeg`)
- **Audio stops mid-track** — ensure `fastcgi_read_timeout` (Nginx) or PHP `max_execution_time` is set to 0 / very large
- **Search returns empty** — `yt-dlp` may need updating: `yt-dlp -U`
- **"No speakers attached"** — restart Minecraft; if using a Noisy Pocket Computer this is a known CC:Tweaked quirk

---

## License

MIT. Based on [computercraft-streaming-music](https://github.com/terreng/computercraft-streaming-music) by terreng (MIT).
