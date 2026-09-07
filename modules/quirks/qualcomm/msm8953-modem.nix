{ config, lib, pkgs, ... }:

# Connectivity support for msm8953-mainline devices (Wi-Fi via WCNSS/wcn36xx
# and the cellular modem).
#
# The proprietary firmware is NOT embedded in the image. Instead the stock
# `modem` (FAT16) and `persist` (ext4) partitions are mounted read-only at
# boot (mounted below /run/mnt by the stage-1 init, which creates the
# mountpoints) and copied into /lib/firmware, the kernel's default firmware
# search path.
#
#   modem partition  -> /run/mnt/modem/image/*   (modem.mdt, wcnss.mdt, adsp.mdt, ...)
#   persist partition-> /run/mnt/persist/         (WCNSS_qcom_wlan_nv.bin, ...)
#
# Only `WCNSS_qcom_cfg.ini` (a small, redistributable config) is provided from
# the Nix store; everything else stays on the device's own partitions.

let
  cfg = config.mobile.quirks.qualcomm.msm8953-modem;
  inherit (lib) mkIf mkOption types;

  # Wi-Fi configuration file, taken from the LineageOS mido device tree. The
  # prima/WCNSS driver and wcn36xx expect this alongside the WLAN NV blob.
  #
  # The file is chip-generic (any device with the same WCNSS chip works), not
  # board-specific, and it is a small redistributable text config — so it is
  # shipped from the Nix store rather than loaded from a device partition.
  # (mido has no `vendor` partition; on stock Android this file lived inside
  # `/system/vendor`, and `system` is repurposed for boot here.)
  #
  # The file is shipped unmodified from the LineageOS mido device tree (stock
  # BMPS setting).
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

      Mounts the stock `modem` and `persist` partitions read-only (below
      `/run/mnt`, at boot) and copies their firmware into `/lib/firmware`, then
      runs the modem userspace stack (qrtr, rmtfs).

      The firmware is loaded from the device's own partitions at runtime; it is
      not embedded in the image.
    '';
  };

  config = mkIf cfg.enable {
    # Mounted very early (stage-1); the stage-1 init creates the mountpoints
    # (including /run/mnt) before mounting.
    boot.specialFileSystems = {
      "/run/mnt/modem" = {
        device = "/dev/disk/by-partlabel/modem";
        fsType = "vfat";
        options = [ "ro" "nosuid" "noexec" "nodev" ];
      };
      "/run/mnt/persist" = {
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
          FW=/lib/firmware

          # Copy (not symlink) the firmware into /lib/firmware as real files,
          # the kernel's default firmware search path
          # The WCNSS PIL/NV expect specific subpaths:
          #   wcnss.mdt / modem.mdt / mba.mbn / adsp.mdt  -> /lib/firmware/
          #   WCNSS_qcom_wlan_nv.bin, ...                 -> /lib/firmware/wlan/prima/
          mkdir -p "$FW/wlan/prima"
          for f in wcnss modem mba adsp; do
            cp -a "/run/mnt/modem/image/$f"* "$FW/" 2>/dev/null || true
          done
          cp -a "/run/mnt/persist/WCNSS_qcom_wlan_nv.bin"    "$FW/wlan/prima/"
          cp -a "/run/mnt/persist/WCNSS_wlan_dictionary.dat" "$FW/wlan/prima/"
          cp -a ${wcnssCfg} "$FW/wlan/prima/WCNSS_qcom_cfg.ini"

          # (Re)load the remoteproc drivers and wcn36xx now that the firmware is
          # in place. Note: systemd services have a restricted PATH, so use the
          # full path to modprobe.
          ${pkgs.kmod}/bin/modprobe qcom_q6v5_mss || true
          ${pkgs.kmod}/bin/modprobe wcn36xx || true

          # (Re)start the auto-booting DSPs (adsp/wcnss) that may have probed
          # before the firmware was in place. The modem (qcom-q6v5-mss) is
          # deliberately excluded here: it must not boot before rmtfs is
          # serving its EFS/NV, so it is started by mobile-msm8953-modem.service
          # instead. Failures are ignored.
          for r in /sys/class/remoteproc/remoteproc*/; do
            drv=$(readlink -f "$r/device/driver" 2>/dev/null || true)
            case "$drv" in */qcom-q6v5-mss) continue ;; esac
            state=$(cat "$r/state" 2>/dev/null || true)
            [ "$state" = running ] && continue
            echo start > "$r/state" 2>/dev/null || true
          done
        '';
      };

      # Start the modem (mss) remoteproc. Unlike adsp/wcnss it does not
      # auto-boot from its driver, and it must not be started by the firmware
      # service above: the modem firmware asks rmtfs for its EFS/NV shortly
      # after booting, so starting it before rmtfs is up would race it.
      mobile-msm8953-modem = {
        description = "Start the msm8953 modem remoteproc";
        wantedBy = [ "multi-user.target" ];
        requires = [ "mobile-msm8953-firmware.service" "rmtfs.service" ];
        after = [ "mobile-msm8953-firmware.service" "rmtfs.service" ];
        before = [ "msm-modem-uim-selection.service" "ModemManager.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -eu
          for r in /sys/class/remoteproc/remoteproc*/; do
            drv=$(readlink -f "$r/device/driver" 2>/dev/null || true)
            case "$drv" in */qcom-q6v5-mss) : ;; *) continue ;; esac
            state=$(cat "$r/state" 2>/dev/null || true)
            [ "$state" = running ] && continue
            # A crashed instance must be stopped before it can be restarted.
            [ "$state" = crashed ] && echo stop > "$r/state" 2>/dev/null || true
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
          # `-P` serves the modem's EFS/NV from the raw modemst1/modemst2/fsc/
          # fsg partitions (resolved by partlabel), `-r` keeps them read-only
          # (writes go to a shadow buffer), `-s` stops the modem cleanly when
          # the service shuts down.
          ExecStart = "${pkgs.rmtfs}/bin/rmtfs -s -r -P";
          Restart = "always";
          RestartSec = "1";
        };
      };

      # The modem does not create a primary-GW UIM provisioning session by
      # itself (on stock Android the RIL does this on every boot). Without one,
      # ModemManager's unlock-status check reports "no card" and parks the
      # modem in a failed/sim-missing state. Activate the session for the first
      # slot holding a card (same approach as the sdm845 qualcomm module)
      # before MM starts. Only runs when ModemManager is enabled.
      msm-modem-uim-selection = {
        enable = true;
        before = [ "ModemManager.service" ];
        wantedBy = [ "ModemManager.service" ];
        requires = [ "mobile-msm8953-modem.service" ];
        after = [ "mobile-msm8953-modem.service" "rmtfs.service" ];
        path = with pkgs; [ libqmi gawk ];
        script = ''
          QMICLI_MODEM="qmicli --silent -pd qrtr://0"

          # The modem takes a few seconds after remoteproc start to register on
          # QRTR and bring UIM up; wait for the card status to answer (bounded).
          i=0
          while [ $i -lt 30 ]; do
            if QMI_CARDS=$($QMICLI_MODEM --uim-get-card-status 2>/dev/null); then
              break
            fi
            i=$((i + 1))
            sleep 2
          done

          # No answer within the timeout: leave MM to its own retry loop.
          [ -n "$QMI_CARDS" ] || exit 0

          # If a session already exists, drop it first so the activation below
          # starts from a clean state.
          if ! printf "%s" "$QMI_CARDS" | grep -Fq "Primary GW:   session doesn't exist"; then
            $QMICLI_MODEM --uim-change-provisioning-session='activate=no,session-type=primary-gw-provisioning' >/dev/null 2>&1 || true
          fi

          FIRST_PRESENT_SLOT=$(printf "%s" "$QMI_CARDS" | grep "Card state: 'present'" -m1 -B1 | head -n1 | cut -c7-7)
          FIRST_PRESENT_AID=$(printf "%s" "$QMI_CARDS" | grep "usim (2)" -m1 -A3 | tail -n1 | awk '{print $1}')

          if [ -n "$FIRST_PRESENT_SLOT" ] && [ -n "$FIRST_PRESENT_AID" ]; then
            $QMICLI_MODEM --uim-change-provisioning-session="slot=$FIRST_PRESENT_SLOT,activate=yes,session-type=primary-gw-provisioning,aid=$FIRST_PRESENT_AID"
          fi
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
      };

      # Shape ModemManager's behaviour *if* the owner activates it. MM is
      # deliberately NOT enabled here (`networking.modemmanager.enable` is left
      # to the device/owner): when they do enable it, this makes sure it is up
      # early and probing the QRTR modem on every boot (it is otherwise only
      # D-Bus-activated), and keeps retrying until the modem shows up after the
      # remoteproc boots.
      ModemManager = {
        wantedBy = [ "multi-user.target" ];
        after = [ "qrtr-ns.service" "rmtfs.service" "mobile-msm8953-firmware.service" "mobile-msm8953-modem.service" "msm-modem-uim-selection.service" ];
        requires = [ "mobile-msm8953-firmware.service" ];
        serviceConfig = {
          Restart = "always";
          RestartSec = "2s";
        };
      };
    };
  };
}
