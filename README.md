# Nebula ✦ convertitore di file per macOS

App nativa per la barra dei menu (Swift, AppKit + SwiftUI, macOS 14+). **Tieni premuto ⌥ Option** e sotto il puntatore compare la **nebula**: un piccolo blob di vetro, appena trasparente, con dentro una galassia e intorno i formati disponibili. Punti un formato e il blob si deforma, molle, verso di lui. Rilasci e parte la conversione.

## Installazione

Scarica `Nebula.dmg` dalla pagina Releases, aprilo e trascina Nebula in Applicazioni. Al primo avvio:
1. Impostazioni di Sistema → Privacy e sicurezza → **Apri comunque**: l'app non è firmata con un account sviluppatore Apple.
2. Concedi **Accessibilità** a Nebula e poi riavviala. Serve per accorgersi di quando tieni premuto ⌥ e per incollare. Va riattivata a ogni aggiornamento.
3. Alla prima conversione concedi il permesso di controllare il Finder.

## Uso

Nebula ha quattro modalità, ognuna con un gesto suo e un cielo suo.

**Nebula · converte (tieni premuto ⌥)**
- Nel Finder con file selezionati compare subito. Altrove, o senza selezione, parte un caricatore di 1,5 s intorno al puntatore (premi ⌥ due volte di fila per dimezzarlo), poi la Nebula lavora su ciò che hai copiato. Il risultato va in Download e si aggiunge a Eco, senza toccare gli appunti.
- Punta un formato e rilascia ⌥. Se rilasci al centro, sparisce senza fare nulla.
- Strattone: parti fermo dal centro e scatta in linea retta, veloce, oltre il bordo verso un formato.
- Clic sul pulsante al centro: copia il file come ⌘C.

**Pulsar · modifica (⌥ Spazio, nel Finder)**
- Tutti i file: Mini (più piccolo, stesso formato quando possibile).
- PDF: Unisci (più PDF selezionati), Svuota (cancella quanto compilato nei moduli), Password.
- Video: Taglia, Muto. Audio: Taglia.
- Immagini: Scontorna (PNG trasparente), Testo (estrae il testo negli appunti), Oscura (sfoca volti e targhe).
- Cartelle: raggruppa il contenuto in sottocartelle Per tipo o Per mese, rinomina in blocco con Numera ("Cartella 001…"), Per data ("2026-11-23 001…") o Rinomina… con un nome tuo.

**Buco nero · scadenza e pulizia (⌥⌫, nel Finder)**
- Scadenza 1, 7 o 30 giorni: il file prende un'etichetta Finder con la data e alla scadenza va nel Cestino. Lo segue anche se lo sposti o lo rinomini.
- Pulisci: toglie GPS, dati della fotocamera, autore e proprietà dei documenti (anche Word, Excel e PowerPoint) e la traccia di dove è stato scaricato.

**Eco · incolla (tieni premuto ⌥⌘V)**
- Le ultime 3 cose copiate e i file convertiti dagli appunti. Punta e rilascia per incollare.

**Sempre**
- ⌘Z subito dopo un'azione la annulla. Nei 10 secondi successivi ⌘Z è riservato a Nebula; poi resta disponibile da ✦ → Annulla ultima azione.
- Abitudini: per ogni tipo di file e modalità, le opzioni che usi di più salgono piano piano verso l'alto e la preferita ha un pallino.
- Pulsar e Buco nero funzionano solo nel Finder con file selezionati e non intercettano mai i tasti mentre rinomini un file.
- Se usi ⌥ insieme ad altri tasti o al mouse, funziona come ⌥ normale.

## AI.md

Per tutti i documenti testuali (PDF, Word, RTF, HTML, testo, codice, Markdown, CSV, JSON, PowerPoint, Excel, EPUB) c'è l'opzione **AI.md**: trasforma il documento in Markdown pulito, pronto da dare a qualsiasi modello AI. Usa [MarkItDown](https://github.com/microsoft/markitdown) di Microsoft, già incluso nell'app sui Mac Apple Silicon. Altrove usa un convertitore nativo di riserva per PDF e documenti di testo.

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
  Miniaturizer.swift     Mini (in Pulsar): file più piccoli
  Habits.swift           adattamento alle abitudini
  Undo.swift             ⌘Z, appunti ripristinabili, avvisi
  Tools.swift            Pulsar: PDF, cartelle, video, immagini (Vision)
  ToolPanels.swift       pannelli password, rinomina, taglio
  BlackHole.swift        scadenze e pulizia dei metadati
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
