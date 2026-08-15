{ lib, fetchurl, runCommand }:

# Adreno 506 ZAP (shader) firmware, mirroring what postmarketOS ships for mido
# (`firmware-xiaomi-mido`). Sourced from the OEM firmware dump kept in
# Kiciuk/proprietary_firmware_mido at the same commit postmarketOS pins.
let
  commit = "bc001cbb255a0ded2b58af07b93f712cd9322483";
  zap = file: sha256: fetchurl {
    url = "https://raw.githubusercontent.com/Kiciuk/proprietary_firmware_mido/${commit}/apnhlos/${file}";
    inherit sha256;
  };
in
runCommand "xiaomi-mido-firmware" {
  meta.license = lib.licenses.unfreeRedistributableFirmware;
} ''
  mkdir -p $out/lib/firmware/qcom
  cp ${zap "a506_zap.mdt" "d0de0d49b2a24009f939dff77094d2628e272c04b86de0ebe49db508fe6d0967"} \
     $out/lib/firmware/qcom/a506_zap.mdt
  cp ${zap "a506_zap.b02" "fe8dead286927c662da0769589c739f914c130271429701606bd7662e91930fd"} \
     $out/lib/firmware/qcom/a506_zap.b02
''