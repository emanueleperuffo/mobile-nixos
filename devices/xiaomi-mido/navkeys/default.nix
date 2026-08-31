{ stdenv, pkg-config, libevdev }:

stdenv.mkDerivation {
  pname = "mido-navkeys";
  version = "0.2";

  src = ./.;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ libevdev ];

  buildPhase = ''
    $CC -O2 -Wall $(pkg-config --cflags --libs libevdev) -o mido-navkeys main.c
  '';

  installPhase = ''
    install -Dm755 mido-navkeys $out/bin/mido-navkeys
  '';
}
