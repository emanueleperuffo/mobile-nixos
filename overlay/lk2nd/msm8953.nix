{
  stdenv
, buildPackages
, fetchFromGitHub
, gcc-arm-embedded
}:
let
  # The lk2nd build only runs host-side tools (the bare-metal binary itself is
  # compiled with the `arm-none-eabi-` toolchain), so build-time tools must be
  # native (build machine) packages. Using the cross-compiled equivalents pulls
  # in a cross-built `dtc` (via `libfdt`) that fails to build on the current
  # nixpkgs pin.
  python = (buildPackages.python3.withPackages (p: [
    p.libfdt
  ]));

in stdenv.mkDerivation {
  pname = "lk2nd";
  version = "23.1";

  src = fetchFromGitHub {
    repo = "lk2nd";
    owner = "msm8916-mainline";
    rev = "23.1";
    hash = "sha256-YgQtDQBlNiOVkKSn1+3YPkadYvzc75XvbEuHB00sN80=";
  };

  nativeBuildInputs = [
    gcc-arm-embedded
    buildPackages.dtc
    python
  ];

  postPatch = ''
    patchShebangs --build \
      lk2nd/scripts/dtbTool \
      lk2nd/scripts/mkbootimg \
      lk2nd/scripts/patch-boot-img.py \
      lk2nd/scripts/bootsignature.py
  '';

  # Upstream hardcodes the FocalTech touch controller on all mido panels, which
  # makes lk2nd always enable the FT5435 node and thus breaks the Goodix GT917D
  # variant. Remove the per-panel `touchscreen-compatible` so touch selection is
  # left to the kernel-side `patchedMidoDTB` (driven by
  # `mobile.hardware.touchscreen`), which supports both controllers.
  patches = [
    ./msm8953-touchscreen.patch
    ./msm8953-fbcon.patch
    ./msm8953-halt-noreboot.patch
    ./msm8953-boot-breadcrumb.patch
    ./msm8953-system-boot.patch
  ];

  installPhase = ''
    mkdir -p $out/
    cp ./build-lk2nd-msm8953/lk2nd.img $out
    cp ./build-lk2nd-msm8953/config.h $out
  '';

  makeFlags = [
    "LK2ND_VERSION=23.1"
    "TOOLCHAIN_PREFIX=arm-none-eabi-"
    # Keep the device sitting on the crash screen instead of watchdog-rebooting,
    # so the lk fault dump (prefetch/data abort registers) can be read.
    "PANIC_REBOOT_MODE=NO_REBOOT"
    # The makefile only overrides `LD` from TOOLCHAIN_PREFIX when `$(LD)` is
    # exactly `ld`; in a cross build the stdenv sets `LD` to the host cross
    # linker, so we must pin it to the bare-metal linker explicitly.
    "LD=arm-none-eabi-ld"
    # Skip QCDT generation (see the postmarketOS APKBUILD: msm8953 is built
    # with `LK2ND_QCDTBS=""` to work around a regression on some devices).
    "LK2ND_QCDTBS="
    "lk2nd-msm8953"
  ];

}
