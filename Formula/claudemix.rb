class Claudemix < Formula
  desc "Multi-session orchestrator for Claude Code"
  homepage "https://github.com/Draidel/ClaudeMix"
  url "https://github.com/Draidel/ClaudeMix.git", branch: "main"
  version "0.2.0"
  license "MIT"

  depends_on "bash"
  depends_on "git"

  def install
    # Install shell completions before moving everything to libexec
    bash_completion.install "completions/claudemix.bash" => "claudemix"
    zsh_completion.install "completions/claudemix.zsh" => "_claudemix"
    fish_completion.install "completions/claudemix.fish" => "claudemix.fish"

    # Install the whole project tree into libexec so the script's
    # symlink-resolving CLAUDEMIX_HOME logic finds lib/*.sh correctly
    libexec.install Dir["*"]

    # Create a wrapper that exec's the real script
    (bin/"claudemix").write <<~SH
      #!/bin/bash
      exec "#{libexec}/bin/claudemix" "$@"
    SH
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
