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
#  Alla fine lo script confronta `-list format` della build iOS, eseguita nel
#  simulatore, con quello dell'albero Mac: ogni differenza che non sia fra
#  quelle previste in `expected_format_differences` lo ferma.
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
#      SIMULATOR=…     UDID del simulatore per la verifica dei formati
#                      (default: il primo iPhone disponibile)
#      SKIP_FORMAT_CHECK=1   salta la verifica (solo per provare in fretta)
#
#  Richiede Xcode con gli SDK iOS e un runtime del simulatore, CMake, Ninja e
#  pkg-config (`brew install cmake ninja pkg-config`).
#

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QUANTUM="${QUANTUM:-16}"
HDRI="${HDRI:-no}"
OUT="${OUT:-$ROOT/Vendor/ImageMagick-iOS}"
WORK="${WORK:-$ROOT/build/imagemagick-ios}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
MIN_IOS=17.0

# nome|versione|url|sha256|licenza
#
# Le versioni sono quelle delle librerie dentro Vendor/ImageMagick (lette
# dalle librerie stesse, non dalle formule Homebrew di oggi). Fa eccezione
# libpng, che sul Mac è 1.6.58: la differenza è solo di correzioni, e il PNG
# è senza perdita.
SOURCES=(
    "imagemagick|7.1.2-30|https://github.com/ImageMagick/ImageMagick/archive/refs/tags/7.1.2-30.tar.gz|3034a64f22398e15ee3dd1e6b1aa83d838cfc47df1bb246ae0eca9590e6ace72|ImageMagick"
    "zstd|1.5.7|https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz|eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3|BSD-3-Clause"
    "xz|5.8.3|https://github.com/tukaani-project/xz/releases/download/v5.8.3/xz-5.8.3.tar.gz|3d3a1b973af218114f4f889bbaa2f4c037deaae0c8e815eec381c3d546b974a0|0BSD"
    "libdeflate|1.26|https://github.com/ebiggers/libdeflate/releases/download/v1.26/libdeflate-1.26.tar.gz|125856d4656e0feab660f94842f835923410c9281fedbcee64598c918da42b5a|MIT"
    "libjpeg-turbo|3.2.0|https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz|6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e|IJG AND BSD-3-Clause AND Zlib"
    "libpng|1.6.59|https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.59.tar.gz|2540302a1844ad2b2b501977abecfa850f265f97b78f065a712ab4074a89f5b5|libpng-2.0"
    "libwebp|1.6.0|https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz|e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564|BSD-3-Clause"
    "libtiff|4.7.2|https://download.osgeo.org/libtiff/tiff-4.7.2.tar.gz|672bd7d10aee4606171afb864f3570b83340f6a33e2c186dc0512f7145ffdf6a|libtiff"
    "lcms2|2.19|https://github.com/mm2/Little-CMS/releases/download/lcms2.19/lcms2-2.19.tar.gz|49e7e134e4299733dd0eda434fa468997a28ab3d33fa397c642b03644f552216|MIT"
    "freetype|2.14.3|https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz|36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f|FTL"
    "openjpeg|2.5.4|https://github.com/uclouvain/openjpeg/archive/refs/tags/v2.5.4.tar.gz|a695fbe19c0165f295a8531b1e4e855cd94d0875d2f88ec4b61080677e27188a|BSD-2-Clause"
    "highway|1.4.0|https://github.com/google/highway/archive/refs/tags/1.4.0.tar.gz|e72241ac9524bb653ae52ced768b508045d4438726a303f10181a38f764a453c|Apache-2.0 OR BSD-3-Clause"
    "brotli|1.2.0|https://github.com/google/brotli/archive/refs/tags/v1.2.0.tar.gz|816c96e8e8f193b40151dad7e8ff37b1221d019dbcb9c35cd3fadbfe6477dfec|MIT"
    "libjxl|0.12.0|https://github.com/libjxl/libjxl/archive/refs/tags/v0.12.0.tar.gz|03e9be69a30be4011f559da75328b6d7cea8ad921fabfbd551ce10bf45cdc992|BSD-3-Clause"
    "libaom|3.14.1|https://storage.googleapis.com/aom-releases/libaom-3.14.1.tar.gz|44bf90dbd23e734d50e70a8c41c285193922938bd0d3bc2ee56764d181d55ef5|BSD-2-Clause"
    "libheif|1.23.1|https://github.com/strukturag/libheif/releases/download/v1.23.1/libheif-1.23.1.tar.gz|0de0327f60fcd47de90d5654c6fe152232738d60d84fe084ec3e0f35e03b166a|LGPL-3.0-or-later"
    "imath|3.2.3|https://github.com/AcademySoftwareFoundation/Imath/archive/refs/tags/v3.2.3.tar.gz|e10c12b3f21f45bf08e09d4215d9c7691368d747beebd840de0b6fefed2df9f8|BSD-3-Clause"
    "openjph|0.31.0|https://github.com/aous72/OpenJPH/archive/refs/tags/0.31.0.tar.gz|fe169dbbaae71a169a0a6a68dccb346616193252c1ca044217afa0d5d1dc436f|BSD-2-Clause"
    "openexr|3.4.15|https://github.com/AcademySoftwareFoundation/openexr/archive/refs/tags/v3.4.15.tar.gz|445ed5b0ea4d9cf98be3a4f219e419628b123b61dec65ccb743ab9b07fbebdaa|BSD-3-Clause"
)

