{ config, lib, pkgs, ... }:

{
  imports = [
    ./sound.nix
  ];

  mobile.hardware = {
    soc = "qualcomm-msm8953";
    # The msm8953-mainline family spans Snapdragon 625/450/632 devices with
    # differing RAM; devices are expected to override.
    ram = lib.mkDefault (1024 * 3);
    screen = {
      width = 1080; height = 1920;
    };
  };

  mobile.boot.stage-1.kernel = {
    # mkDefault so devices can point the family kernel at their own config
    # (e.g. xiaomi-mido uses a trimmed per-device config.aarch64).
    package = lib.mkDefault (pkgs.callPackage ./kernel { });
    modular = true;
  };

  mobile.kernel.structuredConfig = [
    (helpers: with helpers; {
      # PMI8950 fuel gauge driver (binds qcom,pmi8996-fg -> mido's
      # fuel-gauge@4000) exposes battery capacity/voltage/current/temp.
      BATTERY_PMI8994_FG = yes;

      # Vibrator: mido's &pmi8950_haptics is enabled in the DT, so the
      # Qualcomm SPMI haptics driver must be built or there is no haptic
      # feedback (vibrations on tap/etc.).
      INPUT_QCOM_SPMI_HAPTICS = yes;

      # IR blaster: mido has a pwm-ir-tx node (used as a TV/remote
      # transmitter). It needs the RC core + LIRC (raw IR userland, a
      # dependency of IR_PWM_TX). The PWM itself is provided by the LPG
      # driver (qcom,pmi8950-pwm) which is already enabled as a module.
      # RC_DEVICES is the menu that contains IR_PWM_TX; without it oldconfig
      # drops the transmitter symbol.
      RC_CORE = yes;
      RC_DEVICES = yes;
      LIRC = yes;
      IR_PWM_TX = yes;

      CC_OPTIMIZE_FOR_PERFORMANCE = no;
      CC_OPTIMIZE_FOR_SIZE = yes;
    })
  ];

  mobile.quirks.qualcomm.msm8953-modem = {
    enable = true;
  };

  mobile.system.type = "android";
  mobile.system.android = {
    bootimg.flash = {
      offset_base = "0x80000000";
      offset_kernel = "0x00008000";
      offset_ramdisk = "0x01000000";
      offset_second = "0x00f00000";
      offset_tags = "0x00000100";
      pagesize = "2048";
    };
  };
  mobile.system.android.flashingMethod = "lk2nd";

  mobile.usb = {
    mode = "gadgetfs";
    idVendor = "18D1";  # Google
    idProduct = "4EE7"; # distinguish from the fastboot/lk2nd default

    gadgetfs.functions = {
      rndis = "rndis.usb0";
      adb = "ffs.adb";
    };
  };
}
