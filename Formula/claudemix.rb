class Claudemix < Formula
  desc "Multi-session orchestrator for Claude Code"
  homepage "https://github.com/Draidel/ClaudeMix"
  url "https://github.com/Draidel/ClaudeMix.git", branch: "main"
  version "0.2.0"
  license "MIT"

  depends_on "bash" => "4.0"
  depends_on "git"

  def install
    bin.install "bin/claudemix"
    lib.install Dir["lib/*.sh"]

    # Shell completions
    bash_completion.install "completions/claudemix.bash" => "claudemix"
    zsh_completion.install "completions/claudemix.zsh" => "_claudemix"
    fish_completion.install "completions/claudemix.fish" => "claudemix.fish"
  end

  def caveats
    <<~EOS
      ClaudeMix requires Claude Code CLI:
        npm install -g @anthropic-ai/claude-code

      Optional dependencies for full functionality:
        brew install tmux    # Session persistence (recommended)
        brew install gum     # Interactive TUI menus
        brew install gh      # Merge queue PR creation

      Quick start:
        cd your-project
        claudemix init              # Generate config
        claudemix hooks install     # Set up git hooks
        claudemix my-feature        # Start a session
    EOS
  end

  test do
    assert_match "claudemix v#{version}", shell_output("#{bin}/claudemix version")
    assert_match "ClaudeMix", shell_output("#{bin}/claudemix help")
  end
end
