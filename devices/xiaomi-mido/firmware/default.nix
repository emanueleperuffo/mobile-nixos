{ lib, fetchurl, runCommand, linux-firmware }:

# Adreno 506 firmware for mido, mirroring what postmarketOS ships
# (`firmware-xiaomi-mido`).
#
# The generic A5xx microcode (a530_pm4.fw / a530_pfp.fw) that the msm driver
# looks up under `qcom/` is taken straight from `pkgs.linux-firmware` (which
# carries the 2020-09-08 updated PFP microcode fixing GPU bugs, and is kept
# current by NixOS itself), so no manual pinning/fetching is needed.
#
# The ZAP (shader/secure-mode) firmware is mido-specific and absent from
# linux-firmware, so it comes from the OEM firmware dump kept in
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
  cp ${linux-firmware}/lib/firmware/qcom/a530_pm4.fw \
     $out/lib/firmware/qcom/a530_pm4.fw
  cp ${linux-firmware}/lib/firmware/qcom/a530_pfp.fw \
     $out/lib/firmware/qcom/a530_pfp.fw
''
