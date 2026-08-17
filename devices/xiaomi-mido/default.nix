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

  midoKernelPackage = config.mobile.boot.stage-1.kernel.package;

  midoDTB = "${midoKernelPackage}/dtbs/qcom/msm8953-xiaomi-mido.dtb";

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
      # Adreno 506 (GPU/DRM) firmware: ZAP shader + a530 microcode, stage-1.
      (pkgs.callPackage ./firmware { })
    ];

    # Wireless regulatory database for cfg80211 (Wi-Fi channels/TX power per
    # country). Wired into the rootfs /lib/firmware so the kernel can find it.
    hardware.firmware = [
      pkgs.wireless-regdb
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
      "uinput"              # virtual input devices (mido-navkeys)
    ];

    mobile.boot.stage-1.extraUtils = with pkgs; [
      gptfdisk
    ];

    # SSH server in the initrd, reachable over the USB RNDIS gadget.
    # WARNING: initrd-ssh.nix clears the root password and starts dropbear with
    # empty-password login and no key auth. It exists as a bring-up/debug tool;
    # anyone with physical USB access gets root. Remove this once debugging is
    # done (it only takes effect after a boot.img rebuild + reflash).
    mobile.boot.stage-1.ssh.enable = true;
    mobile.boot.stage-1.networking.enable = true;

    networking.networkmanager = {
      enable = true;
      wifi.backend = "iwd";
    };

    # Power button short-press is ignored: binding it to suspend caused a hang
    # (watchdog reset) on this kernel, while a manual `systemctl suspend`
    # suspends/resumes reliably. Sleep with `systemctl suspend`, wake with the
    # power button.
    services.logind.settings.Login.HandlePowerKey = "ignore";
    # Long-press power keeps the logind default (poweroff) — an explicit escape
    # hatch to shut the device down.
    services.logind.settings.Login.HandlePowerKeyLongPress = "poweroff";

    # Use the schedutil CPU frequency governor instead of the kernel default
    # (performance). Applied via the cpufreq oneshot at multi-user.target.
    powerManagement.cpuFreqGovernor = "schedutil";

    # -- Display backlight / screen controls (manual, over adb/shell) --
    # mido drives the panel through DRM (msm), so `/sys/class/graphics/fb0/blank`
    # is only the legacy fbdev shim and is NOT wired to the real display
    # (it may read 4/powerdown while the screen is visibly on). Ignore it.
    #
    # The backlight sysfs device on mido is `backlight`; it is the actual
    # visible-brightness control and the reliable way to blank the screen.
    #
    # Lower brightness (set an absolute value out of max_brightness):
    #   cat /sys/class/backlight/backlight/max_brightness
    #   echo 50 | tee /sys/class/backlight/backlight/brightness
    #
    # Turn the screen off (backlight to 0):
    #   echo 0 | tee /sys/class/backlight/backlight/brightness
    # Back on (restore a value <= max_brightness):
    #   cat /sys/class/backlight/backlight/max_brightness
    #   echo 200 | tee /sys/class/backlight/backlight/brightness
    #
    # Sleep (screen off + low power, wake with the power button):
    #   systemctl suspend

    networking.modemmanager.enable = true;

    systemd.services.ModemManager = {
      # ModemManager is otherwise only D-Bus-activated; pull it into normal
      # boot so it is up and probing the QRTR modem on every start.
      wantedBy = [ "multi-user.target" ];
      after = [ "qrtr-ns.service" "rmtfs.service" "mobile-msm8953-firmware.service" ];
      requires = [ "mobile-msm8953-firmware.service" ];
      # The modem can take a moment to show up on QRTR after the remoteproc
      # boots; keep retrying so ModemManager reliably comes up on every boot.
      serviceConfig = {
        Restart = "always";
        RestartSec = "2s";
      };
    };

    # The FT5x06 touchscreen exposes the bottom capacitive nav-button strip as
    # ordinary touch coordinates (there are no real KEY_BACK/HOME/MENU events).
    # Translate bottom-strip touch-downs into key events via uinput.
    systemd.services.mido-navkeys = {
      description = "mido nav-button to key translation";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.callPackage ./navkeys { }}/bin/mido-navkeys";
        Restart = "always";
        RestartSec = "2s";
      };
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
