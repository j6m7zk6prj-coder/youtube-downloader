# -*- coding: utf-8 -*-
"""
Serveur local pour l'app iPhone.

L'iPhone (sur le même Wi-Fi) envoie un lien. Le PC le télécharge en pleine
qualité avec yt-dlp + ffmpeg, le rend lisible par l'iPhone (MP4 H.264 / HEVC / AV1
+ AAC), puis l'iPhone récupère le fichier et l'enregistre dans Photos.

Points d'accès (JSON) :
    GET  /info                    nom du PC, version, appairé ou non
    POST /pair      {code}        -> {token}
    POST /analyze   {url}         -> titre, miniature, durée, qualités disponibles
    POST /jobs      {url, mode, quality, audio, codecs} -> {id}
    GET  /jobs/<id>               état, %, vitesse, temps restant
    GET  /jobs/<id>/file          le fichier final
    POST /jobs/<id>/cancel
    DELETE /jobs/<id>             supprime le fichier du PC
Toutes les requêtes sauf /info et /pair demandent l'en-tête X-Token.
"""

import os
import re
import json
import time
import uuid
import socket
import shutil
import secrets
import tempfile
import threading
import subprocess
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

import yt_dlp

PORT = 8765
SERVICE = "_ytdl._tcp.local."
VERSION = 1
NO_WINDOW = 0x08000000 if os.name == "nt" else 0


class Cancelled(Exception):
    pass


def _clean_error(e):
    msg = re.sub(r"\x1b\[[0-9;]*m", "", str(e)).strip()
    msg = re.sub(r"^ERROR:\s*", "", msg)
    msg = re.sub(r"^\[[^\]]+\]\s*[\w-]+:\s*", "", msg)
    low = msg.lower()
    if "private" in low:
        return "Cette vidéo est privée."
    if "login" in low or "log in" in low or "cookies" in low or "sign in" in low:
        return "Ce site demande d'être connecté pour cette vidéo."
    if "unsupported url" in low:
        return "Ce lien n'est pas pris en charge."
    if "unavailable" in low or "not available" in low:
        return "Cette vidéo n'est pas disponible."
    if "getaddrinfo" in low or "failed to resolve" in low:
        return "Le PC n'a pas accès à Internet."
    return msg[:280] or "Erreur inconnue."


PLATFORMS = {
    "youtube": "YouTube", "tiktok": "TikTok", "instagram": "Instagram", "twitter": "X",
    "facebook": "Facebook", "reddit": "Reddit", "vimeo": "Vimeo", "dailymotion": "Dailymotion",
    "twitch": "Twitch", "soundcloud": "SoundCloud", "pinterest": "Pinterest", "snapchat": "Snapchat",
    "threads": "Threads", "bilibili": "Bilibili",
}


def _platform(info):
    key = (info.get("extractor_key") or info.get("extractor") or "").lower()
    for k, v in PLATFORMS.items():
        if k in key:
            return v
    return info.get("extractor_key") or "Web"


def _codec_family(vcodec):
    v = (vcodec or "").lower()
    if v.startswith(("avc", "h264")):
        return "h264"
    if v.startswith(("hev", "hvc", "h265", "hevc", "bytevc1")):
        return "hevc"
    if v.startswith(("av01", "av1")):
        return "av1"
    if v.startswith("vp9") or v.startswith("vp09"):
        return "vp9"
    return v.split(".")[0] or "?"


def _has_video(f):
    return f.get("vcodec") not in (None, "none") or (f.get("height") and f.get("acodec") != "none" and f.get("vcodec") is None)


def _height(f):
    w, h = f.get("width"), f.get("height")
    if w and h:
        return min(w, h)  # vidéos verticales (TikTok) : 1080 x 1920 -> 1080p
    return h or 0


