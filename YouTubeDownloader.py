#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
YouTube Downloader – télécharge une vidéo YouTube en pleine qualité.

Dépendances (installées automatiquement au premier lancement si besoin) :
    pip install -U yt-dlp imageio-ffmpeg

Lancement :
    python YouTubeDownloader.py
"""

import os
import sys
import shutil
import queue
import threading
import subprocess
import importlib
import tkinter as tk
from tkinter import ttk, filedialog, messagebox

APP_TITLE = "YouTube Downloader – Pleine qualité"
DEFAULT_DIR = os.path.join(os.path.expanduser("~"), "Downloads")

QUALITIES = {
    "Meilleure qualité (jusqu'à 8K)": None,
    "2160p (4K)": 2160,
    "1440p (2K)": 1440,
    "1080p (Full HD)": 1080,
    "720p (HD)": 720,
    "Audio seul (MP3)": "audio",
}

yt_dlp = None


# --------------------------------------------------------------------------- #
#  Dépendances
# --------------------------------------------------------------------------- #
def load_yt_dlp():
    global yt_dlp
    try:
        yt_dlp = importlib.import_module("yt_dlp")
        return True
    except ImportError:
        return False


def install_dependencies():
    """Installe / met à jour yt-dlp et imageio-ffmpeg via pip."""
    if getattr(sys, "frozen", False):
        return False, ("Version .exe : pour mettre à jour yt-dlp, téléchargez la "
                       "dernière version de l'exe depuis l'onglet Releases du projet "
                       "GitHub (elle est recompilée automatiquement chaque semaine).")
    cmd = [sys.executable, "-m", "pip", "install", "-U", "yt-dlp", "imageio-ffmpeg"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    importlib.invalidate_caches()
    if "yt_dlp" in sys.modules:
        importlib.reload(sys.modules["yt_dlp"])
    return result.returncode == 0, result.stdout + result.stderr


def find_ffmpeg():
    """Cherche ffmpeg dans le PATH, sinon utilise celui fourni par imageio-ffmpeg."""
    path = shutil.which("ffmpeg")
    if path:
        return path
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return None


# --------------------------------------------------------------------------- #
#  Utilitaires
# --------------------------------------------------------------------------- #
def human_size(n):
    if not n:
        return "?"
    for unit in ("o", "Ko", "Mo", "Go"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} To"


def human_eta(s):
    if s is None:
        return "?"
    s = int(s)
    m, s = divmod(s, 60)
    h, m = divmod(m, 60)
    return f"{h}h{m:02d}m{s:02d}s" if h else f"{m}m{s:02d}s"


class QueueLogger:
    def __init__(self, q):
        self.q = q

    def debug(self, msg):
        if not msg.startswith("[debug]"):
            self.q.put(("log", msg))

    def info(self, msg):
        self.q.put(("log", msg))

    def warning(self, msg):
        self.q.put(("log", "⚠ " + msg))

    def error(self, msg):
        self.q.put(("log", "✖ " + msg))


# --------------------------------------------------------------------------- #
#  Application
# --------------------------------------------------------------------------- #
class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(APP_TITLE)
        self.geometry("720x520")
        self.minsize(600, 450)

        self.q = queue.Queue()
        self.worker = None
        self.cancel_flag = threading.Event()

        self.url_var = tk.StringVar()
        self.dir_var = tk.StringVar(value=DEFAULT_DIR)
        self.quality_var = tk.StringVar(value=list(QUALITIES)[0])
        self.container_var = tk.StringVar(value="mkv")
        self.playlist_var = tk.BooleanVar(value=False)
        self.subs_var = tk.BooleanVar(value=False)
        self.status_var = tk.StringVar(value="Prêt.")

        self._build_ui()
        self.after(100, self._poll_queue)
        self.after(200, self._check_deps)

    # ---------------- UI ----------------
    def _build_ui(self):
        pad = {"padx": 10, "pady": 5}
        style = ttk.Style(self)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("Big.TButton", font=("Segoe UI", 11, "bold"), padding=8)

        frm = ttk.Frame(self)
        frm.pack(fill="both", expand=True, padx=10, pady=10)
        frm.columnconfigure(1, weight=1)

        # URL
        ttk.Label(frm, text="Lien YouTube :").grid(row=0, column=0, sticky="w", **pad)
        url_entry = ttk.Entry(frm, textvariable=self.url_var)
        url_entry.grid(row=0, column=1, sticky="ew", **pad)
        url_entry.focus()
        ttk.Button(frm, text="Coller", command=self._paste).grid(row=0, column=2, **pad)

        # Dossier
        ttk.Label(frm, text="Dossier :").grid(row=1, column=0, sticky="w", **pad)
        ttk.Entry(frm, textvariable=self.dir_var).grid(row=1, column=1, sticky="ew", **pad)
        ttk.Button(frm, text="Parcourir…", command=self._browse).grid(row=1, column=2, **pad)

        # Options
        opts = ttk.LabelFrame(frm, text="Options")
        opts.grid(row=2, column=0, columnspan=3, sticky="ew", **pad)

        ttk.Label(opts, text="Qualité :").grid(row=0, column=0, sticky="w", padx=8, pady=6)
        ttk.Combobox(opts, textvariable=self.quality_var, values=list(QUALITIES),
                     state="readonly", width=30).grid(row=0, column=1, sticky="w", padx=8)

        ttk.Label(opts, text="Format :").grid(row=0, column=2, sticky="w", padx=8)
        ttk.Combobox(opts, textvariable=self.container_var, values=["mkv", "mp4"],
                     state="readonly", width=6).grid(row=0, column=3, sticky="w", padx=8)

        ttk.Checkbutton(opts, text="Télécharger toute la playlist",
                        variable=self.playlist_var).grid(row=1, column=0, columnspan=2,
                                                         sticky="w", padx=8, pady=4)
        ttk.Checkbutton(opts, text="Inclure les sous-titres",
                        variable=self.subs_var).grid(row=1, column=2, columnspan=2,
                                                     sticky="w", padx=8)

        # Boutons
        btns = ttk.Frame(frm)
        btns.grid(row=3, column=0, columnspan=3, sticky="ew", **pad)
        self.dl_btn = ttk.Button(btns, text="⬇  Télécharger", style="Big.TButton",
                                 command=self._start)
        self.dl_btn.pack(side="left")
        self.cancel_btn = ttk.Button(btns, text="Annuler", command=self._cancel,
                                     state="disabled")
        self.cancel_btn.pack(side="left", padx=8)
        ttk.Button(btns, text="Mettre à jour yt-dlp",
                   command=self._update_deps).pack(side="right")
        ttk.Button(btns, text="Ouvrir le dossier",
                   command=self._open_folder).pack(side="right", padx=8)

        # Progression
        self.progress = ttk.Progressbar(frm, mode="determinate", maximum=100)
        self.progress.grid(row=4, column=0, columnspan=3, sticky="ew", **pad)
        ttk.Label(frm, textvariable=self.status_var).grid(row=5, column=0, columnspan=3,
                                                          sticky="w", **pad)

        # Journal
        frm.rowconfigure(6, weight=1)
        log_frame = ttk.Frame(frm)
        log_frame.grid(row=6, column=0, columnspan=3, sticky="nsew", **pad)
        self.log = tk.Text(log_frame, height=10, wrap="word", state="disabled",
                           font=("Consolas", 9))
        sb = ttk.Scrollbar(log_frame, command=self.log.yview)
        self.log.configure(yscrollcommand=sb.set)
        self.log.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")

        self.bind("<Return>", lambda e: self._start())

    # ---------------- Actions ----------------
    def _paste(self):
        try:
            self.url_var.set(self.clipboard_get().strip())
        except tk.TclError:
            pass

    def _browse(self):
        d = filedialog.askdirectory(initialdir=self.dir_var.get())
        if d:
            self.dir_var.set(d)

    def _open_folder(self):
        d = self.dir_var.get()
        if not os.path.isdir(d):
            return
        if sys.platform.startswith("win"):
            os.startfile(d)
        elif sys.platform == "darwin":
            subprocess.Popen(["open", d])
        else:
            subprocess.Popen(["xdg-open", d])

    def _log(self, msg):
        self.log.configure(state="normal")
        self.log.insert("end", msg + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def _set_busy(self, busy):
        self.dl_btn.configure(state="disabled" if busy else "normal")
        self.cancel_btn.configure(state="normal" if busy else "disabled")

    def _check_deps(self):
        if load_yt_dlp():
            self._log(f"yt-dlp {yt_dlp.version.__version__} chargé.")
        else:
            if messagebox.askyesno(
                "Dépendances manquantes",
                "yt-dlp n'est pas installé.\nL'installer maintenant (avec ffmpeg) ?"):
                self._update_deps()
            return
        ff = find_ffmpeg()
        if ff:
            self._log(f"ffmpeg trouvé : {ff}")
        else:
            self._log("⚠ ffmpeg introuvable : la pleine qualité nécessite ffmpeg. "
                      "Cliquez sur « Mettre à jour yt-dlp » pour l'installer.")

    def _update_deps(self):
        self._set_busy(True)
        self.dl_btn.configure(state="disabled")
        self.status_var.set("Installation / mise à jour des dépendances…")
        self.progress.configure(mode="indeterminate")
        self.progress.start(10)

        def run():
            ok, out = install_dependencies()
            self.q.put(("deps_done", ok, out))

        threading.Thread(target=run, daemon=True).start()

    def _cancel(self):
        self.cancel_flag.set()
        self.status_var.set("Annulation…")

    def _start(self):
        if self.worker and self.worker.is_alive():
            return
        url = self.url_var.get().strip()
        if not url:
            messagebox.showwarning(APP_TITLE, "Veuillez coller un lien YouTube.")
            return
        if yt_dlp is None and not load_yt_dlp():
            messagebox.showerror(APP_TITLE, "yt-dlp n'est pas installé.")
            return
        out_dir = self.dir_var.get()
        os.makedirs(out_dir, exist_ok=True)

        self.cancel_flag.clear()
        self.progress.configure(mode="determinate", value=0)
        self._set_busy(True)
        self.status_var.set("Analyse du lien…")
        self.worker = threading.Thread(
            target=self._download,
            args=(url, out_dir, QUALITIES[self.quality_var.get()],
                  self.container_var.get(), self.playlist_var.get(), self.subs_var.get()),
            daemon=True)
        self.worker.start()

    # ---------------- Téléchargement (thread) ----------------
    def _download(self, url, out_dir, quality, container, playlist, subs):
        q = self.q

        def progress_hook(d):
            if self.cancel_flag.is_set():
                raise yt_dlp.utils.DownloadError("Téléchargement annulé par l'utilisateur.")
            if d["status"] == "downloading":
                total = d.get("total_bytes") or d.get("total_bytes_estimate")
                done = d.get("downloaded_bytes", 0)
                pct = done / total * 100 if total else 0
                speed = d.get("speed")
                txt = (f"{pct:5.1f} %  –  {human_size(done)} / {human_size(total)}"
                       f"  –  {human_size(speed)}/s  –  reste {human_eta(d.get('eta'))}")
                info = d.get("info_dict", {})
                if info.get("playlist_index"):
                    txt = f"[{info['playlist_index']}/{info.get('n_entries', '?')}] " + txt
                q.put(("progress", pct, txt))
            elif d["status"] == "finished":
                q.put(("progress", 100, "Flux téléchargé, traitement…"))

        def pp_hook(d):
            if d["status"] == "started":
                names = {"Merger": "Fusion audio + vidéo",
                         "FFmpegExtractAudio": "Conversion en MP3",
                         "FFmpegVideoRemuxer": "Conversion du conteneur"}
                q.put(("status", names.get(d.get("postprocessor"),
                                           d.get("postprocessor", "Traitement")) + "…"))

        ffmpeg = find_ffmpeg()
        opts = {
            "outtmpl": os.path.join(out_dir, "%(title)s [%(id)s].%(ext)s"),
            "noplaylist": not playlist,
            "progress_hooks": [progress_hook],
            "postprocessor_hooks": [pp_hook],
            "logger": QueueLogger(q),
            "noprogress": True,
            "windowsfilenames": True,
            "retries": 10,
            "fragment_retries": 10,
            "concurrent_fragment_downloads": 4,
        }
        if ffmpeg:
            opts["ffmpeg_location"] = ffmpeg

        if quality == "audio":
            opts["format"] = "bestaudio/best"
            opts["postprocessors"] = [{
                "key": "FFmpegExtractAudio",
                "preferredcodec": "mp3",
                "preferredquality": "0",
            }]
        else:
            h = f"[height<={quality}]" if quality else ""
            if ffmpeg:
                # Meilleure vidéo + meilleur audio séparés, puis fusion sans perte
                opts["format"] = f"bestvideo*{h}+bestaudio/best{h}"
                opts["merge_output_format"] = container
            else:
                # Sans ffmpeg : seulement les flux déjà combinés (souvent 720p max)
                opts["format"] = f"best{h}"
                q.put(("log", "⚠ Sans ffmpeg, la qualité est limitée aux flux combinés."))

        if subs:
            opts.update({
                "writesubtitles": True,
                "subtitleslangs": ["fr.*", "en.*"],
                "embedsubtitles": bool(ffmpeg),
            })
            if ffmpeg:
                opts.setdefault("postprocessors", []).append({"key": "FFmpegEmbedSubtitle"})

        try:
            with yt_dlp.YoutubeDL(opts) as ydl:
                info = ydl.extract_info(url, download=False)
                title = info.get("title", "vidéo")
                if info.get("_type") == "playlist":
                    q.put(("log", f"Playlist : {title} ({len(info.get('entries') or [])} vidéos)"))
                else:
                    res = f"{info.get('width', '?')}x{info.get('height', '?')}"
                    q.put(("log", f"Vidéo : {title}  –  meilleure résolution dispo : {res}"))
                q.put(("status", "Téléchargement…"))
                ydl.process_ie_result(info, download=True)
            q.put(("done", True, f"Terminé : {title}"))
        except Exception as e:
            q.put(("done", False, str(e)))

    # ---------------- Boucle de messages ----------------
    def _poll_queue(self):
        try:
            while True:
                msg = self.q.get_nowait()
                kind = msg[0]
                if kind == "progress":
                    self.progress.configure(value=msg[1])
                    self.status_var.set(msg[2])
                elif kind == "status":
                    self.status_var.set(msg[1])
                elif kind == "log":
                    self._log(msg[1])
                elif kind == "done":
                    self._set_busy(False)
                    if msg[1]:
                        self.progress.configure(value=100)
                        self.status_var.set("✔ " + msg[2])
                        self._log("✔ " + msg[2])
                    else:
                        self.status_var.set("✖ Erreur")
                        self._log("✖ " + msg[2])
                        messagebox.showerror(APP_TITLE, msg[2])
                elif kind == "deps_done":
                    self.progress.stop()
                    self.progress.configure(mode="determinate", value=0)
                    self._set_busy(False)
                    if msg[1] and load_yt_dlp():
                        self.status_var.set("Dépendances à jour.")
                        self._log(f"yt-dlp {yt_dlp.version.__version__} prêt.")
                        ff = find_ffmpeg()
                        self._log(f"ffmpeg : {ff}" if ff else "⚠ ffmpeg toujours introuvable.")
                    else:
                        self.status_var.set("Échec de l'installation.")
                        self._log(msg[2][-1500:])
                        messagebox.showerror(APP_TITLE,
                                             "Installation échouée. Voir le journal.")
        except queue.Empty:
            pass
        self.after(100, self._poll_queue)


if __name__ == "__main__":
    App().mainloop()
