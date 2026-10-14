{ lib, pkgs, ... }:

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
      # KVM can never work: the signed TZ firmware keeps the CPU at EL1 and
      # msm8953 has no separate `hyp` partition to replace (see the mido
      # README's "Virtualization (KVM)" — same finding for the whole platform,
      # e.g. the Redmi 6 Pro). VIRTIO is intentionally not listed here: the
      # modem stack (REMOTEPROC/RPMSG for QRTR/GLINK) hard-selects the virtio
      # bus core, so CONFIG_VIRTIO=y is forced on msm8953 regardless.
      KVM = no;

      # Freescale/i.MX SoC audio: these codecs are for NXP SoCs and can never
      # appear on an msm8953 device (platform audio is QDSP6 + WCD).
      SND_SOC_FSL_ASRC = no;
      SND_SOC_FSL_SAI = no;
      SND_SOC_FSL_AUDMIX = no;
      SND_SOC_FSL_SSI = no;
      SND_SOC_FSL_SPDIF = no;
      SND_SOC_FSL_ESAI = no;
      SND_SOC_FSL_MICFIL = no;
      SND_SOC_FSL_EASRC = no;
      SND_SOC_FSL_UTILS = no;
      SND_SOC_IMX_AUDMUX = no;

      # --- Dead weight inherited from the generic upstream defconfig ---
      # None of these can appear on an msm8953 device:
      #  - server storage: SAS (RAID/HBA), UFS (msm8953 is eMMC-only)
      #  - optical (iso9660/udf), 9p (VM share), fscache/cachefiles
      #  - EHCI host controller: msm8953's only SoC USB controller is the dwc3,
      #    whose host role is xHCI (kept below for USB OTG)
      #  - other vendors' PMICs: X-Powers AXP20X, HiSilicon HI6421, NVIDIA
      #    MAX77620 (all msm8953-family PMICs are Qualcomm SPMI ones)
      #  - misc: DS3232 RTC, LT8912B DSI->HDMI bridge (only found on dev-boards
      #    like db845c), ath10k (msm8953 Wi-Fi is wcn36xx), IPv6-in-IPv4 sit
      #    tunnel, and the apq8016 DragonBoard machine driver (different SoC).
      SCSI_SAS_ATTRS = no;
      SCSI_SAS_LIBSAS = no;
      SCSI_SAS_HOST_SMP = no;
      SCSI_UFSHCD = no;
      SCSI_UFSHCD_PLATFORM = no;
      SCSI_UFS_QCOM = no;
      CDROM = no;
      BLK_DEV_SR = no;
      ISO9660_FS = no;
      JOLIET = no;
      UDF_FS = no;
      "9P_FS" = no;
      FSCACHE = no;
      CACHEFILES = no;
      USB_EHCI_HCD = no;
      MFD_AXP20X = no;
      MFD_HI6421_PMIC = no;
      MFD_MAX77620 = no;
      RTC_DRV_DS3232 = no;
      DRM_LONTIUM_LT8912B = no;
      ATH10K = no;
      IPV6_SIT = no;
      # MAX9611 has no msm8953-family device tree and stays off.
      MAX9611 = no;
      # NOTE: despite the name, this is NOT just the APQ8016 (Snapdragon 410)
      # machine driver: the msm8953-mainline kernel also matches
      # "qcom,msm8953-qdsp6-sndcard" in apq8016_sbc.c, which is what creates
      # the sound card for mido (sound-card@c051000 in msm8953.dtsi). Without
      # it ASoC never assembles a card and ALSA reports "No soundcards found".
      # SND_SOC_APQ8016_SBC = module;

      # --- Fallout from the above: selectors and universal-default sub-options ---
      # MOUSE_PS2 (default-y, unpinned) selects SERIO. And the universal filesystems
      # defaults expect the following sub-options to be `y`, which cannot hold
      # once their parent is off — pin them off explicitly.
      MFD_AXP20X_I2C = no;
      MOUSE_PS2 = no;
      # The SERIO chain: HID_RMI (Synaptics RMI4 over i2c-hid/usbhid, dead on
      # phones) selects RMI4_F03, which enables RMI4_F03_SERIO — and F03_SERIO
      # ignores an explicit `=n` because its `default RMI4_CORE` beats the
      # config file value, then selects SERIO back to `m`. Killing HID_RMI and
      # RMI4_F03 (the PS/2-guest function, TrackPoint-style passthrough) breaks
      # the chain so SERIO can stay off.
      HID_RMI = no;
      RMI4_F03 = no;
      SERIO = no;
      SERIO_AMBAKMI = no;
      SERIO_LIBPS2 = no;
      BTRFS_FS_POSIX_ACL = no;
      F2FS_FS_COMPRESSION = no;
      F2FS_FS_SECURITY = no;
      "9P_FSCACHE" = no;
      "9P_FS_POSIX_ACL" = no;
      USB_EHCI_ROOT_HUB_TT = no;
      USB_EHCI_TT_NEWSCHED = no;

      # IR blaster: mido has a pwm-ir-tx node (used as a TV/remote
      # transmitter). It needs the RC core + LIRC (raw IR userland, a
      # dependency of IR_PWM_TX). The PWM itself is provided by the LPG
      # driver (qcom,pmi8950-pwm) which is already enabled as a module.
      # RC_DEVICES is the menu that contains IR_PWM_TX; without it oldconfig
      # drops the transmitter symbol.
      RC_CORE = module;
      RC_DEVICES = yes;
      LIRC = yes;
      IR_PWM_TX = module;

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
