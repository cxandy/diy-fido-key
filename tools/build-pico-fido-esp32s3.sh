#!/bin/sh
# Build pico-fido for the ESP32-S3 board and emit a merged image.
# Requires ESP-IDF v5.5.1 exported in the environment (idf.py on PATH).
#
#   SKIP_LCD=1                  build without the ST7735 status display
#   SPIRAM_MODE=oct|quad|none   PSRAM flavour (default: oct, as on the
#                               reference board; `none` without PSRAM)
#
# The image is plaintext: this script never writes eFuses and refuses to build
# if secure boot or flash encryption is enabled in sdkconfig.
set -e

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SRC="$ROOT/vendor/pico-fido"
BUILD="$ROOT/build/pico-fido-esp32s3"
SKIP_LCD=${SKIP_LCD:-0}
SPIRAM_MODE=${SPIRAM_MODE:-oct}

case "$SPIRAM_MODE" in
    oct|quad|none) ;;
    *)
        echo "SPIRAM_MODE must be oct, quad or none" >&2
        exit 2
        ;;
esac

if [ ! -d "$SRC/pico-keys-sdk" ]; then
    echo "vendor/pico-fido is missing; clone it first (see README)." >&2
    exit 1
fi
if ! command -v idf.py >/dev/null 2>&1; then
    echo "idf.py not found; run '. ~/esp/esp-idf-v5.5.1/export.sh' first." >&2
    exit 1
fi

if [ "$SKIP_LCD" = "1" ]; then
    echo "SKIP_LCD=1: building without the status display"
else
    # Reproducible local patches: LCD status UI + PSRAM shadow for the
    # credential partition (the latter only matters with flash encryption).
    sh "$ROOT/tools/install-esp32-lcd.sh"
fi

# ESP-IDF only loads a component's Kconfig when the component is part of the
# build. The LCD patch adds esp_psram as a dependency; without the panel we
# must add it ourselves, otherwise CONFIG_SPIRAM does not exist as a symbol
# and the settings below are silently dropped.
if [ "$SPIRAM_MODE" != "none" ]; then
    COMP="$SRC/pico-keys-sdk/config/esp32/components/pico-keys-sdk/CMakeLists.txt"
    if ! grep -q 'esp_psram' "$COMP"; then
        perl -0pi -e 's{(\n\s*mbedtls\n\))}{\n    mbedtls\n    esp_psram\n)}' "$COMP"
    fi
    if ! grep -q 'esp_psram' "$COMP"; then
        echo "failed to add esp_psram to the pico-keys-sdk component" >&2
        exit 1
    fi
fi

: "${FIDO_USB_VID:=0x2E8A}"
: "${FIDO_USB_PID:=0x10FE}"

# set-target regenerates sdkconfig from sdkconfig.defaults, so every setting
# below must be applied afterwards. Doing it before would be silently lost on
# a fresh checkout, keeping QIO flash mode and the USB-Serial/JTAG console.
idf.py -B "$BUILD" -C "$SRC" -DUSB_VID="$FIDO_USB_VID" -DUSB_PID="$FIDO_USB_PID" set-target esp32s3

python3 - "$SRC/sdkconfig" "$SPIRAM_MODE" <<'PY'
import sys

path, spiram = sys.argv[1], sys.argv[2]
text = open(path).read()


def set_sym(text, name, value=None):
    lines = [l for l in text.splitlines()
             if not l.startswith(name + '=') and l != '# %s is not set' % name]
    if value is None:
        lines.append('# %s is not set' % name)
    else:
        lines.append('%s=%s' % (name, value))
    return '\n'.join(lines) + '\n'


# The USB Serial/JTAG console shares GPIO19/20 with USB-OTG. Leaving the
# secondary console enabled makes the firmware watchdog-loop before TinyUSB
# can enumerate the FIDO HID interface.
text = set_sym(text, 'CONFIG_ESP_CONSOLE_SECONDARY_NONE', 'y')
text = set_sym(text, 'CONFIG_ESP_CONSOLE_SECONDARY_USB_SERIAL_JTAG', None)
text = set_sym(text, 'CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG_ENABLED', None)

# DIO matches the upstream build and is the only mode verified on the board.
text = set_sym(text, 'CONFIG_ESPTOOLPY_FLASHMODE_QIO', None)
text = set_sym(text, 'CONFIG_ESPTOOLPY_FLASHMODE_DIO', 'y')
text = set_sym(text, 'CONFIG_ESPTOOLPY_FLASHMODE', '"dio"')

