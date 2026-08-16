{ stdenv }:

stdenv.mkDerivation {
  pname = "mido-navkeys";
  version = "0.1";

  src = ./.;

  buildPhase = ''
    $CC -O2 -Wall -o mido-navkeys main.c
  '';

  installPhase = ''
    install -Dm755 mido-navkeys $out/bin/mido-navkeys
  '';
}