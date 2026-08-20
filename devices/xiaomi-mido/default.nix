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

    # Hardware/features that can never be used on mido, dropped from the
    # kernel to save build time and image size. Every entry was checked
    # against the mido device tree (msm8953-xiaomi-mido.dts / -common.dtsi):
    # either the hardware is absent, or the DT node is disabled.
    mobile.kernel.structuredConfig = [
      (helpers: with helpers; {
        # --- CPU/memory virtualization ---
        # The signed TZ firmware keeps the CPU at EL1 (no separate `hyp`
        # partition to replace on msm8953), so KVM and the VIRTIO devices it
        # needs can never work. See the README's "Virtualization (KVM)".
        KVM = no;
        VIRTIO = no;

        # --- USB ---
        NFC = no;   # mido has no NFC chip (Redmi Note 4)
        TYPEC = no; # micro-USB port, not Type-C

        # --- Display panels ---
        # The msm8953-mainline kernel builds generated DSI panel drivers for
        # every device in the family (Asus, Huawei, Motorola, ...). mido only
        # ships with the five `DRM_PANEL_XIAOMI_*` options loaded in stage-1
        # (left enabled); everything else matches a different phone. NOTE: the
        # mido panel node uses the placeholder compatible "xiaomi,mido-panel"
        # that no driver matches, so the display is currently driven by the
        # simple-framebuffer handed over by lk2nd.
        DRM_PANEL_MSM8953_GENERATED = no;
        DRM_PANEL_ASUS_ZE520KL_ILI7807B_BOE = no;
        DRM_PANEL_ASUS_ZE520KL_R63350_TM = no;
        DRM_PANEL_ASUS_ZE552KL_ILI7807B_CTC = no;
        DRM_PANEL_ASUS_ZE552KL_NT35596_TXD = no;
        DRM_PANEL_ASUS_ZE552KL_OTM1901A_LCE = no;
        DRM_PANEL_ASUS_ZE552KL_R63350_TM = no;
        DRM_PANEL_BILLION_RIMOB_NT35532_CS = no;
        DRM_PANEL_BOE_BS052FHM_A00_6C01 = no;
        DRM_PANEL_BOE_TV101WUM_LL2 = no;
        DRM_PANEL_EDP = no;
        DRM_PANEL_HIMAX_HX8399C_FHDPLUS = no;
        DRM_PANEL_HUAWEI_MILAN_BOE_OTM1906C = no;
        DRM_PANEL_HUAWEI_MILAN_BOE_TD4322 = no;
        DRM_PANEL_HUAWEI_MILAN_BOE_TEST1906C = no;
        DRM_PANEL_HUAWEI_MILAN_CTC_NT35596S = no;
        DRM_PANEL_HUAWEI_MILAN_CTC_OTM1906C = no;
        DRM_PANEL_HUAWEI_MILAN_JDI_R63452 = no;
        DRM_PANEL_HUAWEI_MILAN_TIANMA_FIC8736 = no;
        DRM_PANEL_HUAWEI_MILAN_TIANMA_FOCAL8716 = no;
        DRM_PANEL_HUAWEI_MILAN_TIANMA_OTM1906C = no;
        DRM_PANEL_LENOVO_CD_18781Y_FT8201 = no;
        DRM_PANEL_LENOVO_CD_18781Y_HX83100A = no;
        DRM_PANEL_LENOVO_KUNTAO_549 = no;
        DRM_PANEL_LVDS = no;
        DRM_PANEL_MDSS_FT8716_FHD = no;
        DRM_PANEL_MDSS_ILI7807_FHD = no;
        DRM_PANEL_MDSS_ILI7807_FHDPLUS = no;
        DRM_PANEL_MDSS_NT35596_EBBG = no;
        DRM_PANEL_MDSS_OTM1911_FHD = no;
        DRM_PANEL_MDSS_OTM1911_FHDPLUS = no;
        DRM_PANEL_MDSS_R63350 = no;
        DRM_PANEL_MOTOROLA_ALI_BOE = no;
        DRM_PANEL_MOTOROLA_ALI_TIANMA = no;
        DRM_PANEL_MOTOROLA_OCEAN_622_OFILM = no;
        DRM_PANEL_MOTOROLA_OCEAN_622_TIANMA = no;
        DRM_PANEL_MOTOROLA_OCEAN_NT36672A_CSOT = no;
        DRM_PANEL_MOTOROLA_RIVER_624_BOE = no;
        DRM_PANEL_MOTOROLA_RIVER_624_TIANMA = no;
        DRM_PANEL_MOTOROLA_RIVER_HX83112B_TIANMA = no;
        DRM_PANEL_MOTOROLA_RIVER_NT36672A_TIANMA = no;
        DRM_PANEL_SAMSUNG_GTA2XL_HX8279_TV101WUM = no;
        DRM_PANEL_SAMSUNG_S6E3FA7 = no;
        DRM_PANEL_SAMSUNG_S6E3FA7_AMS604NL01 = no;
        DRM_PANEL_TENOR_HX8399C_AUO = no;
        DRM_PANEL_TENOR_ILI7807D_DJN_AUO = no;
        DRM_PANEL_TENOR_ILI7807D_DJN = no;
        DRM_PANEL_TIANMA_TL052VDXP02 = no;
        DRM_PANEL_VSMART_CASUARINA_FT8006P_HLT = no;
        DRM_PANEL_VSMART_CASUARINA_FT8006P_TRULY = no;
        DRM_PANEL_VSMART_CASUARINA_ICNL9911S_BYD = no;
        DRM_PANEL_XIAOMI_NT36672_CSOT_FHDPLUS_E7 = no;
        DRM_PANEL_XIAOMI_NT36672_TIANMA_FHDPLUS_E7 = no;
        DRM_PANEL_XIAOMI_ONCLITE_HX8394F = no;
        DRM_PANEL_XIAOMI_ONCLITE_ILI9881 = no;
        DRM_PANEL_XIAOMI_ONCLITE_OTM1901A = no;
        DRM_PANEL_XIAOMI_OXYGEN_R61322_AUO = no;
        DRM_PANEL_XIAOMI_OXYGEN_R63350_TIANMA = no;
        DRM_PANEL_XIAOMI_ROSY_FT8006M_BOE = no;
        DRM_PANEL_XIAOMI_ROSY_FT8613_CSOT = no;
        DRM_PANEL_XIAOMI_ROSY_FT8613_EBBG = no;
        DRM_PANEL_XIAOMI_TD4310_EBBG_FHDPLUS_E7 = no;
        DRM_PANEL_XIAOMI_TD4310_FHDPLUS_E7_G55 = no;
        DRM_PANEL_XIAOMI_TD4310_FHDPLUS_E7 = no;
        DRM_PANEL_XIAOMI_YSL_HX8394F = no;
        DRM_PANEL_XIAOMI_YSL_ILI7807D = no;
        DRM_PANEL_XIAOMI_YSL_ILI9881C = no;

        # --- Cameras ---
        # mido's only camera sensor (samsung,s5k3l8) has no driver in this
        # kernel at all, so the whole camera path is dead weight: disable the
        # camera ISP, video encoder and the sensors fitted to *other* phones
        # in the family. Re-enable VIDEO_QCOM_CAMSS/VENUS when a s5k3l8 (or
        # any mido) camera driver lands.
        VIDEO_QCOM_CAMSS = no;
        VIDEO_QCOM_VENUS = no;
        VIDEO_SR556 = no;
        VIDEO_IMX219 = no;
        VIDEO_OV5645 = no;
        VIDEO_OV5670 = no;
        VIDEO_OV5675 = no;
        VIDEO_OV5695 = no;
        VIDEO_S5K2XX = no;

        # --- Sensors (IIO) ---
        # mido's i2c-gpio bitbanged bus has BMI160 (accel/gyro), LSM6DS3
        # (st,lsm6ds3 -> IIO_ST_LSM6DSX) and LTRF216A (light) — all kept.
        # The ones below are light/magnetometer sensors of other devices.
        LTR501 = no;
        STK3310 = no;
        AK8975 = no;
        AK09911 = no;

        # --- Audio codecs ---
        # mido uses the QDSP6 path with the msm8916 WCD codec (wcd_codec +
        # lpass_codec nodes are enabled) and the awinic,aw8738 speaker amp —
        # all kept. Freescale/i.MX codecs are for NXP SoCs, and the rest are
        # amps/codecs fitted to other devices. The max98927 node (audio-
        # codec@3a) is disabled in the common dtsi and never enabled.
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
        SND_SOC_MAX98927 = no;
        SND_SOC_HDMI_CODEC = no;
        SND_SOC_SIMPLE_AMPLIFIER = no;
        SND_SOC_SIMPLE_MUX = no;
        SND_SOC_SPDIF = no;
        SND_SOC_TFA9872 = no;
        SND_SOC_WM8978 = no;

        # --- Input ---
        # The Synaptics RMI4 node (touchscreen@20) is disabled in the common
        # dtsi and never enabled — mido's controllers are FocalTech (edt-
        # ft5406) or Goodix (gt917d), both kept.
        RMI4_CORE = no;
        RMI4_I2C = no;
      })
    ];

    networking.networkmanager.wifi.backend = "iwd";

    # Power button short-press is ignored: binding it to suspend caused a hang
    # (watchdog reset) on this kernel, while a manual `systemctl suspend`
    # suspends/resumes reliably. Sleep with `systemctl suspend`, wake with the
    # power button.
    services.logind.settings.Login.HandlePowerKey = "ignore";

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
