#
# Example /etc/nixos/configuration.nix for the Xiaomi Redmi Note 4 (mido).
#
# This is a template to copy to your device's /etc/nixos/configuration.nix.
# It imports the device definition (which wires up the kernel, kernel modules,
# GPU/panel/touchscreen firmware, Wi-Fi and modem for you) and enables the
# user-facing hardware services (audio, Bluetooth, sensors).
#
# The extlinux boot flow is handled entirely by the device definition:
#   - boots via lk2nd scanning the `system` partition for
#     `/extlinux/extlinux.conf`
#   - root filesystem lives on the `userdata` partition
#     (mobile.system.android.system_partition_destination = "userdata")
#   - `/boot` is the ext2 boot filesystem on the `system` partition
#
# The device already enables: NetworkManager + iwd (Wi-Fi), ModemManager
# (cellular), and the DRM/GPU/panel/touchscreen/backlight kernel modules.
#
# Assumes NIX_PATH includes `mobile-nixos=/path/to/mobile-nixos`.
#

{ config, lib, pkgs, ... }:

{
  imports = [
    # Pull in the full device configuration (kernel, firmware, modem, wifi).
    (import <mobile-nixos/lib/configuration.nix> { device = "xiaomi-mido"; })
  ];

  # --- Identity ----------------------------------------------------------
  networking.hostName = "mido";

  # --- User ---------------------------------------------------------------
  # Create a normal user with sudo (wheel) access. Change the name/password.
  users.users.user = {
    isNormalUser = true;
    password = "changeme";
    extraGroups = [
      "wheel"
      "networkmanager"
      "video"
      "audio"
      "dialout"
      "feedbackd"
    ];
  };

  # --- Audio ---------------------------------------------------------------
  # PipeWire + WirePlumber provide PulseAudio-compatible audio for the
  # WCD9335 codec that msm8953-mainline enables by default.
  services.pipewire = {
    enable = true;
    pulse.enable = true;
    wireplumber.enable = true;
  };

  # --- Bluetooth ------------------------------------------------------------
  # mido's WCNSS-based Bluetooth, managed by bluez.
  hardware.bluetooth.enable = true;
  services.blueman.enable = true;

  # --- Sensors --------------------------------------------------------------
  # Accelerometer/gyroscope (IIO), e.g. for automatic screen rotation.
  hardware.sensor.iio.enable = true;

  # --- Wi-Fi / cellular (already enabled by the device definition) ---------
  # networking.networkmanager.enable = true;
  # networking.networkmanager.wifi.backend = "iwd";
  # networking.modemmanager.enable = true;

  # --- Power management ------------------------------------------------------
  powerManagement.enable = true;

  # --- Desktop (optional) ----------------------------------------------------
  # Uncomment for a Phosh (GNOME mobile) desktop instead of a bare shell.
  # services.xserver.desktopManager.phosh = {
  #   enable = true;
  #   user = "user";
  # };

  # --- Packages ---------------------------------------------------------------
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
  ];

  # --- Keep a usable default editor -------------------------------------------
  environment.variables.EDITOR = "vim";

  system.stateVersion = "26.05";
}
