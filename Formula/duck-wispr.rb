class DuckWispr < Formula
  desc "Push-to-talk voice dictation for macOS using Whisper"
  homepage "https://github.com/human37/duck-wispr"
  url "https://github.com/human37/duck-wispr.git", tag: "v0.9.1"
  license "MIT"

  depends_on "whisper-cpp"
  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    system "bash", "scripts/bundle-app.sh", ".build/release/duck-wispr", "DuckWispr.app", version.to_s
    bin.install ".build/release/duck-wispr"
    prefix.install "DuckWispr.app"
  end

  def post_install
    target = Pathname.new("#{Dir.home}/Applications/DuckWispr.app")
    target.dirname.mkpath
    rm_rf target if target.exist? && !target.symlink?
    ln_sf prefix/"DuckWispr.app", target
  end

  service do
    run [opt_prefix/"DuckWispr.app/Contents/MacOS/duck-wispr", "start"]
    keep_alive successful_exit: false
    log_path var/"log/duck-wispr.log"
    error_log_path var/"log/duck-wispr.log"
    process_type :interactive
  end

  def caveats
    <<~EOS
      Recommended: use the install script for guided setup:
        curl -fsSL https://raw.githubusercontent.com/human37/duck-wispr/main/scripts/install.sh | bash

      Or start manually:
        brew services start duck-wispr

      Grant Accessibility and Microphone when prompted.
      The Whisper model downloads automatically (~142 MB).
    EOS
  end

  test do
    assert_match "duck-wispr", shell_output("#{bin}/duck-wispr --help")
  end
end