class Job:
    def __init__(self, url, opts):
        self.id = uuid.uuid4().hex[:12]
        self.url = url
        self.opts = opts
        self.status = "queued"  # queued, downloading, converting, ready, error, cancelled
        self.stage = "En attente…"
        self.pct = None
        self.speed = None
        self.eta = None
        self.title = None
        self.thumbnail = None
        self.file = None
        self.filename = None
        self.size = 0
        self.mime = "video/mp4"
        self.error = None
        self.cancel = threading.Event()
        self.proc = None
        self.created = time.time()
        self.workdir = None

    def public(self):
        return {
            "id": self.id, "status": self.status, "stage": self.stage,
            "pct": self.pct, "speed": self.speed, "eta": self.eta,
            "title": self.title, "thumbnail": self.thumbnail,
            "filename": self.filename, "size": self.size, "mime": self.mime,
            "error": self.error,
        }


class PhoneServer:
    def __init__(self, get_settings, save_settings, ffmpeg, on_event=None):
        self.get_settings = get_settings
        self.save_settings = save_settings
        self.ffmpeg = ffmpeg
        self.on_event = on_event or (lambda *a: None)
        self.jobs = {}
        self.lock = threading.Lock()
        self.httpd = None
        self.port = None
        self.zeroconf = None
        self.last_seen = 0
        self.root = os.path.join(tempfile.gettempdir(), "YouTubeDownloader-iPhone")
        shutil.rmtree(self.root, ignore_errors=True)
        os.makedirs(self.root, exist_ok=True)
        self._encoder = None

    # ----- appairage -----
    @property
    def code(self):
        s = self.get_settings()
        if not s.get("phone_code"):
            s["phone_code"] = f"{secrets.randbelow(900000) + 100000}"
            self.save_settings(s)
        return s["phone_code"]

    def new_code(self):
        s = self.get_settings()
        s["phone_code"] = f"{secrets.randbelow(900000) + 100000}"
        s["phone_tokens"] = []
        self.save_settings(s)
        return s["phone_code"]

    def pair(self, code):
        if str(code).strip().replace(" ", "") != self.code:
            return None
        token = secrets.token_hex(16)
        s = self.get_settings()
        s.setdefault("phone_tokens", []).append(token)
        s["phone_tokens"] = s["phone_tokens"][-10:]
        self.save_settings(s)
        self.on_event("paired")
        return token

    def authorized(self, token):
        ok = bool(token) and token in self.get_settings().get("phone_tokens", [])
        if ok:
            self.last_seen = time.time()
        return ok

    @property
    def addresses(self):
        ips = set()
        try:
            for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
                ip = info[4][0]
                if not ip.startswith("127."):
                    ips.add(ip)
        except Exception:
            pass
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("192.168.0.1", 9))
            ips.add(s.getsockname()[0])
            s.close()
        except Exception:
            pass
        return sorted(ips, key=lambda ip: (not ip.startswith(("192.168.", "10.", "172.")), ip))

    # ----- démarrage -----
    def start(self):
        server = self
        for port in range(PORT, PORT + 10):
            try:
                self.httpd = ThreadingHTTPServer(("0.0.0.0", port), _make_handler(server))
                self.port = port
                break
            except OSError:
                continue
        if not self.httpd:
            raise RuntimeError("Aucun port libre pour le serveur iPhone.")
        self.httpd.daemon_threads = True
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        threading.Thread(target=self._advertise, daemon=True).start()
        threading.Thread(target=self._janitor, daemon=True).start()

    def stop(self):
        try:
            if self.zeroconf:
                self.zeroconf.unregister_all_services()
                self.zeroconf.close()
        except Exception:
            pass
        try:
            if self.httpd:
                self.httpd.shutdown()
        except Exception:
            pass
        for j in list(self.jobs.values()):
            j.cancel.set()
        shutil.rmtree(self.root, ignore_errors=True)

    def _advertise(self):
        """Annonce le PC sur le Wi-Fi (Bonjour) pour que l'iPhone le trouve tout seul."""
        try:
            from zeroconf import Zeroconf, ServiceInfo
            name = re.sub(r"[^\w -]", "", socket.gethostname()) or "PC"
            ips = [socket.inet_aton(ip) for ip in self.addresses]
            info = ServiceInfo(
                SERVICE, f"{name}.{SERVICE}", addresses=ips, port=self.port,
                properties={"v": str(VERSION), "name": name},
                server=f"{name.replace(' ', '-')}.local.",
            )
            self.zeroconf = Zeroconf()
            self.zeroconf.register_service(info, allow_name_change=True)
        except Exception:
            traceback.print_exc()

    def _janitor(self):
        """Supprime les fichiers vieux de plus de 3 heures."""
        while True:
            time.sleep(600)
            now = time.time()
            for j in list(self.jobs.values()):
                if now - j.created > 3 * 3600 and j.status not in ("downloading", "converting"):
                    self.delete(j.id)

    # ----- analyse -----
    def analyze(self, url):
        opts = {"quiet": True, "no_warnings": True, "noplaylist": True, "skip_download": True}
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)
        if info.get("_type") == "playlist":
            entries = [e for e in (info.get("entries") or []) if e]
            if not entries:
                raise RuntimeError("Aucune vidéo trouvée à ce lien.")
            info = entries[0]
        formats = info.get("formats") or [info]
        heights = sorted({_height(f) for f in formats if _has_video(f) and _height(f)}, reverse=True)
        thumb = info.get("thumbnail")
        if not thumb and info.get("thumbnails"):
            thumb = info["thumbnails"][-1].get("url")
        return {
            "title": info.get("title") or info.get("description") or "Vidéo",
            "uploader": info.get("uploader") or info.get("channel") or info.get("creator"),
            "duration": info.get("duration"),
            "thumbnail": thumb,
            "platform": _platform(info),
            "heights": heights[:12],
            "hasVideo": bool(heights) or _has_video(info),
        }

    # ----- téléchargement -----
    def create_job(self, url, opts):
        job = Job(url, opts)
        job.workdir = os.path.join(self.root, job.id)
        os.makedirs(job.workdir, exist_ok=True)
        with self.lock:
            self.jobs[job.id] = job
        threading.Thread(target=self._run, args=(job,), daemon=True).start()
        self.on_event("job", job.public())
        return job

    def cancel(self, job_id):
        j = self.jobs.get(job_id)
        if j:
            j.cancel.set()
            if j.proc and j.proc.poll() is None:
                try:
                    j.proc.kill()
                except Exception:
                    pass

    def delete(self, job_id):
        j = self.jobs.pop(job_id, None)
        if j:
            j.cancel.set()
            shutil.rmtree(j.workdir or "", ignore_errors=True)

    def _choose(self, info, max_h, codecs):
        """Choisit le meilleur flux vidéo. Renvoie (format_id, convertir_ou_non)."""
        formats = [f for f in (info.get("formats") or []) if _has_video(f) and f.get("format_id")]
        if not formats:
            return None, False
        limit = max_h or 10 ** 6
        within = [f for f in formats if (_height(f) or 0) <= limit] or formats

        def score(f):
            return (_height(f) or 0, f.get("fps") or 0, f.get("tbr") or f.get("vbr") or 0)

        best_any = max(within, key=score)
        ok = [f for f in within if _codec_family(f.get("vcodec")) in codecs]
        if ok:
            best_ok = max(ok, key=score)
            if (_height(best_ok) or 0) >= (_height(best_any) or 0):
                return best_ok, False
        return best_any, True

    def _run(self, job):
        o = job.opts
        mode = o.get("mode", "video")
        codecs = set(o.get("codecs") or ["h264", "hevc"])
        max_h = int(o.get("quality") or 0)
        files = []

        def hook(d):
            if job.cancel.is_set():
                raise Cancelled()
            if d["status"] == "downloading":
                total = d.get("total_bytes") or d.get("total_bytes_estimate")
                done = d.get("downloaded_bytes") or 0
                info = d.get("info_dict") or {}
                kind = "audio" if info.get("vcodec") in (None, "none") and mode == "video" else ""
                job.status = "downloading"
                job.stage = "Téléchargement du son sur le PC" if kind == "audio" else "Téléchargement sur le PC"
                job.pct = (done / total * 100) if total else None
                job.speed = d.get("speed")
                job.eta = d.get("eta")

        base = {
            "quiet": True, "no_warnings": True, "noprogress": True, "noplaylist": True,
            "outtmpl": os.path.join(job.workdir, "src.%(ext)s"),
            "progress_hooks": [hook], "retries": 10, "fragment_retries": 10,
            "concurrent_fragment_downloads": 4, "windowsfilenames": True,
            "post_hooks": [lambda p: files.append(p)],
        }
        if self.ffmpeg:
            base["ffmpeg_location"] = self.ffmpeg

        try:
            job.status, job.stage = "downloading", "Analyse du lien…"
            with yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True, "noplaylist": True}) as ydl:
                info = ydl.extract_info(job.url, download=False)
            if info.get("_type") == "playlist":
                entries = [e for e in (info.get("entries") or []) if e]
                if not entries:
                    raise RuntimeError("Aucune vidéo trouvée à ce lien.")
                info = entries[0]
            job.title = info.get("title") or "Vidéo"
            job.thumbnail = info.get("thumbnail")
            safe = re.sub(r'[\\/:*?"<>|\n\r\t]+', " ", job.title).strip()[:90] or "video"

            if mode == "audio":
                fmt = o.get("audio") or "m4a"
                opts = dict(base, format="bestaudio[ext=m4a]/bestaudio/best" if fmt == "m4a" else "bestaudio/best")
                opts["postprocessors"] = [{"key": "FFmpegExtractAudio", "preferredcodec": fmt,
                                           "preferredquality": "320" if fmt == "mp3" else "0"},
                                          {"key": "FFmpegMetadata"}]
                with yt_dlp.YoutubeDL(opts) as ydl:
                    ydl.process_ie_result(info, download=True)
                src = self._newest(job.workdir)
                final = os.path.join(job.workdir, f"{safe}.{fmt}")
                os.replace(src, final)
                job.mime = "audio/mpeg" if fmt == "mp3" else "audio/mp4"
            else:
                chosen, convert = self._choose(info, max_h, codecs)
                if chosen is None:
                    fmt_sel = "best"
                else:
                    vid = chosen["format_id"]
                    fmt_sel = vid if chosen.get("acodec") not in (None, "none") else \
                        f"{vid}+bestaudio[acodec^=mp4a]/{vid}+bestaudio/{vid}"
                opts = dict(base, format=fmt_sel, merge_output_format="mkv")
                with yt_dlp.YoutubeDL(opts) as ydl:
                    ydl.process_ie_result(info, download=True)
                src = self._newest(job.workdir)
                final = os.path.join(job.workdir, f"{safe}.mp4")
                vfam = _codec_family((chosen or {}).get("vcodec"))
                self._to_iphone(job, src, final, convert or vfam not in codecs, vfam,
                                (chosen or {}).get("height"), info.get("duration"))
                job.mime = "video/mp4"

            job.file = final
            job.filename = os.path.basename(final)
            job.size = os.path.getsize(final)
            job.status, job.stage, job.pct = "ready", "Prêt", 100
        except Cancelled:
            job.status, job.stage = "cancelled", "Annulé"
        except Exception as e:
            if job.cancel.is_set():
                job.status, job.stage = "cancelled", "Annulé"
            else:
                traceback.print_exc()
                job.status, job.stage, job.error = "error", "Erreur", _clean_error(e)
        self.on_event("job", job.public())

    @staticmethod
    def _newest(folder):
        items = [os.path.join(folder, f) for f in os.listdir(folder) if not f.endswith((".part", ".ytdl"))]
        if not items:
            raise RuntimeError("Le téléchargement n'a produit aucun fichier.")
        return max(items, key=os.path.getmtime)

    # ----- conversion pour l'iPhone -----
    def _probe_audio(self, src):
        try:
            r = subprocess.run([self.ffmpeg, "-hide_banner", "-i", src], capture_output=True, text=True,
                               encoding="utf-8", errors="ignore", creationflags=NO_WINDOW)
            m = re.search(r"Audio:\s*([a-z0-9_]+)", r.stderr)
            return m.group(1) if m else None
        except Exception:
            return None

    def _encoders(self, height):
        """Encodeurs HEVC à essayer, du plus rapide (carte graphique) au plus sûr (processeur)."""
        if self._encoder:
            return [self._encoder]
        try:
            out = subprocess.run([self.ffmpeg, "-hide_banner", "-encoders"], capture_output=True, text=True,
                                 encoding="utf-8", errors="ignore", creationflags=NO_WINDOW).stdout
        except Exception:
            out = ""
        hw = [e for e in ("hevc_nvenc", "hevc_qsv", "hevc_amf", "hevc_mf") if e in out]
        sw = ["libx265"] if "libx265" in out else []
        return hw + sw + ["libx264"]

    def _encoder_args(self, enc, height):
        big = (height or 0) > 1440
        if enc == "libx265":
            return ["-c:v", "libx265", "-preset", "fast", "-crf", "20" if big else "21", "-tag:v", "hvc1"]
        if enc == "libx264":
            return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "19"]
        if enc == "hevc_mf":
            return ["-c:v", "hevc_mf", "-b:v", "45M" if big else "16M", "-tag:v", "hvc1"]
        return ["-c:v", enc, "-b:v", "45M" if big else "16M", "-tag:v", "hvc1"]

    def _to_iphone(self, job, src, dst, convert, vfam, height, duration):
        audio = self._probe_audio(src)
        a_args = ["-c:a", "copy"] if audio in ("aac", "alac", "mp3") else ["-c:a", "aac", "-b:a", "256k"]
        if audio is None:
            a_args = ["-c:a", "aac", "-b:a", "256k"]
        common = ["-map", "0:v:0", "-map", "0:a:0?", "-movflags", "+faststart", "-map_metadata", "0"]

        if not convert:
            tag = ["-tag:v", "hvc1"] if vfam == "hevc" else []
            job.status, job.stage, job.pct = "converting", "Préparation pour l'iPhone", None
            self._ffmpeg(job, ["-i", src] + common + ["-c:v", "copy"] + tag + a_args + [dst], duration)
            return

        last = None
        for enc in self._encoders(height):
            job.status = "converting"
            job.stage = "Conversion pour l'iPhone (peut être long)"
            job.pct = 0
            try:
                self._ffmpeg(job, ["-i", src] + common + self._encoder_args(enc, height)
                             + ["-pix_fmt", "yuv420p"] + a_args + [dst], duration)
                self._encoder = enc
                return
            except Cancelled:
                raise
            except Exception as e:
                last = e
                try:
                    os.remove(dst)
                except OSError:
                    pass
        raise last or RuntimeError("Conversion impossible.")

    def _ffmpeg(self, job, args, duration):
        cmd = [self.ffmpeg, "-hide_banner", "-y", "-nostats", "-progress", "pipe:1"] + args
        job.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                    encoding="utf-8", errors="ignore", creationflags=NO_WINDOW)
        err_lines = []
        threading.Thread(target=lambda: err_lines.extend(job.proc.stderr.readlines()), daemon=True).start()
        for line in job.proc.stdout:
            if job.cancel.is_set():
                job.proc.kill()
                raise Cancelled()
            if line.startswith("out_time_ms=") and duration:
                try:
                    t = int(line.split("=")[1]) / 1_000_000
                    job.pct = max(0.0, min(99.0, t / duration * 100))
                except ValueError:
                    pass
            elif line.startswith("speed=") and duration and job.pct:
                try:
                    sp = float(line.split("=")[1].strip().rstrip("x"))
                    if sp > 0:
                        job.eta = (duration * (1 - job.pct / 100)) / sp
                except ValueError:
                    pass
        job.proc.wait()
        if job.cancel.is_set():
            raise Cancelled()
        if job.proc.returncode != 0:
            raise RuntimeError("ffmpeg : " + "".join(err_lines[-3:]).strip()[:200])