# Le librerie che finiscono nell'XCFramework, nell'ordine del link.
LIBRARIES=(
    "libMagickWand-7.*.a" "libMagickCore-7.*.a"
    libheif.a libaom.a
    libjxl.a libjxl_threads.a libjxl_cms.a libhwy.a
    libbrotlienc.a libbrotlidec.a libbrotlicommon.a
    "libOpenEXRUtil-*.a" "libOpenEXR-*.a" "libOpenEXRCore-*.a"
    "libIlmThread-*.a" "libIex-*.a" "libImath-*.a" libopenjph.a libdeflate.a
    libopenjp2.a libtiff.a liblcms2.a libfreetype.a
    libpng16.a libjpeg.a libwebpmux.a libwebpdemux.a libwebp.a libsharpyuv.a
    libzstd.a liblzma.a
)

# Librerie di sistema dell'SDK da linkare insieme all'XCFramework.
SYSTEM_LIBRARIES=(z bz2 iconv xml2 c++)

# Lo slice per i dispositivi e quello per il simulatore su Apple silicon.
PLATFORMS=(${PLATFORMS:-iphoneos iphonesimulator})

case "$QUANTUM" in 8|16) ;; *) echo "error: QUANTUM deve essere 8 o 16" >&2; exit 1 ;; esac
case "$HDRI" in yes|no) ;; *) echo "error: HDRI deve essere yes o no" >&2; exit 1 ;; esac
command -v cmake >/dev/null || { echo "error: serve CMake (brew install cmake)" >&2; exit 1; }
command -v ninja >/dev/null || { echo "error: serve Ninja (brew install ninja)" >&2; exit 1; }
PKG_CONFIG_BIN="$(command -v pkg-config)" || { echo "error: serve pkg-config (brew install pkg-config)" >&2; exit 1; }

log() { printf '\n==> %s\n' "$*"; }

# MARK: - Sorgenti

fetch() {
    local name="$1" version="$2" url="$3" sha="$4"
    local archive="$WORK/downloads/$name-$version.tar.${url##*.tar.}"
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
        tar xf "$archive" -C "$dest" --strip-components 1
    fi
}

source_dir() {
    local entry
    for entry in "${SOURCES[@]}"; do
        IFS='|' read -r name version _ _ _ <<<"$entry"
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
    local source
    source="$(source_dir "$name")${CMAKE_SUBDIR:+/$CMAKE_SUBDIR}"
    rm -rf "$build"
    cmake -S "$source" -B "$build" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
        -DCMAKE_OSX_SYSROOT="$PLATFORM" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        "$@" >"$build.log" 2>&1 || { tail -40 "$build.log"; exit 1; }
    cmake --build "$build" -j "$JOBS" >>"$build.log" 2>&1 || { grep -m20 -B2 -A5 "error:" "$build.log" || tail -40 "$build.log"; exit 1; }
    cmake --install "$build" >>"$build.log" 2>&1
}

