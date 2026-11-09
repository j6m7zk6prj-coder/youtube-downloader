#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
YouTube Downloader – interface « liquid glass » (HTML/CSS dans une fenêtre native
Edge WebView2) + moteur yt-dlp/ffmpeg.

Dépendances : pip install pywebview yt-dlp imageio-ffmpeg
"""

import os
import re
import sys
import json
import time
import ctypes
import threading
import traceback
import subprocess

import webview
import yt_dlp

APP_NAME = "YouTube Downloader"
IS_WIN = os.name == "nt"
SETTINGS_DIR = os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), "YouTubeDownloader")
SETTINGS_FILE = os.path.join(SETTINGS_DIR, "settings.json")
LOG_FILE = os.path.join(SETTINGS_DIR, "erreurs.log")
BUCKETS = [4320, 2160, 1440, 1080, 720, 480, 360]
ANSI = re.compile(r"\x1b\[[0-9;]*m")


# --------------------------------------------------------------------------- #
#  Utilitaires
# --------------------------------------------------------------------------- #
def resource(name):
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, name)


def log_error(text):
    try:
        os.makedirs(SETTINGS_DIR, exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + text + "\n")
    except Exception:
        pass


def load_settings():
    try:
        with open(SETTINGS_FILE, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_settings(data):
    try:
        os.makedirs(SETTINGS_DIR, exist_ok=True)
        with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
    except Exception:
        pass


def find_ffmpeg():
    import shutil
    path = shutil.which("ffmpeg")
    if path:
        return path
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return None


def read_clipboard():
    if not IS_WIN:
        return ""
    try:
        user32, kernel32 = ctypes.windll.user32, ctypes.windll.kernel32
        user32.GetClipboardData.restype = ctypes.c_void_p
        kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
        kernel32.GlobalLock.restype = ctypes.c_void_p
        kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
        if not user32.OpenClipboard(None):
            return ""
        try:
            handle = user32.GetClipboardData(13)  # CF_UNICODETEXT
            if not handle:
                return ""
            ptr = kernel32.GlobalLock(handle)
            try:
                return ctypes.wstring_at(ptr) if ptr else ""
            finally:
                kernel32.GlobalUnlock(handle)
        finally:
            user32.CloseClipboard()
    except Exception:
        return ""


def is_youtube(text):
    return bool(re.match(r"^\s*(https?://)?([\w-]+\.)?(youtube\.com|youtu\.be)/", text or "", re.I))


def clean_error(e):
    msg = ANSI.sub("", str(e)).strip()
    msg = re.sub(r"^ERROR:\s*", "", msg)
    msg = re.sub(r"^\[[^\]]+\]\s*[\w-]+:\s*", "", msg)
    if "Private video" in msg:
        return "Cette vidéo est privée."
    if "Video unavailable" in msg:
        return "Cette vidéo n'est pas disponible."
    if "Sign in to confirm your age" in msg:
        return "Vidéo soumise à une limite d'âge : connexion YouTube requise."
    if "Unsupported URL" in msg or "is not a valid URL" in msg:
        return "Ce lien n'est pas un lien YouTube valide."
    if "getaddrinfo" in msg or "Failed to resolve" in msg:
        return "Pas de connexion Internet."
    return msg[:300] or "Erreur inconnue."


def short_side(f):
    note = f.get("format_note") or ""
    m = re.search(r"(\d{3,4})p", note)
    if m:
        return int(m.group(1))
    w, h = f.get("width"), f.get("height")
    if w and h:
        return min(w, h)
    return h


def fsize(f, duration):
    s = f.get("filesize") or f.get("filesize_approx")
    if not s and f.get("tbr") and duration:
        s = f["tbr"] * 125 * duration
    return int(s or 0)


def round_corners(title):
    """Coins arrondis Windows 11 pour la fenêtre sans bordure."""
    if not IS_WIN:
        return
    try:
        hwnd = ctypes.windll.user32.FindWindowW(None, title)
        if hwnd:
            pref = ctypes.c_int(2)  # DWMWCP_ROUND
            ctypes.windll.dwmapi.DwmSetWindowAttribute(hwnd, 33, ctypes.byref(pref), ctypes.sizeof(pref))
    except Exception:
        pass


class Cancelled(Exception):
    pass


# --------------------------------------------------------------------------- #
#  API exposée au JavaScript
# --------------------------------------------------------------------------- #
class Api:
    def __init__(self):
        self._window = None
        self._settings = load_settings()
        default = os.path.join(os.path.expanduser("~"), "Downloads")
        self._folder = self._settings.get("folder") or default
        self._cancel = threading.Event()
        self._busy = False
        self._ffmpeg = find_ffmpeg()
        self._last_push = 0.0

    # ----- fenêtre -----
    def init(self):
        clip = read_clipboard().strip()
        return {
            "folder": self._folder,
            "clipboard": clip if is_youtube(clip) else "",
            "version": yt_dlp.version.__version__,
            "ffmpeg": bool(self._ffmpeg),
        }

    def close(self):
        self._cancel.set()
        self._window.destroy()

    def minimize(self):
        self._window.minimize()

    def paste(self):
        return read_clipboard().strip()

    # ----- dossier -----
    def choose_folder(self):
        kind = getattr(getattr(webview, "FileDialog", None), "FOLDER", None)
        if kind is None:
            kind = webview.FOLDER_DIALOG
        res = self._window.create_file_dialog(kind, directory=self._folder)
        if res:
            self._folder = res[0] if isinstance(res, (list, tuple)) else res
            self._settings["folder"] = self._folder
            save_settings(self._settings)
            return self._folder
        return None

    def open_folder(self):
        os.makedirs(self._folder, exist_ok=True)
        if IS_WIN:
            os.startfile(self._folder)
        else:
            subprocess.Popen(["xdg-open", self._folder])

    def reveal(self, path):
        if path and os.path.exists(path) and IS_WIN:
            subprocess.Popen(f'explorer /select,"{os.path.normpath(path)}"')
        else:
            self.open_folder()

    # ----- analyse du lien -----
    def analyze(self, url):
        try:
            opts = {"quiet": True, "no_warnings": True, "noplaylist": True,
                    "extract_flat": "in_playlist", "skip_download": True}
            with yt_dlp.YoutubeDL(opts) as ydl:
                info = ydl.extract_info(url.strip(), download=False)
        except Exception as e:
            return {"error": clean_error(e)}

        has_list = "list=" in url
        if info.get("_type") == "playlist":
            entries = list(info.get("entries") or [])
            thumb = None
            if entries:
                th = entries[0].get("thumbnails") or []
                thumb = th[-1]["url"] if th else None
            return {
                "title": info.get("title"), "channel": info.get("uploader") or info.get("channel"),
                "is_playlist": True, "has_list": True, "count": len(entries),
                "thumbnail": thumb or info.get("thumbnail"),
            }

        duration = info.get("duration") or 0
        formats = info.get("formats") or []
        videos = [f for f in formats if f.get("vcodec") not in (None, "none")]
        audios = [f for f in formats if f.get("acodec") not in (None, "none") and f.get("vcodec") in (None, "none")]
        m4a = [f for f in audios if f.get("ext") == "m4a"]
        audio_size = max((fsize(f, duration) for f in (m4a or audios)), default=0)

        sizes = {}
        for f in videos:
            side = short_side(f)
            if not side:
                continue
            bucket = next((b for b in BUCKETS if side >= b * 0.93), None)
            if bucket is None:
                continue
            s = fsize(f, duration)
            if s + audio_size > sizes.get(bucket, 0):
                sizes[bucket] = s + audio_size
        max_h = max(sizes) if sizes else 0
        labels = {4320: "8K", 2160: "4K", 1440: "1440p", 1080: "1080p", 720: "720p", 480: "480p", 360: "360p"}

        return {
            "title": info.get("title"),
            "channel": info.get("uploader") or info.get("channel"),
            "views": info.get("view_count"),
            "duration": duration,
            "thumbnail": info.get("thumbnail"),
            "is_playlist": False,
            "has_list": has_list,
            "count": 1,
            "sizes": {str(k): v for k, v in sizes.items()},
            "max_height": max_h,
            "max_label": labels.get(max_h, ""),
            "audio_size": audio_size,
        }

    # ----- téléchargement -----
    def download(self, url, opts):
        if self._busy:
            return False
        self._busy = True
        self._cancel.clear()
        threading.Thread(target=self._run, args=(url.strip(), opts), daemon=True).start()
        return True

    def cancel(self):
        self._cancel.set()

    def _push(self, data, force=False):
        now = time.monotonic()
        if not force and now - self._last_push < 0.12:
            return
        self._last_push = now
        try:
            self._window.evaluate_js(f"window.onProgress({json.dumps(data)})")
        except Exception:
            pass

    def _run(self, url, o):
        files = []

        def progress_hook(d):
            if self._cancel.is_set():
                raise Cancelled()
            if d["status"] == "downloading":
                total = d.get("total_bytes") or d.get("total_bytes_estimate")
                done = d.get("downloaded_bytes") or 0
                info = d.get("info_dict") or {}
                vc, ac = info.get("vcodec"), info.get("acodec")
                kind = "video" if vc not in (None, "none") else ("audio" if ac not in (None, "none") else "")
                self._push({
                    "status": "downloading",
                    "pct": (done / total * 100) if total else None,
                    "done": done, "total": total,
                    "speed": d.get("speed"), "eta": d.get("eta"),
                    "kind": kind if o.get("mode") == "video" else "audio",
                    "i": info.get("playlist_index") or 1, "n": info.get("n_entries") or 1,
                })

        def pp_hook(d):
            if self._cancel.is_set():
                raise Cancelled()
            if d["status"] == "started":
                names = {
                    "Merger": "Assemblage de l'image et du son",
                    "FFmpegExtractAudio": f"Conversion en {o.get('audio', 'mp3').upper()}",
                    "FFmpegEmbedSubtitle": "Ajout des sous-titres",
                    "EmbedThumbnail": "Ajout de la pochette",
                    "FFmpegMetadata": "Ajout des informations",
                }
                text = names.get(d.get("postprocessor"))
                if text:
                    self._push({"status": "processing", "text": text + "…"}, force=True)

        ydl_opts = {
            "outtmpl": os.path.join(self._folder, "%(title)s [%(id)s].%(ext)s"),
            "noplaylist": not o.get("playlist"),
            "progress_hooks": [progress_hook],
            "postprocessor_hooks": [pp_hook],
            "post_hooks": [lambda path: files.append(path)],
            "quiet": True, "no_warnings": True, "noprogress": True,
            "windowsfilenames": True,
            "retries": 10, "fragment_retries": 10,
            "concurrent_fragment_downloads": 4,
            "ignoreerrors": "only_download" if o.get("playlist") else False,
            "postprocessors": [],
        }
        if self._ffmpeg:
            ydl_opts["ffmpeg_location"] = self._ffmpeg

        if o.get("mode") == "audio":
            codec = o.get("audio") or "mp3"
            ydl_opts["format"] = "bestaudio[ext=m4a]/bestaudio/best" if codec == "m4a" else "bestaudio/best"
            ydl_opts["postprocessors"].append({
                "key": "FFmpegExtractAudio", "preferredcodec": codec,
                "preferredquality": "320" if codec == "mp3" else "0",
            })
            ydl_opts["postprocessors"].append({"key": "FFmpegMetadata"})
            if codec == "mp3":
                ydl_opts["writethumbnail"] = True
                ydl_opts["postprocessors"].append({"key": "FFmpegThumbnailsConvertor", "format": "jpg", "when": "before_dl"})
                ydl_opts["postprocessors"].append({"key": "EmbedThumbnail"})
        else:
            h = int(o.get("quality") or 0)
            container = o.get("container") or "mp4"
            sort = [f"res:{h}"] if h else ["res"]
            if container == "mp4":
                sort.append("ext:mp4:m4a")  # flux natifs MP4/AAC : lisibles partout
            ydl_opts["format"] = "bv*+ba/b"
            ydl_opts["format_sort"] = sort
            ydl_opts["merge_output_format"] = container
            ydl_opts["postprocessors"].append({"key": "FFmpegMetadata"})
            if o.get("subs"):
                ydl_opts.update({"writesubtitles": True, "subtitleslangs": ["fr.*", "en.*"]})
                ydl_opts["postprocessors"].append({"key": "FFmpegEmbedSubtitle"})

        try:
            os.makedirs(self._folder, exist_ok=True)
            self._push({"status": "processing", "text": "Connexion à YouTube…"}, force=True)
            with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                ydl.download([url])
            if not files:
                raise RuntimeError("Aucun fichier n'a été téléchargé.")
            last = files[-1]
            self._push({"status": "done", "file": last, "name": os.path.basename(last),
                        "count": len(files)}, force=True)
        except Cancelled:
            self._push({"status": "cancelled"}, force=True)
        except Exception as e:
            if self._cancel.is_set():
                self._push({"status": "cancelled"}, force=True)
            else:
                log_error(traceback.format_exc())
                self._push({"status": "error", "text": clean_error(e)}, force=True)
        finally:
            self._busy = False


# --------------------------------------------------------------------------- #
#  Lancement
# --------------------------------------------------------------------------- #
def selftest(window):
    """Utilisé par GitHub Actions : vérifie que l'interface et le pont JS fonctionnent."""
    ok = False
    for _ in range(120):
        try:
            if window.evaluate_js("window.__ready === true"):
                ok = True
                break
        except Exception:
            pass
        time.sleep(0.5)
    with open(os.path.join(os.getcwd(), "selftest_result.txt"), "w") as f:
        f.write("OK" if ok else "FAIL")
    window.destroy()


def main():
    api = Api()
    with open(resource("ui.html"), encoding="utf-8") as f:
        html = f.read()
    window = webview.create_window(
        APP_NAME, html=html, js_api=api,
        width=1040, height=700, resizable=False,
        frameless=True, easy_drag=False,
        background_color="#0c0a1c",
    )
    api._window = window
    window.events.shown += lambda: round_corners(APP_NAME)
    if "--selftest" in sys.argv:
        webview.start(selftest, window)
    else:
        webview.start()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        err = traceback.format_exc()
        log_error(err)
        if IS_WIN:
            ctypes.windll.user32.MessageBoxW(
                None, "Impossible de démarrer l'application.\n\n" + err[-800:]
                + "\n\nSi le problème persiste, installez « Microsoft Edge WebView2 Runtime ».",
                APP_NAME, 0x10)
        raise
