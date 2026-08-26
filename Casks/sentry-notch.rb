cask "sentry-notch" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/SP1R4/sentrynotch/releases/download/v#{version}/SentryNotch-#{version}.dmg"
  name "Sentry Notch"
  desc "Permission checkpoint for coding agents, living in the macOS notch"
  homepage "https://github.com/SP1R4/sentrynotch"

  # The release is signed + notarized via release.sh; keep the floor in step
  # with LSMinimumSystemVersion in make-app.sh.
  depends_on macos: ">= :sonoma"

  app "SentryNotch.app"

  # Everything the app writes lives under one owner-only directory.
  zap trash: [
    "~/Library/Application Support/SentryNotch",
  ]

  caveats <<~EOS
    Sentry Notch installs a Claude Code hook on first run and, for other
    agents, brokers over a local socket. It fails open: if it isn't running,
    your agent's own permission flow is untouched.
  EOS
end
