"""Launch an isolated Jellyfin server and index two synthetic videos."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time
from urllib.parse import urlencode
from urllib.request import Request, urlopen

work, evidence = map(Path, sys.argv[1:])
base = "http://127.0.0.1:18096"
name, password = "QA", "StreamyfinFixture2536"
auth = 'MediaBrowser Client="QA fixture", Device="Runner", DeviceId="streamyfin-2536", Version="1.0"'
token = None


def request(path, body=None, method="GET"):
    headers = {"Authorization": auth + (f', Token="{token}"' if token else "")}
    if body is not None:
        headers["Content-Type"] = "application/json"
    raw = json.dumps(body).encode() if body is not None else None
    with urlopen(Request(base + path, raw, headers, method=method), timeout=8) as response:
        data = response.read()
        return json.loads(data) if data else None


def until(operation, description, attempts=60):
    for attempt in range(attempts):
        try:
            result = operation()
            if result:
                return result
        except (OSError, ValueError):
            if attempt == attempts - 1:
                raise
        time.sleep(2)
    raise RuntimeError(f"Timed out waiting for {description}")


def unpack(name, url):
    archive = work / f"{name}.tar.xz"
    folder = work / name
    folder.mkdir()
    subprocess.run(["curl", "-fsSL", "--retry", "3", "--max-time", "120", url, "-o", str(archive)], check=True)
    subprocess.run(["tar", "-xJf", str(archive), "-C", str(folder)], check=True)
    archive.unlink()
    return next(path for path in folder.rglob(name) if path.is_file())


server = unpack("jellyfin", "https://sfo1.mirror.jellyfin.org/files/server/macos/latest/arm64/jellyfin_12.4-arm64.tar.xz")
ffmpeg = unpack("ffmpeg", "https://github.com/jellyfin/jellyfin-ffmpeg/releases/download/v8.1.3-2/jellyfin-ffmpeg_8.1.3-2_portable_macarm64-gpl.tar.xz")
config = work / "config"
config.mkdir()
(config / "network.xml").write_text("""<NetworkConfiguration>
  <EnableIPv4>true</EnableIPv4><EnableIPv6>false</EnableIPv6>
  <InternalHttpPort>18096</InternalHttpPort>
  <LocalNetworkAddresses><string>127.0.0.1</string></LocalNetworkAddresses>
  <EnableRemoteAccess>false</EnableRemoteAccess>
  <EnableAutoDiscovery>false</EnableAutoDiscovery>
</NetworkConfiguration>""")

media = work / "media"
movie = media / "Movies" / "Fixture Movie (2020)" / "Fixture Movie (2020).mp4"
episode = media / "Shows" / "Fixture Series" / "Season 01" / "Fixture Series S01E01.mp4"
for file in (movie, episode):
    file.parent.mkdir(parents=True)
subprocess.run([
    str(ffmpeg), "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24",
    "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "35",
    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart", str(movie)
], check=True)
shutil.copyfile(movie, episode)
movie.with_suffix(".nfo").write_text("<movie><title>Fixture Movie</title><year>2020</year></movie>")
(episode.parent.parent / "tvshow.nfo").write_text("<tvshow><title>Fixture Series</title></tvshow>")
episode.with_suffix(".nfo").write_text("<episodedetails><title>Fixture Episode</title><season>1</season><episode>1</episode></episodedetails>")

with (evidence / "jellyfin.log").open("w") as log:
    process = subprocess.Popen([
        str(server), "--datadir", str(work / "data"), "--configdir", str(config),
        "--cachedir", str(work / "cache"), "--logdir", str(work / "logs"),
        "--ffmpeg", str(ffmpeg), "--nonetchange", "--nowebclient"
    ], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
(work / "server.pid").write_text(str(process.pid))

def ready_info():
    # The setup listener answers before the media server finishes its database
    # migrations. Only the real public info endpoint returns Version.
    response = request("/System/Info/Public")
    if isinstance(response, dict) and response.get("Version"):
        return response
    return None


info = until(ready_info, "Jellyfin public server information")
assert info["Version"] == "12.4.0", info["Version"]
request("/Startup/Configuration", {
    "ServerName": "Fixture Jellyfin", "UICulture": "en-US",
    "MetadataCountryCode": "US", "PreferredMetadataLanguage": "en"
}, "POST")
request("/Startup/User")
request("/Startup/User", {"Name": name, "Password": password}, "POST")
request("/Startup/RemoteAccess", {"EnableRemoteAccess": False, "EnableAutomaticPortMapping": False}, "POST")
request("/Startup/Complete", method="POST")
login = request("/Users/AuthenticateByName", {"Username": name, "Pw": password}, "POST")
token = login["AccessToken"]
user = login["User"]["Id"]

library_name = "Mixed Fixture"
providers = ["TheMovieDb", "TheMovieDbBoxSets", "OMDb", "TheTVDB", "Fanart"]
request("/Library/VirtualFolders?" + urlencode({
    "name": library_name, "paths": str(media), "refreshLibrary": "true"
}), {"LibraryOptions": {
    "EnableRealtimeMonitor": False,
    "MetadataOptions": [
        {"ItemType": kind, "DisabledMetadataFetchers": providers, "DisabledImageFetchers": providers}
        for kind in ("Movie", "Series", "Season", "Episode")
    ],
}}, "POST")
library = until(lambda: next((item["Id"] for item in request(
    "/UserViews?" + urlencode({"userId": user})
)["Items"] if item["Name"] == library_name), None), "the mixed library collection")

items_path = "/Items?" + urlencode({"parentId": library, "userId": user, "recursive": "true"})
required = {"Movie", "Series", "Season", "Episode"}
for i in range(60):
    types = {item["Type"] for item in request(items_path)["Items"]}
    if required <= types:
        break
    if i == 4:
        request("/Library/Refresh", method="POST")
    time.sleep(2)
else:
    raise RuntimeError(f"Fixture contains {types}, expected {required}")
print("Jellyfin indexed the movie, series, season and episode.")
