# Dipendenze versionate

## ImageMagick

`Vendor/ImageMagick/` contiene ImageMagick reso rilocabile: il binario
`magick`, la chiusura delle librerie da cui dipende e i moduli coder, con
gli install name riscritti in forma relativa a `@loader_path`. La fase di
build «Includi ImageMagick nel bundle» lo copia in
`Comprimio.app/Contents/Resources/ImageMagick` e lo rifirma con l'identità
della macchina che compila.

**Compilare Comprimio non richiede quindi alcuna installazione di
ImageMagick.** I file qui sono firmati ad-hoc, così i byte versionati non
dipendono da chi ha costruito l'albero.

ImageMagick non esiste come pacchetto SwiftPM né come XCFramework: si
distribuisce come sorgente autotools, e il link statico su macOS non è
praticabile perché Apple non fornisce una libSystem statica. Includere
binario e dylib nel bundle è la strada indicata dai manutentori stessi
(vedi ImageMagick/ImageMagick discussione #7054).

### Aggiornare la versione

Serve un'installazione locale di ImageMagick da cui partire:

    brew install imagemagick          # oppure IMAGEMAGICK_PREFIX=/percorso
    python3 Scripts/bundle-imagemagick.py vendor Vendor/ImageMagick
    git add Vendor/ImageMagick && git commit

Lo script verifica da sé che ogni riferimento Mach-O risolva dentro
l'albero e si ferma altrimenti: un modulo con una dipendenza mancante non
darebbe errore a runtime, ImageMagick si limiterebbe a non registrare il
formato. La versione incorporata è in `Vendor/ImageMagick/imagemagick-bundle.json`.