autotools_build() {
    local name="$1"; shift
    local build="$BUILD/$name"
    rm -rf "$build"
    mkdir -p "$build"
    (
        cd "$build"
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$(source_dir "$name")/configure" \
            --host=aarch64-apple-darwin \
            --prefix="$PREFIX" \
            --disable-shared --enable-static \
            "$@" >configure.log 2>&1 || { tail -40 configure.log; exit 1; }
        make -j "$JOBS" >make.log 2>&1 || { grep -m20 -B2 -A5 "error:" make.log || tail -40 make.log; exit 1; }
        make install >install.log 2>&1
    )
}

# Un .pc per una libreria dell'SDK, che non ne ha: configure e CMake le
# cercano con pkg-config.
system_pc() {
    local module="$1" version="$2" libs="$3" cflags="$4"
    cat >"$PREFIX/lib/pkgconfig/$module.pc" <<EOF
Name: $module
Description: $module dell'SDK iOS
Version: $version
Libs: $libs
Cflags: $cflags
EOF
}

# MARK: - Dipendenze

build_compression() {
    log "[$PLATFORM] zstd, xz, libdeflate"
    CMAKE_SUBDIR=build/cmake cmake_build zstd \
        -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON \
        -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF -DZSTD_BUILD_CONTRIB=OFF \
        -DZSTD_MULTITHREAD_SUPPORT=ON
    autotools_build xz \
        --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
        --disable-lzma-links --disable-scripts --disable-doc --disable-nls
    cmake_build libdeflate \
        -DLIBDEFLATE_BUILD_SHARED_LIB=OFF -DLIBDEFLATE_BUILD_STATIC_LIB=ON \
        -DLIBDEFLATE_BUILD_GZIP=OFF
}

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

build_libtiff() {
    log "[$PLATFORM] libtiff"
    # Le stesse compressioni del Mac: zlib, JPEG, WebP, zstd, LZMA. Il
    # libtiff di Homebrew non usa libdeflate, quindi nemmeno questo. Per
    # iOS il CMake di libtiff farebbe un framework: serve la libreria.
    cmake_build libtiff \
        -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF \
        -Dtiff-framework=OFF -Dcxx=OFF -Djbig=OFF -Dlerc=OFF -Dlibdeflate=OFF -Djpeg12=OFF \
        -Dzlib=ON -Djpeg=ON -Dwebp=ON -Dzstd=ON -Dlzma=ON
}

build_lcms2() {
    log "[$PLATFORM] lcms2"
    autotools_build lcms2 --without-jpeg --without-tiff
}

build_freetype() {
    log "[$PLATFORM] FreeType"
    # Come la formula Homebrew: PNG (le emoji a colori), zlib e bzip2.
    # Senza HarfBuzz e Brotli (WOFF2): ImageMagick non li usa.
    cmake_build freetype \
        -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON \
        -DFT_REQUIRE_PNG=ON -DFT_REQUIRE_ZLIB=ON -DFT_REQUIRE_BZIP2=ON
}

build_openjpeg() {
    log "[$PLATFORM] OpenJPEG"
    cmake_build openjpeg \
        -DBUILD_STATIC_LIBS=ON -DBUILD_CODEC=OFF -DBUILD_DOC=OFF
}

