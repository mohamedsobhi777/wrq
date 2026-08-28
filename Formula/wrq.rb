class Wrq < Formula
  desc "Local-first command-line library for research papers"
  homepage "https://github.com/mohamedsobhi777/wrq"
  url "https://github.com/mohamedsobhi777/wrq/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0e3d806a9d4fd5ac39931f218b2de43a438ad6bde617620c56d0de22904100ae"
  license "MIT"
  head "https://github.com/mohamedsobhi777/wrq.git", branch: "main"

  depends_on "ruby"
  on_linux do
    depends_on "xdg-utils"
  end

  def install
    libexec.install "wrq.rb", "lib"
    (bin/"wrq").write_env_script libexec/"wrq.rb",
      PATH: "#{formula_opt_bin("ruby")}:$PATH"
  end

  test do
    reported_version = shell_output("#{bin}/wrq --version").strip
    if build.head?
      assert_match(/^wrq \d+\.\d+\.\d+$/, reported_version)
    else
      assert_equal "wrq #{version}", reported_version
    end
    assert_match "research paper", shell_output("#{bin}/wrq --help")
  end
end
