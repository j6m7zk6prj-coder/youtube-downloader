# YouTube Downloader

Application Windows pour télécharger une vidéo YouTube en pleine qualité (jusqu'en 8K), en MKV/MP4 ou en MP3.

## Télécharger

Onglet **Releases** → `YouTubeDownloader.exe` → double-clic. Rien à installer.

Si Windows affiche « Windows a protégé votre ordinateur » : **Informations complémentaires** → **Exécuter quand même**.

L'exe est recompilé automatiquement chaque lundi avec la dernière version de yt-dlp. Si un téléchargement échoue, reprenez simplement la dernière version.

## Fonctionnement

- Interface : Python / Tkinter
- Moteur : [yt-dlp](https://github.com/yt-dlp/yt-dlp) + ffmpeg (intégrés dans l'exe)
- Compilation : GitHub Actions (`.github/workflows/build.yml`)

À utiliser pour vos propres vidéos ou des contenus libres de droits.