build_libjxl() {
    log "[$PLATFORM] highway, brotli, libjxl"
    cmake_build highway \
        -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_CONTRIB=ON \
        -DHWY_ENABLE_INSTALL=ON
    cmake_build brotli \
        -DBROTLI_BUILD_TOOLS=OFF -DBROTLI_DISABLE_TESTS=ON
    # Le dipendenze sono quelle compilate qui, come per la formula Homebrew:
    # lcms2 al posto di skcms, che il Mac non usa.
    cmake_build libjxl \
        -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON \
        -DJPEGXL_FORCE_SYSTEM_LCMS2=ON -DJPEGXL_ENABLE_SKCMS=OFF \
        -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF \
        -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
        -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_JPEGLI=OFF \
        -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF \
        -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_PLUGINS=OFF \
        -DJPEGXL_BUNDLE_LIBPNG=OFF -DJPEGXL_ENABLE_VIEWERS=OFF \
        -DJPEGXL_ENABLE_FUZZERS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF
}

build_avif() {
    log "[$PLATFORM] libaom, libheif (solo AVIF)"
    # Senza libvmaf: serve solo a `--tune=vmaf`, che ImageMagick non chiede.
    # Il rilevamento della CPU resta a runtime (su Apple con sysctlbyname):
    # spento, libaom chiama direttamente le versioni più avanzate compilate,
    # e un iPhone senza DotProd o I8MM andrebbe in crash. SVE e SVE2 non ci
    # sono su nessun chip Apple: spento il rilevamento, l'encoder AVIF
    # moriva di SIGILL nel simulatore.
    cmake_build libaom \
        -DAOM_TARGET_CPU=arm64 -DCONFIG_RUNTIME_CPU_DETECT=1 \
        -DENABLE_SVE=0 -DENABLE_SVE2=0 \
        -DENABLE_DOCS=0 -DENABLE_EXAMPLES=0 -DENABLE_TESTS=0 -DENABLE_TOOLS=0 \
        -DENABLE_TESTDATA=0 -DCONFIG_TUNE_VMAF=0 -DCONFIG_TUNE_BUTTERAUGLI=0
    # Solo AV1. Niente libde265 né x265 (LGPL e GPL): l'HEIC su iOS passa da
    # ImageIO, e senza codec HEVC ImageMagick non registra HEIC né HEIF.
    # libheif resta LGPL: linkata staticamente, va distribuita in modo che
    # chi vuole possa ricollegarla (vedi Vendor/README.md).
    # heifio, la libreria di I/O degli esempi, si compila sempre: senza i
    # find_package di TIFF, JPEG e PNG resta al minimo e non pesca il
    # tiff-config di CMake, che vorrebbe un target liblzma inesistente.
    cmake_build libheif \
        -DCMAKE_DISABLE_FIND_PACKAGE_TIFF=ON -DCMAKE_DISABLE_FIND_PACKAGE_JPEG=ON \
        -DCMAKE_DISABLE_FIND_PACKAGE_PNG=ON \
        -DWITH_AOM_ENCODER=ON -DWITH_AOM_DECODER=ON \
        -DWITH_LIBDE265=OFF -DWITH_X265=OFF -DWITH_DAV1D=OFF -DWITH_RAV1E=OFF \
        -DWITH_SvtEnc=OFF -DWITH_KVAZAAR=OFF -DWITH_UVG266=OFF -DWITH_VVDEC=OFF \
        -DWITH_VVENC=OFF -DWITH_FFMPEG_DECODER=OFF -DWITH_OpenH264_DECODER=OFF \
        -DWITH_OpenH264_ENCODER=OFF -DWITH_JPEG_DECODER=OFF -DWITH_JPEG_ENCODER=OFF \
        -DWITH_OpenJPEG_DECODER=OFF -DWITH_OpenJPEG_ENCODER=OFF \
        -DWITH_OPENJPH_ENCODER=OFF -DWITH_OPENJPH_DECODER=OFF \
        -DWITH_LIBSHARPYUV=ON -DWITH_GDK_PIXBUF=OFF -DWITH_EXAMPLES=OFF \
        -DWITH_EXAMPLE_HEIF_VIEW=OFF -DWITH_FUZZERS=OFF -DENABLE_PLUGIN_LOADING=OFF \
        -DENABLE_MULTITHREADING_SUPPORT=ON -DBUILD_DOCUMENTATION=OFF
}

