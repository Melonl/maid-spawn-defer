#!/usr/bin/env bash
# 离线构建：直接使用一个已安装的 Minecraft 1.20.1 Forge 环境作为 classpath，
# 不需要 ForgeGradle / 不需要访问 maven.minecraftforge.net。
#
# 用法：
#   MC_DIR="/c/Users/you/Desktop/pack/.minecraft" ./tools/build-offline.sh
#   （MC_DIR 默认 ~/.minecraft）
#
# 产物：dist/<mod_id>-<version>.jar

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MC_DIR="${MC_DIR:-$HOME/.minecraft}"

prop() {
    grep -E "^$1=" "$ROOT/gradle.properties" | head -1 | cut -d= -f2- | tr -d '\r'
}

MOD_ID="$(prop mod_id)"
VERSION="$(prop mod_version)"
MC_VERSION="$(prop minecraft_version)"
FORGE_VERSION="$(prop forge_version)"

die() { echo "错误：$*" >&2; exit 1; }

command -v javac >/dev/null 2>&1 || die "找不到 javac，请安装 JDK 17+ 并加入 PATH"
command -v jar   >/dev/null 2>&1 || die "找不到 jar，请安装 JDK 17+ 并加入 PATH"
[ -d "$MC_DIR" ] || die "MC_DIR 不存在：$MC_DIR"

pick() { # pick <dir> <pattern> [filter]
    [ -d "$1" ] || return 1
    find "$1" -type f -name "$2" 2>/dev/null | sort -V | tail -1
}

LIB="$MC_DIR/libraries"
SRG="$(pick "$LIB/net/minecraft/client" "client-${MC_VERSION}-*-srg.jar")"
[ -n "${SRG:-}" ] || SRG="$(find "$LIB/net/minecraft/client" -name 'client-*-srg.jar' 2>/dev/null | grep -F "$MC_VERSION" | sort -V | tail -1)"

FORGE="$(pick "$LIB/net/minecraftforge/forge/${MC_VERSION}-${FORGE_VERSION}" "forge-*-universal.jar")"
[ -n "${FORGE:-}" ] || FORGE="$(find "$LIB/net/minecraftforge/forge" -name 'forge-*-universal.jar' 2>/dev/null | grep -F "$MC_VERSION" | sort -V | tail -1)"

FMLCORE="$(find "$LIB/net/minecraftforge/fmlcore" -name 'fmlcore-*.jar' 2>/dev/null | grep -F "$MC_VERSION" | sort -V | tail -1)"
# @Mod 注解在 javafmllanguage 里，不在 forge-universal
JAVAFML="$(find "$LIB/net/minecraftforge/javafmllanguage" -name 'javafmllanguage-*.jar' 2>/dev/null | grep -F "$MC_VERSION" | sort -V | tail -1)"
MIXIN="$(pick "$LIB/org/spongepowered/mixin" 'mixin-*.jar')"

[ -n "${SRG:-}" ]     || die "找不到 client-${MC_VERSION}-*-srg.jar（MC_DIR 是否正确？）"
[ -n "${FORGE:-}" ]   || die "找不到 forge-*-universal.jar"
[ -n "${FMLCORE:-}" ] || die "找不到 fmlcore-*.jar"
[ -n "${JAVAFML:-}" ] || die "找不到 javafmllanguage-*.jar"
[ -n "${MIXIN:-}" ]   || die "找不到 mixin-*.jar"

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) SEP=';' ;;
    *)                    SEP=':' ;;
esac
CP="$SRG${SEP}$FORGE${SEP}$FMLCORE${SEP}$JAVAFML${SEP}$MIXIN"

echo "MC_DIR   : $MC_DIR"
echo "client   : $(basename "$SRG")"
echo "forge    : $(basename "$FORGE")"
echo "javafml  : $(basename "$JAVAFML")"
echo "mixin    : $(basename "$MIXIN")"
echo "version  : $VERSION"

BUILD="$ROOT/build/offline"
rm -rf "$BUILD"
mkdir -p "$BUILD/classes" "$ROOT/dist"

# shellcheck disable=SC2046
javac --release 17 -encoding UTF-8 -cp "$CP" -d "$BUILD/classes" \
    $(find "$ROOT/src/main/java" -name '*.java')

cp -R "$ROOT/src/main/resources/." "$BUILD/classes/"

printf 'Manifest-Version: 1.0\nMixinConfigs: %s.mixins.json\nImplementation-Version: %s\nFMLModType: MOD\n\n' \
    "$MOD_ID" "$VERSION" > "$BUILD/MANIFEST.MF"

OUT="$ROOT/dist/${MOD_ID}-${VERSION}.jar"
rm -f "$OUT"
jar --create --file "$OUT" --manifest "$BUILD/MANIFEST.MF" -C "$BUILD/classes" .

echo
echo "构建完成：$OUT"
unzip -l "$OUT"