if spiram == 'none':
    for sym in ('CONFIG_SPIRAM', 'CONFIG_SPIRAM_MODE_OCT', 'CONFIG_SPIRAM_MODE_QUAD',
                'CONFIG_SPIRAM_SPEED_80M', 'CONFIG_SPIRAM_SPEED_40M'):
        text = set_sym(text, sym, None)
else:
    text = set_sym(text, 'CONFIG_SPIRAM', 'y')
    text = set_sym(text, 'CONFIG_SPIRAM_MODE_OCT', 'y' if spiram == 'oct' else None)
    text = set_sym(text, 'CONFIG_SPIRAM_MODE_QUAD', 'y' if spiram == 'quad' else None)
    text = set_sym(text, 'CONFIG_SPIRAM_SPEED_80M', 'y' if spiram == 'oct' else None)
    text = set_sym(text, 'CONFIG_SPIRAM_SPEED_40M', 'y' if spiram == 'quad' else None)
    text = set_sym(text, 'CONFIG_SPIRAM_USE_MALLOC', 'y')
    text = set_sym(text, 'CONFIG_SPIRAM_BOOT_INIT', 'y')
    text = set_sym(text, 'CONFIG_SPIRAM_IGNORE_NOTFOUND', 'y')

open(path, 'w').write(text)
PY

SDKCONFIG="$SRC/sdkconfig"
print_cfg() {
    grep -E '^CONFIG_(SPIRAM|SPIRAM_MODE|SPIRAM_SPEED|ESP_CONSOLE_SECONDARY_NONE|ESPTOOLPY_FLASHMODE)' "$SDKCONFIG" || true
}
echo "sdkconfig after edit:"
print_cfg

idf.py -B "$BUILD" -C "$SRC" -DUSB_VID="$FIDO_USB_VID" -DUSB_PID="$FIDO_USB_PID" build

echo "sdkconfig after build:"
print_cfg

# Never emit an image that could burn eFuses (or change the boot chain) on
# first boot. security-profiles.sh is the only supported way to do that.
for sym in CONFIG_SECURE_BOOT CONFIG_SECURE_FLASH_ENC_ENABLED; do
    if grep -q "^$sym=y" "$SDKCONFIG"; then
        echo "refusing to build: $sym is enabled in sdkconfig" >&2
        exit 1
    fi
done
if ! grep -q '^CONFIG_ESPTOOLPY_FLASHMODE_DIO=y' "$SDKCONFIG"; then
    echo "refusing to build: DIO flash mode was not applied to sdkconfig" >&2
    exit 1
fi
if ! grep -q '^CONFIG_ESP_CONSOLE_SECONDARY_NONE=y' "$SDKCONFIG"; then
    echo "refusing to build: the USB-Serial/JTAG secondary console is still enabled" >&2
    exit 1
fi
if [ "$SPIRAM_MODE" = "none" ]; then
    if grep -q '^CONFIG_SPIRAM=y' "$SDKCONFIG"; then
        echo "refusing to build: CONFIG_SPIRAM is enabled for SPIRAM_MODE=none" >&2
        exit 1
    fi
else
    if ! grep -q '^CONFIG_SPIRAM=y' "$SDKCONFIG"; then
        echo "refusing to build: CONFIG_SPIRAM was dropped for SPIRAM_MODE=$SPIRAM_MODE" >&2
        exit 1
    fi
    if [ "$SPIRAM_MODE" = "oct" ] && ! grep -q '^CONFIG_SPIRAM_MODE_OCT=y' "$SDKCONFIG"; then
        echo "refusing to build: octal PSRAM mode was dropped from sdkconfig" >&2
        exit 1
    fi
fi

{
    echo "flash_mode=dio"
    echo "spiram=$SPIRAM_MODE"
    echo "lcd=$([ "$SKIP_LCD" = "1" ] && echo off || echo on)"
    echo "secure_boot=off"
    echo "flash_encryption=off"
    # Actual values taken from the generated sdkconfig.
    print_cfg | sed 's/^/sdkconfig: /'
} > "$BUILD/build-config.txt"

esptool --chip esp32s3 merge-bin \
    -o "$BUILD/pico_fido_full.bin" \
    --flash-mode dio --flash-freq 80m --flash-size 4MB \
    0x0 "$BUILD/bootloader/bootloader.bin" \
    0x8000 "$BUILD/partition_table/partition-table.bin" \
    0x20000 "$BUILD/pico_fido.bin"

echo "Merged image: $BUILD/pico_fido_full.bin"
echo "Flash: hold BOOT (GPIO0) while plugging in, then:"
echo "  esptool --chip esp32s3 --port /dev/cu.usbmodemXXXX write-flash 0x0 $BUILD/pico_fido_full.bin"
echo "After flashing, release BOOT and replug."
