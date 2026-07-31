# Prebuilt comment-checker binary consumed by omo-senpi's comment-checker
# component (and symlinked into omo-cli's bin/).
#
# The component resolves the binary in this order:
#   1. OMO_COMMENT_CHECKER_BIN (absolute path)
#   2. require('@code-yeongyu/comment-checker').getBinaryPath()
#   3. PATH lookup for `comment-checker`
# The npm package is not usable here (its postinstall downloads from GitHub at
# install time, which the sandbox forbids), so we fetch the same per-platform
# release archive the postinstall would have downloaded:
#   https://github.com/code-yeongyu/go-claude-code-comment-checker/releases
#
# Version and archive hashes live in omo-hashes.json under `commentChecker`
# and are refreshed by update-omo.sh via plain nix-prefetch-url (no FOD
# discovery build needed — these are ordinary fetchurl inputs).
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}:

let
  hashesData = lib.importJSON ./omo-hashes.json;
  pin = hashesData.commentChecker;

  # Release asset names follow GoReleaser conventions (amd64, not x86_64).
  platformMap = {
    "x86_64-linux" = {
      os = "linux";
      arch = "amd64";
    };
    "aarch64-linux" = {
      os = "linux";
      arch = "arm64";
    };
    "x86_64-darwin" = {
      os = "darwin";
      arch = "amd64";
    };
    "aarch64-darwin" = {
      os = "darwin";
      arch = "arm64";
    };
  };

  system = stdenv.hostPlatform.system;
  platform =
    platformMap.${system}
      or (throw "comment-checker: unsupported system \"${system}\" (no upstream release asset)");

  src = fetchurl {
    url = "https://github.com/code-yeongyu/go-claude-code-comment-checker/releases/download/v${pin.version}/comment-checker_v${pin.version}_${platform.os}_${platform.arch}.tar.gz";
    hash =
      pin.hashes.${system}
        or (throw "comment-checker: no hash pinned for system \"${system}\" in omo-hashes.json");
  };
in
stdenv.mkDerivation {
  pname = "comment-checker";
  version = pin.version;
  inherit src;

  # The release archive ships bare files (comment-checker, LICENSE, README.md)
  # with no top-level directory, which makes the default unpack phase abort
  # with "unpacker appears to have produced no directories".
  sourceRoot = ".";

  # The release binary is CGO-enabled (tree-sitter): it dynamically links
  # glibc and libgcc_s, and its ELF interpreter points at the FHS path
  # /lib64/ld-linux-x86-64.so.2 which does not exist on NixOS.  Rewrite the
  # interpreter and rpath on Linux; Mach-O binaries need no such treatment.
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall

    install -Dm755 comment-checker $out/bin/comment-checker
    install -Dm644 LICENSE $out/share/licenses/comment-checker/LICENSE

    runHook postInstall
  '';

  meta = {
    description = "Multi-language comment detection hook — native tree-sitter binary used by omo-senpi's comment-checker component";
    homepage = "https://github.com/code-yeongyu/go-claude-code-comment-checker";
    license = lib.licenses.mit;
    # Prebuilt upstream binary, not compiled from source here.
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
    # Upstream ships no --version flag (clap parser without a version
    # subcommand); verify with `comment-checker --help` instead.
    mainProgram = "comment-checker";
  };
}
