{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
}:

let
  version = "2026.5.15-2";

  platforms = {
    "x86_64-linux" = {
      suffix = "linux-x64";
      hash = "sha256-pe0GnmdbjVN57uKZiHekksTwYFnxmJsJXLBNyf2UdjA=";
    };
    "aarch64-linux" = {
      suffix = "linux-arm64";
      hash = "sha256-hfEO+c4biwjoRYkOVQsn0qL+T//tUN48lals9Y1vi9w=";
    };
    "x86_64-darwin" = {
      suffix = "darwin-x64";
      hash = "sha256-qvLtl3m9Z4aVZxLuP9GOEpLlh+v4eOzT3MRXxEztgEw=";
    };
    "aarch64-darwin" = {
      suffix = "darwin-arm64";
      hash = "sha256-c7oYgFPIqtPk/fZWEGsfvPfgsgsgjx2tCYSO/7rfV2A=";
    };
  };

  platform =
    platforms.${stdenv.hostPlatform.system}
      or (throw "Unsupported platform: ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "senpi";
  inherit version;

  src = fetchurl {
    url = "https://github.com/code-yeongyu/senpi/releases/download/v${version}/pi-${platform.suffix}.tar.gz";
    hash = platform.hash;
  };

  nativeBuildInputs =
    [
      makeWrapper
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      autoPatchelfHook
    ];

  sourceRoot = "pi";

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/senpi $out/bin
    cp -r . $out/lib/senpi/

    chmod +x $out/lib/senpi/pi

    # senpi is the canonical name. pi is kept as an alias for upstream compatibility.
    makeWrapper $out/lib/senpi/pi $out/bin/senpi
    ln -s $out/bin/senpi $out/bin/pi

    runHook postInstall
  '';

  meta = {
    description = "Coding agent CLI with read, bash, edit, write tools and session management (opinionated pi-mono fork)";
    homepage = "https://github.com/code-yeongyu/senpi";
    changelog = "https://github.com/code-yeongyu/senpi/releases";
    license = lib.licenses.mit;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = builtins.attrNames platforms;
    mainProgram = "senpi";
  };
}
