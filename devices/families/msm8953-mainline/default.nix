{ config, lib, pkgs, ... }:

{
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
    package = (pkgs.callPackage ./kernel { });
    modular = true;
  };

  mobile.kernel.structuredConfig = [
    (helpers: with helpers; {
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