build_openexr() {
    log "[$PLATFORM] Imath, OpenJPH, OpenEXR"
    cmake_build imath -DPYTHON=OFF -DIMATH_INSTALL_PKG_CONFIG=ON
    cmake_build openjph \
        -DOJPH_BUILD_EXECUTABLES=OFF -DOJPH_ENABLE_TIFF_SUPPORT=OFF \
        -DOJPH_BUILD_TESTS=OFF
    cmake_build openexr \
        -DOPENEXR_BUILD_TOOLS=OFF -DOPENEXR_INSTALL_TOOLS=OFF \
        -DOPENEXR_BUILD_EXAMPLES=OFF -DOPENEXR_INSTALL_EXAMPLES=OFF \
        -DOPENEXR_BUILD_PYTHON=OFF -DOPENEXR_INSTALL_PKG_CONFIG=ON \
        -DOPENEXR_FORCE_INTERNAL_DEFLATE=OFF -DOPENEXR_FORCE_INTERNAL_IMATH=OFF \
        -DOPENEXR_FORCE_INTERNAL_OPENJPH=OFF -DOPENEXR_ENABLE_THREADING=ON
}

# MARK: - ImageMagick

build_imagemagick() {
    log "[$PLATFORM] ImageMagick (Q$QUANTUM, HDRI $HDRI)"
    local build="$BUILD/imagemagick"
    rm -rf "$build"
    mkdir -p "$build"
    # configure cerca zlib e libxml2 solo con pkg-config, e l'SDK iOS non ha
    # i loro .pc: senza questi mancano zlib e, a cascata, PNG (libpng.pc
    # richiede zlib).
    system_pc zlib "$(sed -n 's/^#define ZLIB_VERSION "\(.*\)"/\1/p' "$SDK/usr/include/zlib.h")" "-lz" ""
    system_pc libxml-2.0 \
        "$(sed -n 's/^#define LIBXML_DOTTED_VERSION "\(.*\)"/\1/p' "$SDK/usr/include/libxml2/libxml/xmlversion.h")" \
        "-lxml2" "-I$SDK/usr/include/libxml2"
    # Le librerie sono statiche: pkg-config deve dare anche le loro
    # dipendenze, o i test di link di configure falliscono e il delegate
    # sparisce senza errori.
    local pkg_config="$BUILD/pkg-config-static"
    printf '#!/bin/sh\nexec "%s" --static "$@"\n' "$PKG_CONFIG_BIN" >"$pkg_config"
    chmod +x "$pkg_config"
    (
        cd "$build"
        # PATH ristretto: i programmi di Homebrew (gs, ffmpeg…) finirebbero
        # nei delegate inclusi nella libreria, e su iOS non si lancia niente.
        # getentropy è in libSystem ma l'SDK iOS non ha <sys/random.h>:
        # configure lo trova col test di link e la compilazione poi fallisce.
        # libjxl, OpenEXR e OpenJPH sono in C++: -lc++ serve ai test di link.
        # Esclusi per scelta, non per mancanza: x265 (GPL), libde265, libraw,
        # liblqr e glib (LGPL). HEIC e RAW su iOS passano da ImageIO; vedi
        # docs/ROADMAP-iOS.md. fontconfig non esiste su iOS (i font arrivano
        # da percorsi espliciti), e le altre esclusioni sono funzioni che
        # nemmeno l'albero Mac ha.
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" PKG_CONFIG="$pkg_config" LIBS="-lc++" \
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
            --without-x --without-fontconfig \
            --without-raw --without-lqr --without-zip \
            --without-djvu --without-fftw --without-gslib --without-gvc \
            --without-pango --without-rsvg --without-wmf --without-flif \
            --without-uhdr --without-jbig --without-dps --without-raqm \
            --with-png --with-jpeg --with-webp --with-zlib --with-bzlib \
            --with-tiff --with-lcms --with-openjp2 --with-jxl --with-heic \
            --with-openexr --with-freetype --with-zstd --with-lzma --with-xml \
            ac_cv_func_getentropy=no \
            >configure.log 2>&1 || { tail -40 configure.log; exit 1; }
        make -j "$JOBS" >make.log 2>&1 || { grep -m20 -B2 -A5 "error:" make.log || tail -40 make.log; exit 1; }
        make install >install.log 2>&1
    )
    # Verifica i delegate presi da configure: uno mancante non dà errore, il
    # formato semplicemente non c'è. E nessun programma esterno.
    local delegates expected
    delegates="$(sed -n 's/^ *DELEGATES *= *//p' "$build/configure.log" | tr ' ' '\n' | sort | xargs)"
    expected="bzlib freetype heic jng jp2 jpeg jxl lcms lzma openexr png tiff webp xml zlib zstd"
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
    local pattern lib
    for pattern in "${LIBRARIES[@]}"; do
        # shellcheck disable=SC2206
        local matches=($PREFIX/lib/$pattern)
        [ -f "${matches[0]}" ] || { echo "error: manca $PREFIX/lib/$pattern" >&2; exit 1; }
        libs+=("${matches[@]}")
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

    {
        echo "module ImageMagick [system] {"
        echo "    header \"ImageMagick.h\""
        for lib in "${SYSTEM_LIBRARIES[@]}"; do
            echo "    link \"$lib\""
        done
        echo "    export *"
        echo "}"
    } >"$stage/Headers/module.modulemap"
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
            IFS='|' read -r name version _ _ _ <<<"$entry"
            [ $first = 1 ] || echo ","
            printf '    "%s": "%s"' "$name" "$version"
            first=0
        done
        echo ""
        echo "  }"
        echo "}"
    } >"$OUT/imagemagick-ios.json"
}

