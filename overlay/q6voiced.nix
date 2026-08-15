{ stdenv, lib, fetchFromGitLab, meson, ninja, pkg-config, alsa-lib, dbus }:

stdenv.mkDerivation {
  pname = "q6voiced";
  version = "0.3.1";

  src = fetchFromGitLab {
    domain = "gitlab.postmarketos.org";
    owner = "postmarketOS";
    repo = "q6voiced";
    rev = "0.3.1";
    sha256 = "sha256-VvhDaejcvCERU8oDgsjl3IuV5a8RjkA+pH8PJRHJWJs=";
  };

  nativeBuildInputs = [ meson ninja pkg-config ];
  buildInputs = [ alsa-lib dbus ];

  meta = with lib; {
    description = "Userspace QDSP6 voice driver daemon listening on oFono/ModemManager";
    homepage = "https://gitlab.postmarketos.org/postmarketOS/q6voiced/";
    license = licenses.mit;
    platforms = platforms.aarch64;
    maintainers = with maintainers; [ ];
  };
}
