{ mobile-nixos
, fetchFromGitHub
, python3
, ...
}:

mobile-nixos.kernel-builder {
  version = "7.1.3";
  configfile = ./config.aarch64;

  # The MSM DRM driver generates a2xx.xml.h with a python3 script.
  nativeBuildInputs = [ python3 ];

  src = fetchFromGitHub {
    owner = "msm8953-mainline";
    repo = "linux";
    rev = "7213855948c70fd165356526f1de1c3b6bf4d554";  # tag v7.1.3-r0
    hash = "sha256-EkdZtqbohDwnytlU8DUCGzi2KRgYfRkqdU5lmurwzOM=";
  };

  isModular = true;
}