# MARK: - Licenze

# I file di licenza di ogni sorgente, in Vendor/ImageMagick-iOS/Licenses,
# più un indice che l'app mostra nella schermata dei riconoscimenti.
# Il nome del file nella sorgente cambia da progetto a progetto: si prende il
# primo che esiste fra quelli usati di solito.
collect_licenses() {
    log "Licenze"
    local dir="$OUT/Licenses"
    rm -rf "$dir"
    mkdir -p "$dir"
    local entry name version license src file found
    {
        echo "["
        local first=1
        for entry in "${SOURCES[@]}"; do
            IFS='|' read -r name version _ _ license <<<"$entry"
            src="$(source_dir "$name")"
            found=""
            for file in LICENSE LICENSE.md LICENSE.txt COPYING COPYING.txt LICENSE.TXT \
                        LICENSE.rst README.ijg docs/LICENSE.TXT; do
                if [ -f "$src/$file" ]; then found="$src/$file"; break; fi
            done
            [ -n "$found" ] || { echo "error: nessun file di licenza per $name" >&2; exit 1; }
            # libjpeg-turbo e FreeType hanno più testi: li si unisce.
            case "$name" in
                libjpeg-turbo) cat "$src/LICENSE.md" "$src/README.ijg" >"$dir/$name.txt" ;;
                freetype)      cat "$src/LICENSE.TXT" "$src/docs/FTL.TXT" >"$dir/$name.txt" ;;
                xz)            cat "$src/COPYING" "$src/COPYING.0BSD" >"$dir/$name.txt" ;;
                *)             cp "$found" "$dir/$name.txt" ;;
            esac
            # libaom e libwebp hanno anche una licenza sui brevetti.
            if [ -f "$src/PATENTS" ]; then
                printf '\n\n' >>"$dir/$name.txt"
                cat "$src/PATENTS" >>"$dir/$name.txt"
            fi
            [ $first = 1 ] || echo ","
            printf '  {"name": "%s", "version": "%s", "license": "%s", "file": "%s.txt"}' \
                "$name" "$version" "$license" "$name"
            first=0
        done
        echo ""
        echo "]"
    } >"$dir/licenses.json"
}

# MARK: - Verifica dei formati

