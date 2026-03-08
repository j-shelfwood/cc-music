# cc-music

**Self-hosted streaming music for ComputerCraft: Tweaked.**
Search YouTube, stream audio in-game, queue and shuffle tracks — no mods beyond CC:Tweaked required.

---

## Inspiration & Attribution

cc-music is a ground-up reimplementation inspired by [computercraft-streaming-music](https://github.com/terreng/computercraft-streaming-music) by [terreng](https://github.com/terreng), which demonstrated that DFPWM streaming via HTTP is viable in CC:Tweaked and built the original Firebase + RapidAPI architecture.

**What we changed and why:**

| Original | cc-music |
|---|---|
| Firebase Cloud Functions (60s timeout) | PHP on any VPS — unlimited stream duration |
| RapidAPI YT-API (paid, rate-limited, key required) | `yt-dlp` — free, self-hosted, no keys |
| Firebase deploy pipeline | One PHP file, drop anywhere |
| 5 fixed search results | 10 results with pagination |
| No wired modem speaker support | Discovers speakers across wired networks |
| No monitor output | Fancy now-playing display on any attached monitor |
| Volume change restarts track | Volume applies live on next audio chunk |
| No shuffle | Shuffle mode for queue |
| No queue management | Per-item remove, clear queue, scroll |

---

## Quick install via MPM

If you have [MPM](https://github.com/Bitcraft-Creations/mpm) installed:

```
mpm install cc-music
mpm run cc-music
```

To install MPM first:
```
wget run https://shelfwood-mpm.netlify.app/install.lua
```

cc-music is featured in the `mpm intro` tutorial — just say yes when prompted.

---

## Manual install

Transfer `music.lua` to your ComputerCraft computer (drag and drop onto the Minecraft window, or use `wget`):

```
wget https://raw.githubusercontent.com/j-shelfwood/cc-music/main/music.lua music
```

Then run it:
```
music
```

The script connects to the public backend at `https://cc-music.shelfwood.co/` by default. No setup required — just a speaker and an internet connection.

---

## In-game requirements

- [CC: Tweaked](https://tweaked.cc/) v1.100.0+ (December 2021 or later)
- **Advanced Computer** (for colour UI) — Standard Computer works but looks plain
- **Speaker** — attached directly, or connected via wired modem network
- **Monitor** (optional) — Advanced Monitor shows a now-playing display

---

## Usage

| Control | Action |
|---|---|
| Click result → Play now | Stop current, play immediately |
| Click result → Play next | Insert at front of queue |
| Click result → + Queue | Append to queue |
| **Stop / Play** button | Pause and resume |
| **Skip** button | Next track in queue |
| **Loop** button | Cycle: Off → Loop Queue → Loop Song |
| **Shuf** button | Toggle shuffle (also shuffles existing queue) |
| Volume bar | Click or drag to adjust — applies on next audio chunk |
| **[x]** next to queue item | Remove that track |
| **Clear queue** | Remove all queued tracks |
| Scroll wheel | Scroll queue (Now Playing tab) or paginate results (Search tab) |
| Paste a YouTube URL | Resolves single video or entire playlist |

---

## Public instance

The backend at `https://cc-music.shelfwood.co/` is open for anyone to use. It runs on a VPS using the Docker setup in this repo. `yt-dlp` and `ffmpeg` handle all audio — no API keys, no rate limits beyond VPS bandwidth.

If the public instance is down or you want your own, self-hosting takes about 5 minutes.

---

## Self-host the backend

### Option A — Docker (recommended)

```bash
git clone https://github.com/j-shelfwood/cc-music.git
cd cc-music
docker compose up -d
```

Then point a reverse proxy (Caddy, Nginx) at `127.0.0.1:3001`.

### Option B — Bare PHP

**Requirements:** PHP 8.x, `yt-dlp` in `$PATH`, `ffmpeg` in `$PATH`

```bash
apt install php ffmpeg
wget https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
     -O /usr/local/bin/yt-dlp && chmod +x /usr/local/bin/yt-dlp
```

Copy `server/index.php` (and `server/.htaccess` for Apache, or use `server/nginx.conf` snippet) to your web root.

**Nginx — critical settings:**
```nginx
fastcgi_read_timeout 86400;  # streams can run for 40+ minutes
fastcgi_buffering off;        # don't buffer audio in memory
```

### After setup — point music.lua at your server

Edit line 4 of `music.lua`:
```lua
local api_base_url = "https://your-domain.com/"
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| "No speakers found" | Connect a speaker directly or via wired modem; restart Minecraft |
| "Network error" | Check `yt-dlp` and `ffmpeg` are in PATH; run `yt-dlp -U` to update |
| Audio stops mid-track | Ensure `fastcgi_read_timeout` is 0 or very large in Nginx config |
| Search returns empty | Run `yt-dlp -U` on the server; YouTube occasionally breaks yt-dlp |
| Monitor shows nothing | Must be an **Advanced** Monitor; plain monitors don't support colour |
| Pocket Computer: "No speakers" | Restart Minecraft — known CC:Tweaked quirk |

---

## License

MIT — see [LICENSE](LICENSE).

Based on [computercraft-streaming-music](https://github.com/terreng/computercraft-streaming-music) by [terreng](https://github.com/terreng), also MIT.
