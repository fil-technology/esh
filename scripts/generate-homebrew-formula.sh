#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <version> <sha256>" >&2
  exit 1
fi

VERSION="$1"
SHA256="$2"

cat <<EOF
class Esh < Formula
  desc "Local-first LLM tool for Apple Silicon"
  homepage "https://github.com/fil-technology/esh"
  url "https://github.com/fil-technology/esh/releases/download/v${VERSION}/esh-macos-${VERSION}.tar.gz"
  sha256 "${SHA256}"
  license "MIT"

  depends_on macos: :ventura

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"esh" => "esh"
  end

  test do
    output = shell_output("#{bin}/esh doctor 2>&1")
    assert_match "python", output.downcase
  end
end
EOF
