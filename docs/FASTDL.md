# Setting up FastDL for tf2cc

tf2cc's client content (models, textures and sounds for the Mercenary, Civilian and
their weapons) is about **300 MB in 1,150 files** (about 140 MB compressed for FastDL). Without FastDL, players download it
from the game server through the game's own slow transfer, which can take many minutes
and is capped at 16 MB per file by default. With FastDL, players fetch compressed copies
over normal HTTP from a web host, usually in well under a minute.

## How it works

1. The game server tells each player its `sv_downloadurl`, for example
   `https://dl.example.com/tf/`.
2. For every file the player is missing, the game requests
   `<sv_downloadurl><path>.bz2`, for example
   `https://dl.example.com/tf/models/player/tf2cc/mercenary.mdl.bz2`.
3. If that fails, it tries the uncompressed `<path>`, then falls back to downloading from
   the game server.

Any web host that serves static files works: your own web server (nginx, Apache, IIS),
object storage (Amazon S3, Cloudflare R2, Backblaze B2), or GitHub Pages / a public
GitHub repository. The host only needs to return the files over plain HTTP(S) GET.

## Step 1: Build the compressed files

You need Python 3. From this repository's root, run:

```
python tools/make_fastdl.py tf fastdl
```

- The first argument is a `tf` folder that contains `addons/sourcemod/configs/tf2cc/downloads.txt`
  and the content. This repository's `tf/` folder or your server's `tf/` folder both work.
- The second argument is the output folder.

The script reads `downloads.txt` (the same list the plugin gives to the game) and writes
`fastdl/tf/<path>.bz2` for every file. Run it again after updates: it only recompresses
files that changed.

## Step 2: Upload

Upload the **contents** of `fastdl/` to your web host, keeping the folder structure. The
result must look like this:

```
https://dl.example.com/tf/models/player/tf2cc/mercenary.mdl.bz2
https://dl.example.com/tf/sound/vo/custom/civilian_battlecry01.wav.bz2
...
```

Notes for some hosts:

- **Existing FastDL for maps:** put tf2cc's files into the same `tf/` tree, next to
  `maps/`. One `sv_downloadurl` serves both.
- **Web servers:** don't let the server re-compress `.bz2` files or add a
  `Content-Encoding` header to them. Serve them as `application/octet-stream`.
- **GitHub repository / Pages:** a single file must be under 100 MB (every tf2cc file
  is). If you use a GitHub Pages site, the URL is
  `https://<user>.github.io/<repo>/tf/`.
- **Object storage:** make the bucket (or the `tf/` prefix) publicly readable.

## Step 3: Point the server at it

Add these lines to `tf/cfg/server.cfg`. The trailing slash in the URL matters:

```
sv_downloadurl "https://dl.example.com/tf/"
sv_allowdownload 1
net_maxfilesize 64
```

Restart the server or change map.

## Step 4: Test

1. On a test PC, delete or rename your client's `tf/download/models/player/tf2cc/`
   folder, so the game has to download.
2. Join the server. The loading screen should show files arriving quickly from the URL.
3. In-game, pick `!merc` and check the model has textures (no purple-and-black
   checkerboard).

Open one URL in a browser, for example
`https://dl.example.com/tf/models/player/tf2cc/mercenary.mdl.bz2`. It must download a
file, not show an error page. If it 404s, the folder layout is off by one level: check
whether the `tf/` folder ended up nested inside another `tf/`.

## Updating

When a tf2cc update changes client content, it ships the changed models in a **new
revision folder**, for example `models/weapons/tf2cc_r3/` replacing `tf2cc_r2/`. Players
only download files they don't already have, so a changed file under an old name would
never reach anyone who has the old one.

After each update:
1. copy the new `tf/` folder to the game server;
2. run `make_fastdl.py` again;
3. upload the new files.

Old revision folders can stay on the host or be deleted.
