#!/usr/bin/env python3
"""Build the FastDL (HTTP download) tree for tf2cc's client files.

  python make_fastdl.py <server tf folder> <output folder>
  python make_fastdl.py ./tf ./fastdl

Reads addons/sourcemod/configs/tf2cc/downloads.txt inside the tf folder (the
same list the plugin hands to the game) and writes every listed file as
<output>/tf/<path>.bz2 - the layout Source clients request from sv_downloadurl.
Upload the CONTENTS of <output> to your web host so that
<sv_downloadurl>/models/... resolves (see docs/FASTDL.md). Needs only Python 3.
Files already compressed and newer than their source are skipped.
"""
import bz2
import os
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    tf, out = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    listing = os.path.join(tf, "addons", "sourcemod", "configs", "tf2cc", "downloads.txt")
    if not os.path.isfile(listing):
        sys.exit("not found: %s (point the first argument at the server's tf folder)" % listing)
    done = skipped = missing = 0
    for line in open(listing, encoding="utf-8"):
        rel = line.strip()
        if not rel or rel.startswith(("//", "#")):
            continue
        src = os.path.join(tf, *rel.split("/"))
        if not os.path.isfile(src):
            print("missing on server: " + rel)
            missing += 1
            continue
        dst = os.path.join(out, "tf", *rel.split("/")) + ".bz2"
        if os.path.isfile(dst) and os.path.getmtime(dst) >= os.path.getmtime(src):
            skipped += 1
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(src, "rb") as f, bz2.open(dst, "wb", compresslevel=9) as g:
            g.write(f.read())
        done += 1
    print("%d compressed, %d up to date, %d missing -> %s" % (done, skipped, missing, os.path.join(out, "tf")))
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
