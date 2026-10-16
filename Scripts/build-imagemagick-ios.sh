#!/bin/bash
#
#  build-imagemagick-ios.sh
#  Comprimio
#
#  Cross-compila ImageMagick e le sue dipendenze per iOS e ne fa un
#  XCFramework statico in Vendor/ImageMagick-iOS.
#
#  Su iOS non si può lanciare `magick` come sottoprocesso, e l'App Store non
#  accetta dylib sciolte: ImageMagick va quindi linkato nell'app, con i coder
#  compilati dentro la libreria (`--without-modules`) e la configurazione
#  inclusa (`--enable-zero-configuration`), così non servono né file XML né
#  variabili d'ambiente.
#
#  Le versioni coincidono con quelle dell'albero Mac in Vendor/ImageMagick:
#  le stesse opzioni devono dare lo stesso file sulle due piattaforme.
#
#  Uso:
#      Scripts/build-imagemagick-ios.sh
#
#  Variabili:
#      QUANTUM=8|16    profondità del quantum (default 16)
#      HDRI=yes|no     pixel in virgola mobile (default no: su iPhone una foto
#                      da 48 MP in Q16HDRI occupa ~770 MB)
#      OUT=…           cartella di destinazione (default Vendor/ImageMagick-iOS)
#      WORK=…          cartella di lavoro (default build/imagemagick-ios)
#      JOBS=…          compilazioni in parallelo (default: numero di core)
#
#  Richiede Xcode con gli SDK iOS, CMake e pkg-config
#  (`brew install cmake ninja pkg-config`).
#

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QUANTUM="${QUANTUM:-16}"
HDRI="${HDRI:-no}"
OUT="${OUT:-$ROOT/Vendor/ImageMagick-iOS}"
WORK="${WORK:-$ROOT/build/imagemagick-ios}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
MIN_IOS=17.0

# nome|versione|url|sha256
SOURCES=(
    "imagemagick|7.1.2-30|https://github.com/ImageMagick/ImageMagick/archive/refs/tags/7.1.2-30.tar.gz|3034a64f22398e15ee3dd1e6b1aa83d838cfc47df1bb246ae0eca9590e6ace72"
    "libpng|1.6.59|https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.59.tar.gz|2540302a1844ad2b2b501977abecfa850f265f97b78f065a712ab4074a89f5b5"
    "libjpeg-turbo|3.2.0|https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz|6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e"
    "libwebp|1.6.0|https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz|e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564"
)

# Lo slice per i dispositivi e quello per il simulatore su Apple silicon.
PLATFORMS=(iphoneos iphonesimulator)

case "$QUANTUM" in 8|16) ;; *) echo "error: QUANTUM deve essere 8 o 16" >&2; exit 1 ;; esac
case "$HDRI" in yes|no) ;; *) echo "error: HDRI deve essere yes o no" >&2; exit 1 ;; esac
command -v cmake >/dev/null || { echo "error: serve CMake (brew install cmake)" >&2; exit 1; }
PKG_CONFIG_BIN="$(command -v pkg-config)" || { echo "error: serve pkg-config (brew install pkg-config)" >&2; exit 1; }

log() { printf '\n==> %s\n' "$*"; }

# MARK: - Sorgenti

fetch() {
    local name="$1" version="$2" url="$3" sha="$4"
    local archive="$WORK/downloads/$name-$version.tar.gz"
    local dest="$WORK/src/$name-$version"
    mkdir -p "$WORK/downloads" "$WORK/src"
    if [ ! -f "$archive" ]; then
        log "Scarico $name $version"
        curl -sSfL -o "$archive.part" "$url"
        mv "$archive.part" "$archive"
    fi
    echo "$sha  $archive" | shasum -a 256 -c --quiet - \
        || { echo "error: checksum di $name non valido" >&2; rm -f "$archive"; exit 1; }
    if [ ! -d "$dest" ]; then
        mkdir -p "$dest"
        tar xzf "$archive" -C "$dest" --strip-components 1
    fi
}

source_dir() {
    local entry
    for entry in "${SOURCES[@]}"; do
        IFS='|' read -r name version _ _ <<<"$entry"
        [ "$name" = "$1" ] && { echo "$WORK/src/$name-$version"; return; }
    done
    exit 1
}

# MARK: - Toolchain

