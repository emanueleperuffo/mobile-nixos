{ lib, fetchurl, runCommand }:

# Adreno 506 firmware for mido, mirroring what postmarketOS ships
# (`firmware-xiaomi-mido`).
#
# The ZAP (shader/secure-mode) firmware comes from the OEM firmware dump kept in
# Kiciuk/proprietary_firmware_mido at the same commit postmarketOS pins; the
# Adreno 506 microcode (a530_pm4.fw / a530_pfp.fw) is the generic A5xx
# microcode that the msm driver looks up under `qcom/` and is shipped by
# mainline linux-firmware.
let
  commit = "bc001cbb255a0ded2b58af07b93f712cd9322483";
  zap = file: sha256: fetchurl {
    url = "https://raw.githubusercontent.com/Kiciuk/proprietary_firmware_mido/${commit}/apnhlos/${file}";
    inherit sha256;
  };
  lf = file: sha256: fetchurl {
    url = "https://raw.githubusercontent.com/thesofproject/linux-firmware/master/qcom/${file}";
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
  cp ${lf "a530_pm4.fw" "6419f35956ec7307af83723fedfba752520bacd8389eda0d0120e185e4cb1d3f"} \
     $out/lib/firmware/qcom/a530_pm4.fw
  cp ${lf "a530_pfp.fw" "ed2c860ae56c5061d630b40cbe0aae6b0c4c4d0422b91b838973fbee66a3b00e"} \
     $out/lib/firmware/qcom/a530_pfp.fw
''