# Nebula ✦ convertitore di file per macOS

App nativa per la barra dei menu (Swift, AppKit + SwiftUI, macOS 14+). **Tieni premuto ⌥ Option** e sotto il puntatore compare la **nebula**: un piccolo blob di vetro, appena trasparente, con dentro una galassia e intorno i formati disponibili. Punti un formato e il blob si deforma, molle, verso di lui. Rilasci e parte la conversione.

## Installazione

Scarica `Nebula.dmg` dalla pagina Releases, aprilo e trascina Nebula in Applicazioni. Al primo avvio:
1. Impostazioni di Sistema → Privacy e sicurezza → **Apri comunque**: l'app non è firmata con un account sviluppatore Apple.
2. Concedi **Accessibilità** a Nebula e poi riavviala. Serve per accorgersi di quando tieni premuto ⌥ e per incollare. Va riattivata a ogni aggiornamento.
3. Alla prima conversione concedi il permesso di controllare il Finder.

## Uso

- **Nel Finder con file selezionati:** tieni premuto ⌥ e la nebula compare subito.
- **Altrove, o nel Finder senza selezione:** intorno al puntatore parte un caricatore di 1,5 s, poi la nebula lavora su ciò che hai **copiato** (immagini, testo, file). Il risultato va in Download e torna negli appunti.
- **Scegliere:** punta un formato e **rilascia ⌥**. Se rilasci al centro, la nebula sparisce e non succede niente.
- **Strattone:** un movimento veloce verso un formato vale come "voglio questo". La nebula scatta in quella direzione e si dissolve sull'opzione, che parte senza aspettare il rilascio.
- **Clic al centro = Mini:** riduce i file (immagini ridimensionate e ricompresse, video in HEVC 1080p, audio in AAC, PDF con immagini ottimizzate, il resto in ZIP).
- **⌥⌘V tenuto premuto:** compaiono le ultime 3 cose copiate. Punta e rilascia per incollarla.
- Se usi ⌥ insieme ad altri tasti o al mouse, funziona come ⌥ normale.
- Tasto, scorciatoie e comportamento si cambiano in **✦ → Impostazioni…**.

## AI.md

Per PDF, Word, PowerPoint, Excel ed EPUB c'è l'opzione **AI.md**: trasforma il documento in Markdown pulito, pronto da dare a qualsiasi modello AI. Usa [MarkItDown](https://github.com/microsoft/markitdown) di Microsoft, già incluso nell'app sui Mac Apple Silicon. Altrove usa un convertitore nativo di riserva per PDF e documenti di testo.

## Formati

Il formato di partenza viene riconosciuto in automatico (UTType + estensione) e la nebula propone solo le conversioni che hanno senso. Con più file selezionati compaiono solo i formati comuni a tutti. **ZIP** c'è sempre.

| Origine | Destinazioni |
|---|---|
| Immagini (HEIC, JPEG, PNG, RAW, SVG…) | PNG · JPEG · HEIC · WebP · TIFF · GIF · BMP · PDF |
| Video | MP4 · MOV · HEVC · GIF animata · M4A (solo audio) · fotogramma PNG · *WebM · MKV · MP3* |
| Audio | M4A · WAV · AIFF · CAF · *MP3 · FLAC · OGG* |
| PDF | AI.md · PNG/JPEG (una per pagina) · TXT · DOCX · RTF · HTML |
| Documenti (DOCX, DOC, RTF, ODT, HTML) | AI.md · PDF · DOCX · RTF · HTML · ODT · DOC · TXT |
| Markdown | HTML · PDF · DOCX · RTF · TXT |
| Testo / codice | PDF · DOCX · RTF · HTML |
| JSON · PLIST · CSV | JSON ⇄ PLIST · JSON ⇄ CSV · CSV → tabella HTML (riconosce il separatore `;` di Excel) |
| PowerPoint · Excel · EPUB | AI.md |
| Archivi (zip, tar, gz, 7z…) | Estrai |

*In corsivo*: richiede FFmpeg. I file convertiti vanno accanto all'originale (o in Download se la cartella non è scrivibile) e non sovrascrivono mai niente.

## Struttura del codice

```
Sources/Nebula/
  NebulaApp.swift        avvio come app della barra dei menu
  AppDelegate.swift      menu ✦, scorciatoia, Servizi, avvio al login
  TriggerMonitor.swift   tasto ⌥ tenuto da solo, permesso Accessibilità
  HotKey.swift           scorciatoie globali (⌥⌘V)
  Clipboard.swift        appunti come sorgente, risultati negli appunti, ultimi 3 copiati
  Loader.swift           caricatore circolare attorno al puntatore
  Miniaturizer.swift     Mini: file più piccoli
  MarkItDown.swift       AI.md con MarkItDown + convertitore nativo
  Settings.swift         impostazioni e registrazione della scorciatoia
  FinderBridge.swift     selezione del Finder
  Catalog.swift          riconoscimento dei file e conversioni proposte
  Engine.swift           smistamento, percorsi di uscita, zip/estrazione
  ImageConverter.swift   ImageIO + PDFKit
  MediaConverter.swift   AVFoundation + FFmpeg facoltativo
  DocumentConverter.swift NSAttributedString, PDF impaginato A4, Markdown
  DataConverter.swift    JSON / PLIST / CSV
  NebulaController.swift stato, fisica a molla, strattone e finestra della nebula
  NebulaView.swift       il blob, la galassia interna, le opzioni
```

Per aggiungere un formato: aggiungi una voce in `ConversionCatalog.options(for:)` e gestisci il suo `tag` nel convertitore giusto. La scorciatoia di default è in `Shortcut.default` (`HotKey.swift`).
