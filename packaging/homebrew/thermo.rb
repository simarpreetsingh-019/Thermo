# Homebrew cask for Thermo (from shipcrate). Lives at Casks/thermo.rb in simarpreetsingh-019/homebrew-thermo;
# scripts/release.sh rewrites the version and sha256 lines on every release.
cask "thermo" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000" # shipcrate:macos

  url "https://github.com/simarpreetsingh-019/Thermo/releases/download/v#{version}/Thermo.zip"
  name "Thermo"
  desc "Mac stats, right on your notch"
  homepage "https://github.com/simarpreetsingh-019/Thermo"

  # The app updates itself; tell Homebrew so `brew upgrade` doesn't fight it.
  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Thermo.app"

  zap trash: [
    "~/Library/Preferences/local.thermo.plist",
    "~/Library/Caches/local.thermo",
  ]
end
