# Nebula ✦ convertitore di file per macOS

App nativa per la barra dei menu (Swift, AppKit + SwiftUI, macOS 14+). Selezioni un file e attorno al puntatore si apre una **ghiera a tema galassia**: un buco nero al centro con l'icona del file, una galassia a spirale che ruota, una nebulosa che respira e dei pianeti in orbita, uno per ogni formato di destinazione. Passi sopra un pianeta e si gonfia come una gelatina, gli clicchi sopra e si schiaccia. A quel punto tutti i pianeti vengono risucchiati nel nucleo, la galassia accelera mentre la conversione procede e alla fine c'è un'esplosione di supernova.

## Installazione

Serve Xcode oppure i Command Line Tools (`xcode-select --install`).

```bash
cd Nebula
chmod +x build.sh
./build.sh --install     # compila, copia in /Applicazioni e avvia
```

Al primo uso macOS ti chiede il permesso di **controllare il Finder**: serve a leggere la selezione. Se lo neghi per errore, lo trovi in Impostazioni di Sistema → Privacy e sicurezza → Automazione.

Facoltativo: `brew install ffmpeg` sblocca WebM, MKV, MP3, FLAC, OGG e WebP, e permette di leggere formati che macOS da solo non apre (mkv, webm, avi, ogg…).

## Come si apre la ghiera

| Modo | Cosa fai |
|---|---|
| **Automatico** | Nel menu ✦ attiva "Mostra la ghiera quando selezioni un file": la ghiera compare appena selezioni qualcosa nel Finder |
| **Scorciatoia** | Selezioni il file nel Finder e premi **⌥ Spazio** |
| **Tasto destro** | Nel Finder: Servizi / Azioni rapide → **Converti con Nebula** |
| **Trascina** | Trascini i file sull'icona dell'app |

Dentro la ghiera: **1–9** scelgono il pianeta, **Invio** conferma, **Esc** chiude, e un clic sul nucleo a fine conversione mostra il file nel Finder.

## Formati

Il formato di partenza viene riconosciuto in automatico (UTType + estensione) e la ghiera propone solo le conversioni che hanno senso. Con più file selezionati compaiono solo i formati comuni a tutti. **ZIP** c'è sempre.

| Origine | Destinazioni |
|---|---|
| Immagini (HEIC, JPEG, PNG, RAW, SVG…) | PNG · JPEG · HEIC · WebP · TIFF · GIF · BMP · PDF |
| Video | MP4 · MOV · HEVC · GIF animata · M4A (solo audio) · fotogramma PNG · *WebM · MKV · MP3* |
| Audio | M4A · WAV · AIFF · CAF · *MP3 · FLAC · OGG* |
| PDF | PNG/JPEG (una per pagina) · TXT · DOCX · RTF · HTML |
| Documenti (DOCX, DOC, RTF, ODT, HTML) | PDF · DOCX · RTF · HTML · ODT · DOC · TXT |
| Markdown | HTML · PDF · DOCX · RTF · TXT |
| Testo / codice | PDF · DOCX · RTF · HTML |
| JSON · PLIST · CSV | JSON ⇄ PLIST · JSON ⇄ CSV · CSV → tabella HTML (riconosce il separatore `;` di Excel) |
| Archivi (zip, tar, gz, 7z…) | Estrai |

*In corsivo*: richiede FFmpeg. I file convertiti vanno accanto all'originale (o in Download se la cartella non è scrivibile) e non sovrascrivono mai niente.

## Struttura del codice

```
Sources/Nebula/
  NebulaApp.swift        avvio come app della barra dei menu
  AppDelegate.swift      menu ✦, scorciatoia, Servizi, avvio al login
  HotKey.swift           scorciatoia globale ⌥Spazio (Carbon)
  FinderBridge.swift     selezione del Finder + modalità automatica
  Catalog.swift          riconoscimento dei file e conversioni proposte
  Engine.swift           smistamento, percorsi di uscita, zip/estrazione
  ImageConverter.swift   ImageIO + PDFKit
  MediaConverter.swift   AVFoundation + FFmpeg facoltativo
  DocumentConverter.swift NSAttributedString, PDF impaginato A4, Markdown
  DataConverter.swift    JSON / PLIST / CSV
  RingController.swift   finestra trasparente e stato della ghiera
  GalaxyRingView.swift   la ghiera: galassia, nebulosa, pianeti, buco nero, supernova
```

Per aggiungere un formato: aggiungi una voce in `ConversionCatalog.options(for:)` e gestisci il suo `tag` nel convertitore giusto. Per cambiare la scorciatoia: modifica `kVK_Space` / `optionKey` in `AppDelegate`.
