{ config, lib, pkgs, ... }:

let
  inherit (lib)
    mkOption
    optionalString
    types
  ;

  inherit (config)
    computeMinimalSize
    extraPadding
    inodeRatio
    size
  ;
in
{
  options = {
    name = mkOption {
      type = types.str;
      default = "filesystem-image";
      description = "Base name of the output";
    };

    label = mkOption {
      type = with types; nullOr str;
      default = null;
      description = ''
        Filesystem label

        Not to be confused with either the output name, or the partition label.
      '';
    };

    sectorSize = mkOption {
      type = types.int;
      internal = true;
      description = ''
        Default value should probably not be changed. Used internally for some
        automatic size maths.
      '';
    };

    blockSize = mkOption {
      type = types.int;
      internal = true;
      description = ''
        Used with the assumption that files are rounded up to blockSize increments.
      '';
    };

    size = mkOption {
      type = with types; nullOr int;
      default = null;
      defaultText = "[automatically computed]";
      description = ''
        When null, size is computed automatically.

        Otherwise sets the size of the filesystem image.

        Note that the usable space in the disk image will most likely be
        smaller than the size given here!
      '';
    };

    computeMinimalSize = mkOption {
      internal = true;
      type = types.str;
      description = ''
        Filesystem-specific snippet to adapt the size of the filesystem image
        so the content can fit.
      '';
    };

    extraPadding = mkOption {
      type = types.int;
      default = 0;
      description = ''
        When size is computed automatically, how many bytes to add to the
        filesystem total size.
      '';
    };

    inodeRatio = mkOption {
      type = types.int;
      internal = true;
      default = 0;
      description = ''
        Filesystems with inode tables (ext4) allocate inodes in proportion to
        the image size (make_ext4fs: 1 inode per 16 KiB). Set this to the
        bytes-per-inode ratio of the filesystem so the auto-computed size also
        accounts for the number of files and directories in the content.

        Inode-dense contents (e.g. NixOS system closures: many small files and
        directories) would otherwise exhaust inodes while the image still has
        free space, failing the build with a `make_file: failed to allocate
        inode` error. Filesystems without inode tables (squashfs, fat32,
        btrfs) leave this at 0.
      '';
    };

    minimumSize = mkOption {
      type = types.int;
      internal = true;
      default = 0;
      description = ''
        Minimum usable size the filesystem must have. "Usable" here may not
        actually be useful.
      '';
    };

    builderFunctions = mkOption {
      type = types.lines;
      internal = true;
      default = "";
      description = ''
        Bash functions required by the builder.
      '';
    };

    buildPhases = mkOption {
      type = with types; lazyAttrsOf str;
      internal = true;
      description = ''
        Implementation of build phases for the filesystem image.
      '';
    };

    buildPhasesOrder = mkOption {
      type = with types; listOf str;
      internal = true;
      description = ''
        Order of the filesystem image build phase. Adding to this is likely to
        cause issues. Use this sparingly, and as a last resort.
      '';
    };

    populateCommands = lib.mkOption {
      type = types.lines;                  
      default = "";
      description = ''
        Commands used to fill the filesystem.

        `$PWD` is the root of the filesystem.
      '';
    };                                       

    buildInputs = mkOption {
      type = with types; listOf package;
      internal = true;
      description = ''
        Allows adding to the builder buildInputs.
      '';
    };

    nativeBuildInputs = mkOption {
      type = with types; listOf package;
      internal = true;
      description = ''
        Allows adding to the builder nativeBuildInputs.

        As this list is built without *splicing*, use `pkgs.buildPackages` as
        a source for packages.
      '';
    };

    location = mkOption {
      type = types.str;
      default = "";
      description = ''
        Location of the image in the `$out` path.

        The default value means that `$img == $out`, which means that the
        image is bare at the out path.

        Other values should start with the directory separator (`/`), and
        refer to the desired name.

        The `$img` variable in the build script refers to `$out$location`.
      '';
    };

    output = mkOption {
      type = types.package;
      internal = true;
      description = ''
        The build output for the filesystem image.
      '';
    };

    imagePath = mkOption {
      type = types.path;
      default = "${config.output}${config.location}";
      defaultText = lib.literalExpression "\"\${config.output}\${config.location}\"";
      readOnly = true;
      description = ''
        Output path for the image file.
      '';
    };

    additionalCommands = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Additional commands to run during the filesystem image build.
      '';
    };
  };

  config = {
    buildInputs = [
    ];
    nativeBuildInputs = with pkgs.buildPackages; [
      libfaketime
    ];
    buildPhasesOrder = [
      # Copy the files to be copied into the target filesystem image first in
      # the `pwd` during this phase.
      "populatePhase"

      # Default phase should be fine, pre-allocate the disk image file.
      "allocationPhase"

      # Phase in which the `mkfs` command is called on the disk image file.
      "filesystemPhase"

      # Commands to copy the files into the disk image (if the creation command
      # does not intrinsically do it).
      # The prep/unprep phases change the CWD to the directory containing the
      # files to copy into the filesystem image, and back into the build dir.
      "_prepCopyPhase"
      "copyPhase"
      "_unprepCopyPhase"

      # Commands where a filesystem check should be ran.
      "checkPhase"

      # Any other extra business to run, normally left to the consumer.
      "additionalCommandsPhase"
    ];

    buildPhases = {
      "allocationPhase" = lib.mkDefault ''
        ${optionalString (size == null) ''
          size=$(compute-minimal-size)
        ''}

        if (( size < minimumSize )); then
          size=$minimumSize
          echo "WARNING: the '${"\${label:-(unlabeled)}"}' partition was too small, size increased to $minimumSize bytes."
        fi

        truncate -s $size "$img"
      '';

      "populatePhase" = lib.mkDefault ''
        (
          cd "$files"
          ${config.populateCommands}

          # This also activates dotglob automatically.
          # Using this means hidden files will be added too.
          GLOBIGNORE=".:.."

          if (( $(find -maxdepth 1 | wc -l) == 1 )); then
            (set -x; ls -l)

            echo ""
            echo "ERROR: populatePhase produced no files."
            echo "       tip: using mkForce or mkDefault at different places may unexpected overwrite values."
            exit 2
          fi
        )
      '';

      "_prepCopyPhase" = ''
        cd "$files"
      '';

      "_unprepCopyPhase" = ''
        cd "$NIX_BUILD_TOP"
      '';

      "additionalCommandsPhase" = config.additionalCommands;
    };

    builderFunctions = ''
      compute-minimal-size() {
        local size=0
        (
        cd files
        # Size rounded in blocks. This assumes all files are to be rounded to a
        # multiple of blockSize.
        # Use of `--apparent-size` is to ensure we don't get the block size of the underlying FS.
        # Use of `--block-size` is to get *our* block size.
        size=$(find . ! -type d -print0 | du --files0-from=- --apparent-size --block-size "$blockSize" | cut -f1 | sum-lines)
        echo "Reserving $size sectors for files..." 1>&2

        # Adds one blockSize per directory, they do take some place, in the end.
        local directories=$(find . -type d | wc -l)
        echo "Reserving $directories sectors for directories..." 1>&2

        size=$(( directories + size ))

        size=$((size * blockSize))

        ${computeMinimalSize}

        # Filesystems with inode tables allocate inodes in proportion to the
        # image size. The byte estimate above has no notion of file *counts*,
        # so inode-dense contents can exhaust inodes while the image still has
        # free space. Floor the size to what the inode count requires.
        if (( ${toString inodeRatio} > 0 )); then
          local inodes=$(find . | wc -l)
          echo "Reserving $inodes inodes..." 1>&2
          local inodeSize=$(( inodes * ${toString inodeRatio} ))
          if (( inodeSize > size )); then
            echo "WARNING: increasing size to ${toString inodeRatio} bytes/inode for $inodes inodes ($inodeSize bytes)." 1>&2
            size=$inodeSize
          fi
        fi

        size=$(( size + ${toString extraPadding} ))

        echo "$size"
        )
      }

      sum-lines() {
        local acc=0
        while read -r number; do
            acc=$((acc+number))
        done

        echo "$acc"
      }
    '';

    output = pkgs.callPackage ./builder.nix { inherit config; };
  };
}
