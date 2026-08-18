{ lib, stdenv, libdrm, pkg-config }:

stdenv.mkDerivation {
  pname = "dpms";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ libdrm ];

  buildPhase = ''
    runHook preBuild
    $CC dpms.c -o dpms $(pkg-config --cflags --libs libdrm)
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 dpms $out/bin/dpms
    runHook postInstall
  '';

  meta = {
    description = "Set a DRM connector's DPMS state (on/off) from the CLI";
    longDescription = ''
      Small helper to power a DRM display panel on or off without a
      compositor, by writing the connector's DPMS property via
      drmModeObjectSetProperty. Useful on devices like mido that boot to a
      console (no phosh) where wlr-randr/Wayland is unavailable.

      Usage:
        dpms list             # list every connector (id, name, status, DPMS)
        dpms on all           # power every DPMS-capable connector on
        dpms standby 36       # blank, minimal power, connector 36
        dpms suspend all      # blank, less power, all connectors
        dpms off 36           # power connector 36 off
    '';
    license = lib.licenses.mit;
    maintainers = [ ];
    platforms = lib.platforms.linux;
  };
}