def _make_handler(server):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def _send(self, code, data):
            body = json.dumps(data, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _body(self):
            n = int(self.headers.get("Content-Length") or 0)
            if not n:
                return {}
            try:
                return json.loads(self.rfile.read(n).decode("utf-8"))
            except Exception:
                return {}

        def _auth(self):
            if server.authorized(self.headers.get("X-Token")):
                return True
            self._send(401, {"error": "Appareil non appairé. Entre le code affiché sur le PC."})
            return False

        def _route(self):
            return [p for p in urlparse(self.path).path.split("/") if p]

        def do_GET(self):
            r = self._route()
            if r == ["info"]:
                token = self.headers.get("X-Token")
                return self._send(200, {"name": socket.gethostname(), "version": VERSION,
                                        "paired": server.authorized(token), "app": "YouTubeDownloader"})
            if not self._auth():
                return
            if len(r) == 2 and r[0] == "jobs":
                j = server.jobs.get(r[1])
                return self._send(200, j.public()) if j else self._send(404, {"error": "Introuvable."})
            if len(r) == 3 and r[0] == "jobs" and r[2] == "file":
                return self._file(server.jobs.get(r[1]))
            self._send(404, {"error": "Introuvable."})

        def do_POST(self):
            r = self._route()
            data = self._body()
            if r == ["pair"]:
                token = server.pair(data.get("code", ""))
                if token:
                    return self._send(200, {"token": token, "name": socket.gethostname()})
                return self._send(403, {"error": "Code incorrect."})
            if not self._auth():
                return
            if r == ["analyze"]:
                try:
                    return self._send(200, server.analyze(data.get("url", "")))
                except Exception as e:
                    return self._send(422, {"error": _clean_error(e)})
            if r == ["jobs"]:
                url = (data.get("url") or "").strip()
                if not url:
                    return self._send(400, {"error": "Lien manquant."})
                return self._send(200, server.create_job(url, data).public())
            if len(r) == 3 and r[0] == "jobs" and r[2] == "cancel":
                server.cancel(r[1])
                return self._send(200, {"ok": True})
            self._send(404, {"error": "Introuvable."})

        def do_DELETE(self):
            r = self._route()
            if not self._auth():
                return
            if len(r) == 2 and r[0] == "jobs":
                server.delete(r[1])
                return self._send(200, {"ok": True})
            self._send(404, {"error": "Introuvable."})

        def _file(self, job):
            if not job or job.status != "ready" or not job.file or not os.path.exists(job.file):
                return self._send(404, {"error": "Fichier pas encore prêt."})
            size = os.path.getsize(job.file)
            start, end = 0, size - 1
            rng = self.headers.get("Range")
            m = re.match(r"bytes=(\d+)-(\d*)", rng or "")
            if m:
                start = int(m.group(1))
                end = int(m.group(2)) if m.group(2) else size - 1
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            else:
                self.send_response(200)
            self.send_header("Content-Type", job.mime)
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Accept-Ranges", "bytes")
            from urllib.parse import quote
            self.send_header("Content-Disposition", f"attachment; filename*=UTF-8''{quote(job.filename)}")
            self.end_headers()
            with open(job.file, "rb") as f:
                f.seek(start)
                left = end - start + 1
                try:
                    while left > 0:
                        chunk = f.read(min(1024 * 1024, left))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        left -= len(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            server.on_event("sent", job.public())

    return Handler
