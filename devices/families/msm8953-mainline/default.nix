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
      # None of these can appear on an msm8953 device (verified against the
      # device trees and the platform's hardware):
      #  - server storage: SAS (RAID/HBA), UFS (msm8953 is eMMC-only)
      #  - unused filesystems: btrfs/f2fs (rootfs is squashfs, data is ext4),
      #    optical (iso9660/udf), 9p (VM share), fscache/cachefiles
      #  - USB *host* stack: xhci/ehci (dwc3 is peripheral-only), mass storage,
      #    serial adapters (incl. LTE dongles), ethernet dongles
      #  - other vendors' PMICs: X-Powers AXP20X, HiSilicon HI6421, NVIDIA
      #    MAX77620 (mido's PMICs are the Qualcomm SPMI ones)
      #  - misc: DS3232 RTC, DisplayLink/UDL, LT8912B DSI->HDMI bridge (only
      #    found on dev-boards like db845c), USB audio, ALSA MIDI sequencer,
      #    ath10k (msm8953 Wi-Fi is wcn36xx), Speakup, NT sync (Wine),
      #    IPv6-in-IPv4 sit tunnel, sensors/PMICs of other devices,
      #    and the apq8016 DragonBoard machine driver (different SoC).
      SCSI_SAS_ATTRS = no;
      SCSI_SAS_LIBSAS = no;
      SCSI_SAS_HOST_SMP = no;
      SCSI_UFSHCD = no;
      SCSI_UFSHCD_PLATFORM = no;
      SCSI_UFS_QCOM = no;
      F2FS_FS = no;
      BTRFS_FS = no;
      ISO9660_FS = no;
      UDF_FS = no;
      "9P_FS" = no;
      FSCACHE = no;
      CACHEFILES = no;
      USB_XHCI_HCD = no;
      USB_EHCI_HCD = no;
      USB_STORAGE = no;
      USB_SERIAL = no;
      USB_NET_DRIVERS = no;
      MFD_AXP20X = no;
      MFD_HI6421_PMIC = no;
      MFD_MAX77620 = no;
      RTC_DRV_DS3232 = no;
      DRM_UDL = no;
      DRM_LONTIUM_LT8912B = no;
      SND_USB_AUDIO = no;
      SND_SEQUENCER = no;
      SND_RAWMIDI = no;
      SND_UMP = no;
      SND_SEQ_UMP = no;
      ATH10K = no;
      SPEAKUP = no;
      NTSYNC = no;
      IPV6_SIT = no;
      CM3323 = no;
      YAMAHA_YAS530 = no;
      MAX9611 = no;
      SM5708_POWER = no;
      SND_SOC_APQ8016_SBC = no;

      # --- Fallout from the above: selectors and universal-default sub-options ---
      # MFD_AXP20X_I2C selects the AXP20X core back to `y`; HID_PRODIKEYS
      # (PC-MIDI keyboard) selects SND_RAWMIDI; MOUSE_PS2 (default-y, unpinned)
      # selects SERIO. And the universal filesystems defaults expect the
      # following sub-options to be `y`, which cannot hold once their parent is
      # off — pin them off explicitly.
      MFD_AXP20X_I2C = no;
      HID_PRODIKEYS = no;
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