# Differenze attese fra `-list format` del Mac e quello di iOS, con il modo
# (r, w, +) che deve avere su iOS; «-» vuol dire assente. Tutto ciò che non è
# qui deve coincidere col Mac, modo compreso.
#
# I raw delle fotocamere (DNG, CR2, NEF…) coincidono nell'elenco ma non nei
# fatti: senza libraw il coder DNG passa la decodifica a un programma esterno,
# che su iOS non si può lanciare. Come HEIC, passano da ImageIO.
expected_format_differences() {
    cat <<'EOF'
# HEIC e HEIF: senza codec HEVC (niente libde265 né x265) ImageMagick li
# registra in sola lettura, e leggerli fallisce. Su iOS passano da ImageIO,
# in lettura e in scrittura (MagickEngine/ImageIOBridge.swift).
HEIC r--
HEIF r--
# I canali grezzi del coder RAW: il Mac li ha (`magick … R:file` funziona) ma
# con i moduli `-list format` non li elenca.
A rw+
B rw+
C rw+
G rw+
K rw+
M rw+
O rw+
R rw+
Y rw+
# Graphviz manca su entrambi: il Mac lo elenca come «---» perché il modulo
# dot.so esiste, senza moduli la voce non viene registrata.
DOT -
GV -
# KERNEL (un elenco di numeri, non un'immagine) manca in coders-list.h di
# ImageMagick 7.1.2-30, e senza moduli il coder non viene registrato.
KERNEL -
# SCREENSHOT è compilato solo senza moduli; funziona solo su Windows.
SCREENSHOT r--
EOF
}

# Il `-list format` dell'albero Mac, ridotto a «NOME modo».
mac_formats() {
    local tree="$ROOT/Vendor/ImageMagick/$(uname -m)"
    [ -x "$tree/bin/magick" ] || tree="$(ls -d "$ROOT"/Vendor/ImageMagick/*/ | head -1)"
    local manifest="$tree/imagemagick-bundle.json"
    local coders filters
    coders="$(sed -n 's/.*"coderModulePath": "\(.*\)".*/\1/p' "$manifest")"
    filters="$(sed -n 's/.*"filterModulePath": "\(.*\)".*/\1/p' "$manifest")"
    local configure=""
    local path
    for path in $(sed -n '/"configurePaths"/,/]/p' "$manifest" | sed -n 's/^ *"\(.*\)",\{0,1\}$/\1/p'); do
        configure="${configure:+$configure:}$tree/$path"
    done
    env -i PATH=/usr/bin:/bin MAGICK_HOME="$tree" \
        MAGICK_CODER_MODULE_PATH="$tree/$coders" MAGICK_FILTER_MODULE_PATH="$tree/$filters" \
        MAGICK_CONFIGURE_PATH="$configure" \
        "$tree/bin/magick" -list format | format_modes
}

# Con i moduli c'è una colonna in più, quella del modulo, fra nome e modo:
# il modo è il primo campo della forma «rw+».
format_modes() {
    awk '{ for (i = 2; i <= 3 && i <= NF; i++) if ($i ~ /^[r-][w-][+-]$/) {
               name = $1; sub(/\*$/, "", name); print name, $i; break } }' | sort
}

