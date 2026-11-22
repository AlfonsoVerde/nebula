# Nebula ✦ convertitore di file per macOS

App nativa per la barra dei menu (Swift, AppKit + SwiftUI, macOS 14+). Selezioni uno o più file nel Finder e **tieni premuto ⌥ Spazio**: sotto il puntatore compare la **nebula**, un piccolo blob di vetro scuro con dentro una galassia. Intorno al centro ci sono i formati disponibili. Muovi il puntatore verso un formato e il blob si deforma, molle, in quella direzione. Rilasci la scorciatoia e il file viene convertito.

## Installazione

Scarica `Nebula.dmg` dalla pagina Releases del repository, aprilo e trascina Nebula in Applicazioni. Al primo avvio macOS la blocca, perché non è firmata con un account sviluppatore Apple: vai in Impostazioni di Sistema → Privacy e sicurezza → **Apri comunque**. Alla prima scorciatoia concedi anche il permesso di controllare il Finder.

Facoltativo: `brew install ffmpeg` sblocca WebM, MKV, MP3, FLAC, OGG e WebP.

## Uso

- **Tieni premuto ⌥ Spazio**, punta un formato, **rilascia** → conversione.
- Se rilasci senza muoverti, la nebula **resta aperta**: punta e clicca. **1–9** scelgono un formato, **Esc** chiude.
- A conversione finita, un clic sul centro mostra il file nel Finder.
- La scorciatoia si cambia in **✦ → Impostazioni…**. Di base è attiva solo quando il Finder è in primo piano, così ⌥ Spazio continua a funzionare normalmente nelle altre app.
- In alternativa: tasto destro nel Finder → **Converti con Nebula**, oppure trascini i file sull'icona dell'app.

## Formati

Il formato di partenza viene riconosciuto in automatico (UTType + estensione) e la nebula propone solo le conversioni che hanno senso. Con più file selezionati compaiono solo i formati comuni a tutti. **ZIP** c'è sempre.

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
  HotKey.swift           scorciatoia globale con pressione/rilascio
  Settings.swift         impostazioni e registrazione della scorciatoia
  FinderBridge.swift     selezione del Finder
  Catalog.swift          riconoscimento dei file e conversioni proposte
  Engine.swift           smistamento, percorsi di uscita, zip/estrazione
  ImageConverter.swift   ImageIO + PDFKit
  MediaConverter.swift   AVFoundation + FFmpeg facoltativo
  DocumentConverter.swift NSAttributedString, PDF impaginato A4, Markdown
  DataConverter.swift    JSON / PLIST / CSV
  NebulaController.swift stato, fisica a molla e finestra della nebula
  NebulaView.swift       il blob, la galassia interna, le opzioni
```

Per aggiungere un formato: aggiungi una voce in `ConversionCatalog.options(for:)` e gestisci il suo `tag` nel convertitore giusto. La scorciatoia di default è in `Shortcut.default` (`HotKey.swift`).