setup_platform() {
    PLATFORM="$1"
    SDK="$(xcrun --sdk "$PLATFORM" --show-sdk-path)"
    case "$PLATFORM" in
        iphoneos)        TARGET="arm64-apple-ios$MIN_IOS" ;;
        iphonesimulator) TARGET="arm64-apple-ios$MIN_IOS-simulator" ;;
    esac
    PREFIX="$WORK/$PLATFORM/prefix"
    BUILD="$WORK/$PLATFORM/build"
    mkdir -p "$PREFIX" "$BUILD"

    export CC="$(xcrun --sdk "$PLATFORM" -f clang)"
    export CXX="$(xcrun --sdk "$PLATFORM" -f clang++)"
    export AR="$(xcrun --sdk "$PLATFORM" -f ar)"
    export RANLIB="$(xcrun --sdk "$PLATFORM" -f ranlib)"
    export CFLAGS="-target $TARGET -isysroot $SDK -O2 -fno-common"
    export CXXFLAGS="$CFLAGS"
    export CPPFLAGS="-I$PREFIX/include"
    export LDFLAGS="-target $TARGET -isysroot $SDK -L$PREFIX/lib"
    # Solo le dipendenze compilate qui: senza questo configure troverebbe
    # quelle di Homebrew, per macOS, e il link fallirebbe molto più avanti.
    export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
    unset PKG_CONFIG_PATH
}

cmake_build() {
    local name="$1"; shift
    local build="$BUILD/$name"
    rm -rf "$build"
    cmake -S "$(source_dir "$name")" -B "$build" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DCMAKE_OSX_SYSROOT="$PLATFORM" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DBUILD_SHARED_LIBS=OFF \
        "$@" >"$build.log" 2>&1 || { tail -40 "$build.log"; exit 1; }
    cmake --build "$build" -j "$JOBS" >>"$build.log" 2>&1 || { tail -40 "$build.log"; exit 1; }
    cmake --install "$build" >>"$build.log" 2>&1
}

# MARK: - Dipendenze

build_libjpeg() {
    log "[$PLATFORM] libjpeg-turbo"
    cmake_build libjpeg-turbo \
        -DENABLE_SHARED=OFF -DENABLE_STATIC=ON \
        -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF
}

build_libpng() {
    log "[$PLATFORM] libpng"
    # zlib è quella dell'SDK.
    cmake_build libpng \
        -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_FRAMEWORK=OFF \
        -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
}

build_libwebp() {
    log "[$PLATFORM] libwebp"
    # mux e demux servono a ImageMagick per il WebP animato.
    cmake_build libwebp \
        -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
        -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
        -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF \
        -DWEBP_BUILD_LIBWEBPMUX=ON
}

# MARK: - ImageMagick

build_imagemagick() {
    log "[$PLATFORM] ImageMagick (Q$QUANTUM, HDRI $HDRI)"
    local build="$BUILD/imagemagick"
    rm -rf "$build"
    mkdir -p "$build"
    # configure cerca zlib solo con pkg-config, e l'SDK iOS non ha zlib.pc:
    # senza questo mancano zlib e, a cascata, PNG (libpng.pc richiede zlib).
    cat >"$PREFIX/lib/pkgconfig/zlib.pc" <<EOF
Name: zlib
Description: zlib dell'SDK iOS
Version: $(sed -n 's/^#define ZLIB_VERSION "\(.*\)"/\1/p' "$SDK/usr/include/zlib.h")
Libs: -lz
Cflags:
EOF
    (
        cd "$build"
        # PATH ristretto: i programmi di Homebrew (gs, ffmpeg…) finirebbero
        # nei delegate inclusi nella libreria, e su iOS non si lancia niente.
        # getentropy è in libSystem ma l'SDK iOS non ha <sys/random.h>:
        # configure lo trova col test di link e la compilazione poi fallisce.
        # Esclusi per scelta, non per mancanza: x265 (GPL), libde265, libraw,
        # liblqr e glib (LGPL). HEIC e RAW su iOS passano da ImageIO; vedi
        # docs/ROADMAP-iOS.md. Le altre esclusioni sono dipendenze non ancora
        # compilate per iOS, o funzioni che Comprimio non usa.
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" PKG_CONFIG="$PKG_CONFIG_BIN" \
            "$(source_dir imagemagick)/configure" \
            --host=aarch64-apple-darwin \
            --prefix="$PREFIX" \
            --disable-shared --enable-static \
            --without-modules \
            --enable-zero-configuration \
            --disable-installed \
            --with-quantum-depth="$QUANTUM" \
            --enable-hdri="$HDRI" \
            --disable-openmp --disable-opencl \
            --without-utilities \
            --without-magick-plus-plus --without-perl --disable-docs \
            --without-x --without-xml \
            --without-fontconfig --without-freetype \
            --without-heic --without-raw --without-lqr \
            --without-tiff --without-lcms --without-openjp2 --without-jxl \
            --without-openexr --without-zstd --without-lzma --without-zip \
            --without-djvu --without-fftw --without-gslib --without-gvc \
            --without-pango --without-rsvg --without-wmf --without-flif \
            --without-uhdr --without-jbig --without-dps --without-raqm \
            --with-png --with-jpeg --with-webp --with-zlib --with-bzlib \
            ac_cv_func_getentropy=no \
            >configure.log 2>&1 || { tail -40 configure.log; exit 1; }
        make -j "$JOBS" >make.log 2>&1 || { grep -m20 -B2 -A5 "error:" make.log || tail -40 make.log; exit 1; }
        make install >install.log 2>&1
    )
    # Verifica i delegate presi da configure: uno mancante non dà errore, il
    # formato semplicemente non c'è. E nessun programma esterno.
    local delegates expected
    delegates="$(sed -n 's/^ *DELEGATES *= *//p' "$build/configure.log")"
    expected="bzlib jng jpeg png webp zlib"
    if [ "$delegates" != "$expected" ]; then
        echo "error: [$PLATFORM] delegate «${delegates}», attesi «${expected}»" >&2
        exit 1
    fi
}

