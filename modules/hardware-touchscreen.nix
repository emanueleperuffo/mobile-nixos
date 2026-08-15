{ config, lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  options.mobile.hardware.touchscreen = mkOption {
    type = types.nullOr (types.enum [
      "unknown"
      "focaltech"
      "goodix"
      "synaptics"
    ]);
    description = ''
      Which touch controller the device ships with.

      Devices that come with multiple possible touch controllers (e.g. mido
      ships either a FocalTech or a Goodix controller) use this to select the
      matching device tree node at build time.
    '';
    default = null;
  };
}
