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
          FW=/lib/firmware

          # Copy (not symlink) the firmware into /lib/firmware as real files.
          # The kernel's request_firmware reliably finds files there (the
          # firmware_class.path=/run/firmware path does not traverse the
          # partition-mounted symlinks, and it races with module autoload at
          # boot), and the WCNSS PIL/NV expect specific subpaths:
          #   wcnss.mdt / modem.mdt / mba.mbn / adsp.mdt  -> /lib/firmware/
          #   WCNSS_qcom_wlan_nv.bin, ...                 -> /lib/firmware/wlan/prima/
          mkdir -p "$FW/wlan/prima"
          for f in wcnss modem mba adsp; do
            cp -a "$fwdir/modem/image/$f"* "$FW/" 2>/dev/null || true
          done
          cp -a "$fwdir/persist/WCNSS_qcom_wlan_nv.bin"    "$FW/wlan/prima/"
          cp -a "$fwdir/persist/WCNSS_wlan_dictionary.dat" "$FW/wlan/prima/"
          cp -a ${wcnssCfg} "$FW/wlan/prima/WCNSS_qcom_cfg.ini"

          # (Re)load the remoteproc drivers and wcn36xx now that the firmware is
          # in place. Note: systemd services have a restricted PATH, so use the
          # full path to modprobe.
          ${pkgs.kmod}/bin/modprobe qcom_q6v5_mss || true
          ${pkgs.kmod}/bin/modprobe wcn36xx || true

          # Kick the remoteprocs that probed-and-failed at boot (before the
          # firmware was available) so they now load wcnss.mdt / mba.mbn /
          # modem.mdt. Failures are ignored (e.g. the modem needs rmtfs first).
          for r in /sys/class/remoteproc/*/; do
            echo start > "$r/state" 2>/dev/null || true
          done
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
