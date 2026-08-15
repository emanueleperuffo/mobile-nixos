{ config, lib, pkgs, ... }:

let
  inherit (lib) mkDefault;

  # The kernel DTB ships with the touch controller nodes (both FocalTech and
  # Goodix) disabled. lk2nd used by this device does not enable them at boot,
  # so we enable the node matching the physical controller at build time.
  # The nodes live on the BLSP1 I2C-3 bus; addresses come from the msm8953
  # xiaomi-common device tree:
  #   touchscreen@38 -> FocalTech FT5435 (edt,edt-ft5406, driver: edt-ft5x06)
  #   touchscreen@5d -> Goodix GT917D  (goodix,gt917d,  driver: goodix)
  touchscreenNode =
    if config.mobile.hardware.touchscreen == "goodix"
    then "touchscreen@5d"
    else "touchscreen@38";

  midoDTB = "${config.mobile.boot.stage-1.kernel.package}/dtbs/qcom/msm8953-xiaomi-mido.dtb";

  # NOTE: This build-time patch is a stopgap for the lk2nd rev pinned in this
  # repo (msm8953-mainline/lk2nd @ 5912c91), which does not enable a touchscreen
  # at boot. Upstream mainline lk2nd (msm8916-mainline) instead detects the
  # panel at runtime and sets `touchscreen-compatible` on the DT it passes to
  # Linux. If we ever switch to such an lk2nd, this patching (and the
  # `mobile.hardware.touchscreen` override below) becomes redundant for the
  # FocalTech case and can be dropped.
  #
  # Caveat: mainline lk2nd maps *every* mido panel to the FocalTech controller
  # (edt,edt-ft5406), so a Goodix-controller mido is not auto-detected even
  # there. Keep this option (or provide a custom lk2nd) if you need the Goodix
  # variant, since that case has no automatic path in upstream either.
  #
  # Enable the selected touch controller in the appended DTB.
  patchedMidoDTB = pkgs.runCommand "msm8953-xiaomi-mido-touchscreen.dtb" {
    nativeBuildInputs = [ pkgs.buildPackages.dtc ];
    baseDTB = midoDTB;
    inherit touchscreenNode;
  } ''
    cat > overlay.dts <<EOF
    /dts-v1/;
    /plugin/;
    &{/soc@0/i2c@78b7000/$touchscreenNode} {
        status = "okay";
    };
    EOF
    dtc -@ -I dts -O dtb -o overlay.dtbo overlay.dts
    fdtoverlay -i "$baseDTB" -o "$out" overlay.dtbo
  '';
in
{
  imports = [
    ../families/msm8953-mainline
  ];

  config = {
    mobile.hardware.touchscreen = mkDefault "focaltech";

    mobile.device.name = "xiaomi-mido";
    mobile.device.identity = {
      name = "Redmi Note 4";
      manufacturer = "Xiaomi";
    };
    # Untested on real hardware, yet.
    mobile.device.supportLevel = "best-effort";

    mobile.hardware = {
      # mido ships in both 3GB and 4GB variants; the family default (3GB) is
      # intentionally weak so either can be overridden cleanly in configuration.nix.
      screen = {
        width = 1080; height = 1920;
      };
    };

    mobile.boot.stage-1.firmware = [
      # Adreno 506 ZAP shader firmware, needed for the GPU/DRM driver in stage-1.
      (pkgs.callPackage ./firmware { })
    ];

    mobile.boot.stage-1.kernel.modules = [
      "qcom-pon"              # power and volume down keys
      "goodix-ts"             # touchscreen (goodix,gt917d variant)
      "edt-ft5x06"            # touchscreen (focaltech FT5435 variant)
      "msm"                   # DRM module
      # mido ships with several possible panels; only one is probed at runtime.
      "panel-xiaomi-boe-ili9885"
      "panel-xiaomi-ebbg-r63350"
      "panel-xiaomi-nt35532"
      "panel-xiaomi-otm1911"
      "panel-xiaomi-tianma-nt35596"
      # Backlight and LEDs
      "pwm-bl"
      "leds-qcom-lpg"
      "qcom-pbs"
    ];

    networking.networkmanager = {
      enable = true;
      wifi.backend = "iwd";
    };

    networking.modemmanager.enable = true;

    systemd.services.ModemManager = {
      after = [ "qrtr-ns.service" "mobile-msm8953-firmware.service" ];
      requires = [ "mobile-msm8953-firmware.service" ];
    };

    # The stock Android `system` partition is repurposed to hold the stage-1
    # `boot.img` (kernel + initrd) for lk2nd, which is too large for the `boot`
    # partition. The root filesystem therefore goes on the larger `userdata`
    # partition. Keeping this in sync with the lk2nd install instructions.
    mobile.system.android.system_partition_destination = "userdata";

    mobile.system.android.appendDTB = [
      patchedMidoDTB
    ];
  };
}