# MARK: - XCFramework

package_platform() {
    local stage="$WORK/$PLATFORM/stage"
    rm -rf "$stage"
    mkdir -p "$stage/Headers"

    # Una sola libreria per slice: un binaryTarget di SwiftPM ne accetta una.
    local libs=()
    local lib
    for lib in "$PREFIX"/lib/libMagickWand-7.*.a "$PREFIX"/lib/libMagickCore-7.*.a \
               "$PREFIX/lib/libpng16.a" "$PREFIX/lib/libjpeg.a" \
               "$PREFIX/lib/libwebp.a" "$PREFIX/lib/libwebpmux.a" \
               "$PREFIX/lib/libwebpdemux.a" "$PREFIX/lib/libsharpyuv.a"; do
        [ -f "$lib" ] || { echo "error: manca $lib" >&2; exit 1; }
        libs+=("$lib")
    done
    xcrun libtool -static -no_warning_for_no_symbols -o "$stage/libImageMagick.a" "${libs[@]}"

    cp -R "$PREFIX"/include/ImageMagick-7/MagickCore "$PREFIX"/include/ImageMagick-7/MagickWand "$stage/Headers/"

    # Gli header vogliono i -D che di solito arrivano da `pkg-config
    # --cflags`. Presi dal .pc della build, non riscritti a mano: un quantum
    # diverso da quello della libreria sposterebbe i campi delle strutture.
    local defines
    defines="$(PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" "$PKG_CONFIG_BIN" --cflags MagickWand \
        | tr ' ' '\n' | sed -n 's/^-D\([A-Z_]*\)=\(.*\)$/#define \1 \2/p')"
    [ -n "$defines" ] || { echo "error: nessun -D nel .pc di MagickWand" >&2; exit 1; }
    {
        echo "// Generato da Scripts/build-imagemagick-ios.sh."
        echo "$defines"
        echo '#include "MagickWand/MagickWand.h"'
    } >"$stage/Headers/ImageMagick.h"

    cat >"$stage/Headers/module.modulemap" <<'EOF'
module ImageMagick [system] {
    header "ImageMagick.h"
    link "z"
    link "bz2"
    link "iconv"
    export *
}
EOF
}

create_xcframework() {
    log "XCFramework"
    rm -rf "$OUT/ImageMagick.xcframework"
    mkdir -p "$OUT"
    local args=()
    local platform
    for platform in "${PLATFORMS[@]}"; do
        args+=(-library "$WORK/$platform/stage/libImageMagick.a" -headers "$WORK/$platform/stage/Headers")
    done
    xcodebuild -create-xcframework "${args[@]}" -output "$OUT/ImageMagick.xcframework" >/dev/null

    local entry
    {
        echo "{"
        echo "  \"quantumDepth\": $QUANTUM,"
        echo "  \"hdri\": $([ "$HDRI" = yes ] && echo true || echo false),"
        echo "  \"minimumIOS\": \"$MIN_IOS\","
        echo "  \"sources\": {"
        local first=1
        for entry in "${SOURCES[@]}"; do
            IFS='|' read -r name version _ _ <<<"$entry"
            [ $first = 1 ] || echo ","
            printf '    "%s": "%s"' "$name" "$version"
            first=0
        done
        echo ""
        echo "  }"
        echo "}"
    } >"$OUT/imagemagick-ios.json"
}

# MARK: - Main

for entry in "${SOURCES[@]}"; do
    IFS='|' read -r name version url sha <<<"$entry"
    fetch "$name" "$version" "$url" "$sha"
done

for platform in "${PLATFORMS[@]}"; do
    setup_platform "$platform"
    rm -rf "$PREFIX"
    mkdir -p "$PREFIX"
    build_libjpeg
    build_libpng
    build_libwebp
    build_imagemagick
    package_platform
done

create_xcframework
log "Fatto: $OUT/ImageMagick.xcframework (Q$QUANTUM, HDRI $HDRI)"
