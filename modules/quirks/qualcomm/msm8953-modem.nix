{ config, lib, pkgs, ... }:

# Connectivity support for msm8953-mainline devices (Wi-Fi via WCNSS/wcn36xx
# and the cellular modem).
#
# The proprietary firmware is NOT embedded in the image. Instead the stock
# `modem` (FAT16) and `persist` (ext4) partitions are mounted read-only at
# runtime and exposed to the kernel through `firmware_class.path=/run/firmware`.
#
#   modem partition  -> /run/firmware/modem/image/*   (modem.mdt, wcnss.mdt, adsp.mdt, ...)
#   persist partition-> /run/firmware/persist/        (WCNSS_qcom_wlan_nv.bin, ...)
#
# Only `WCNSS_qcom_cfg.ini` (a small, redistributable config) is provided from
# the Nix store; everything else stays on the device's own partitions.

let
  cfg = config.mobile.quirks.qualcomm.msm8953-modem;
  inherit (lib) mkIf mkOption types;

  # Wi-Fi configuration file, taken from the LineageOS mido device tree. The
  # prima/WCNSS driver and wcn36xx expect this alongside the WLAN NV blob.
  wcnssCfg = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/LineageOS/android_device_xiaomi_mido/cm-14.1/wifi/WCNSS_qcom_cfg.ini";
    sha256 = "1678w9zw43kf0nl2hfvsgn8srram8f027hhhs4nkg4c1n31r12wa";
  };
in
{
  options.mobile.quirks.qualcomm.msm8953-modem.enable = mkOption {
    type = types.bool;
    default = false;
    description = ''
      Enable connectivity support for msm8953-mainline devices (Wi-Fi via
      WCNSS/wcn36xx and the cellular modem).

      Mounts the stock `modem` and `persist` partitions read-only and exposes
      their firmware through `firmware_class.path`, then runs the modem
      userspace stack (qrtr, rmtfs).

      The firmware is loaded from the device's own partitions at runtime; it is
      not embedded in the image.
    '';
  };

  config = mkIf cfg.enable {
    boot.kernelParams = [
      "firmware_class.path=/run/firmware"
    ];

    boot.specialFileSystems = {
      "/run/firmware/modem" = {
        device = "/dev/disk/by-partlabel/modem";
        fsType = "vfat";
        options = [ "ro" "nosuid" "noexec" "nodev" ];
      };
      "/run/firmware/persist" = {
        device = "/dev/disk/by-partlabel/persist";
        fsType = "ext4";
        options = [ "ro" "nosuid" "noexec" "nodev" ];
      };
    };

    systemd.services = {
      # Surface the partition firmware at the names the kernel drivers request,
      # before the modem/Wi-Fi stacks come up.
      mobile-msm8953-firmware = {
        description = "Expose msm8953 modem/WCNSS firmware to the kernel";
        wantedBy = [ "multi-user.target" ];
        before = [ "qrtr-ns.service" "rmtfs.service" "ModemManager.service" "NetworkManager.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -eu
          fwdir=/run/firmware
          # modem + wcnss + adsp firmware live under `image/` on the modem partition
          for f in "$fwdir/modem/image/"*; do
            ln -sfn "$f" "$fwdir/$(basename "$f")"
          done
          # Wi-Fi NV + dictionary live at the root of the persist partition
          ln -sfn "$fwdir/persist/WCNSS_qcom_wlan_nv.bin"    "$fwdir/WCNSS_qcom_wlan_nv.bin"
          ln -sfn "$fwdir/persist/WCNSS_wlan_dictionary.dat" "$fwdir/WCNSS_wlan_dictionary.dat"
          # Small redistributable config, shipped from the Nix store
          ln -sfn ${wcnssCfg} "$fwdir/WCNSS_qcom_cfg.ini"
          # Trigger the (modular) remoteproc drivers now that their firmware is
          # visible; loading the modules also starts the respective remoteprocs.
          modprobe wcn36xx || true
          modprobe qcom_q6v5_mss || true
        '';
      };

      qrtr-ns = {
        serviceConfig = {
          ExecStart = "${pkgs.qrtr}/bin/qrtr-ns -f 1";
          Restart = "always";
        };
      };

      rmtfs = {
        wantedBy = [ "multi-user.target" ];
        requires = [ "qrtr-ns.service" ];
        after = [ "qrtr-ns.service" ];
        serviceConfig = {
          # TODO: msm8953's rmtfs region source (partition vs directory) needs
          # to be validated on-device; `-P` reads the modem's memory regions
          # from a partition.
          ExecStart = "${pkgs.rmtfs}/bin/rmtfs -s -r -P";
          Restart = "always";
          RestartSec = "1";
        };
      };
    };
  };
}