# Esegue `-list format` con la libreria appena costruita, nel simulatore:
# un eseguibile per il simulatore non parte sull'host.
ios_formats() {
    local sim_prefix="$WORK/iphonesimulator/prefix"
    local checker="$WORK/list-formats"
    local sdk
    sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    cat >"$WORK/list-formats.c" <<'EOF'
#include <MagickWand/MagickWand.h>
int main(void) {
    char *argv[] = { "magick", "-list", "format", NULL };
    MagickWandGenesis();
    ImageInfo *info = AcquireImageInfo();
    ExceptionInfo *exception = AcquireExceptionInfo();
    MagickBooleanType status = MagickImageCommand(info, 3, argv, NULL, exception);
    DestroyExceptionInfo(exception);
    DestroyImageInfo(info);
    MagickWandTerminus();
    return status == MagickTrue ? 0 : 1;
}
EOF
    local system_flags=()
    local lib
    for lib in "${SYSTEM_LIBRARIES[@]}"; do system_flags+=("-l$lib"); done
    "$(xcrun --sdk iphonesimulator -f clang)" -target "arm64-apple-ios$MIN_IOS-simulator" -isysroot "$sdk" \
        $(grep '^#define' "$WORK/iphonesimulator/stage/Headers/ImageMagick.h" | awk '{printf "-D%s=%s ", $2, $3}') \
        -I"$sim_prefix/include/ImageMagick-7" "$WORK/list-formats.c" \
        "$WORK/iphonesimulator/stage/libImageMagick.a" "${system_flags[@]}" -o "$checker"

    local device="${SIMULATOR:-}"
    if [ -z "$device" ]; then
        device="$(xcrun simctl list devices available | sed -n 's/^ *iPhone[^(]*(\([0-9A-F-]\{36\}\)).*/\1/p' | head -1)"
    fi
    [ -n "$device" ] || { echo "error: nessun simulatore iPhone disponibile per la verifica dei formati" >&2; exit 1; }
    local booted=0
    # Niente `grep -q` qui: con pipefail chiude la pipe in anticipo, la
    # pipeline fallisce e un simulatore già acceso verrebbe spento alla fine.
    if ! xcrun simctl list devices | grep "$device" | grep Booted >/dev/null; then
        xcrun simctl bootstatus "$device" -b >/dev/null
        booted=1
    fi
    local output status=0
    output="$(xcrun simctl spawn "$device" "$checker" 2>&1)" || status=$?
    [ $booted = 1 ] && xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
    [ $status = 0 ] || { echo "$output" | tail -20 >&2; echo "error: -list format non riuscito nel simulatore" >&2; exit 1; }
    echo "$output" | format_modes
}

check_formats() {
    log "Verifica dei formati (simulatore)"
    local mac ios expected
    mac="$(mac_formats)"
    ios="$(ios_formats)"
    [ -n "$mac" ] || { echo "error: -list format del Mac vuoto" >&2; exit 1; }
    expected="$(expected_format_differences | grep -v '^#')"

    # Ciò che iOS dovrebbe avere: il Mac, corretto dalle differenze attese.
    local want
    want="$(awk 'NR == FNR { diff[$1] = $2; next }
                 ($1 in diff) { if (diff[$1] != "-") print $1, diff[$1]; delete diff[$1]; next }
                 { print }
                 END { for (n in diff) if (diff[n] != "-") print n, diff[n] }' \
            <(echo "$expected") <(echo "$mac") | sort)"
    local report
    report="$(diff <(echo "$want") <(echo "$ios") || true)"
    if [ -n "$report" ]; then
        echo "error: i formati di iOS non coincidono con quelli del Mac" >&2
        echo "       (< atteso, > iOS; le differenze volute sono in expected_format_differences)" >&2
        echo "$report" | grep '^[<>]' >&2
        exit 1
    fi
    echo "$(echo "$ios" | wc -l | xargs) formati, $(echo "$ios" | grep -c ' .w' | xargs) scrivibili: coincidono con il Mac"
}

# MARK: - Main

for entry in "${SOURCES[@]}"; do
    IFS='|' read -r name version url sha _ <<<"$entry"
    fetch "$name" "$version" "$url" "$sha"
done

for platform in "${PLATFORMS[@]}"; do
    setup_platform "$platform"
    rm -rf "$PREFIX"
    mkdir -p "$PREFIX/lib/pkgconfig"
    build_compression
    build_libjpeg
    build_libpng
    build_libwebp
    build_libtiff
    build_lcms2
    build_freetype
    build_openjpeg
    build_libjxl
    build_avif
    build_openexr
    build_imagemagick
    package_platform
done

[ "${SKIP_FORMAT_CHECK:-}" = 1 ] || check_formats
create_xcframework
collect_licenses
log "Fatto: $OUT/ImageMagick.xcframework (Q$QUANTUM, HDRI $HDRI)"
